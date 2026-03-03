// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Master / Producer phase of the import pipeline.
///
/// Reads the prepared <c>users_*.json</c> blobs that were written during the
/// export phase, applies all attribute transformations, and enqueues each user
/// as an individual message on the <c>users-to-import</c> Azure Queue.
/// Optionally also enqueues a companion message to the <c>phone-registration</c>
/// queue for users who have an MFA phone number.
///
/// The actual user-creation calls against Entra External ID are made by
/// <see cref="WorkerImportOrchestrator"/> instances that drain the queue in
/// parallel, each using their own app registration.
/// </summary>
public class ImportOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IBlobStorageClient _blobClient;
    private readonly IQueueClient _queueClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<ImportOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public ImportOrchestrator(
        IBlobStorageClient blobClient,
        IQueueClient queueClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<ImportOrchestrator> logger)
    {
        _blobClient = blobClient ?? throw new ArgumentNullException(nameof(blobClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "Import Master — Enqueue Users",
            StartTime = DateTimeOffset.UtcNow
        };

        long totalBlobBytesRead = 0;
        int usersEnqueued = 0;
        int phonesEnqueued = 0;

        try
        {
            _logger.LogInformation("=== IMPORT MASTER START ===");
            _telemetry.TrackEvent("Import.Started");

            // Validate extension attributes configuration
            ValidateExtensionAttributes();

            // ---------------------------------------------------------------
            // Ensure queues exist
            // ---------------------------------------------------------------
            var importQueueName = _options.Import.QueueName;
            await _queueClient.CreateQueueIfNotExistsAsync(importQueueName, cancellationToken);
            _logger.LogInformation("Queue ready: {Queue}", importQueueName);

            if (_options.Import.PhoneRegistration.EnqueuePhoneRegistration)
            {
                var phoneQueueName = _options.PhoneRegistration.QueueName;
                await _queueClient.CreateQueueIfNotExistsAsync(phoneQueueName, cancellationToken);
                _logger.LogInformation("Queue ready: {Queue}", phoneQueueName);
            }

            // ---------------------------------------------------------------
            // Load phone-harvest lookup (phones_*.json blobs written by phone-harvest workers)
            // ---------------------------------------------------------------
            var phoneLookup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var phoneBlobs = (await _blobClient.ListBlobsAsync(
                _options.Storage.ExportContainerName,
                "phones_",
                cancellationToken)).ToList();

            foreach (var phoneBlobName in phoneBlobs)
            {
                try
                {
                    var phoneJson = await _blobClient.ReadBlobAsync(
                        _options.Storage.ExportContainerName,
                        phoneBlobName,
                        cancellationToken);
                    var phoneEntries = JsonSerializer.Deserialize<List<PhoneLookupEntry>>(phoneJson);
                    if (phoneEntries != null)
                    {
                        foreach (var entry in phoneEntries)
                        {
                            phoneLookup[entry.UserId] = entry.PhoneNumber;
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Could not read phone lookup blob {Blob} — skipping.", phoneBlobName);
                }
            }

            _logger.LogInformation(
                "Phone lookup loaded: {Count:N0} users have an MFA phone number (from {BlobCount} phone blob(s)).",
                phoneLookup.Count, phoneBlobs.Count);

            // ---------------------------------------------------------------
            // List all export blobs
            // ---------------------------------------------------------------
            var blobs = await _blobClient.ListBlobsAsync(
                _options.Storage.ExportContainerName,
                _options.Storage.ExportBlobPrefix,
                cancellationToken);

            var blobList = blobs.OrderBy(b => b).ToList();
            _logger.LogInformation("Found {Count} export blob(s) to process", blobList.Count);

            // ---------------------------------------------------------------
            // For each blob, for each user: transform then enqueue
            // ---------------------------------------------------------------
            foreach (var blobName in blobList)
            {
                if (cancellationToken.IsCancellationRequested) break;

                try
                {
                    var json = await _blobClient.ReadBlobAsync(
                        _options.Storage.ExportContainerName,
                        blobName,
                        cancellationToken);

                    totalBlobBytesRead += System.Text.Encoding.UTF8.GetByteCount(json);

                    var users = JsonSerializer.Deserialize<List<UserProfile>>(json);

                    if (users == null || !users.Any())
                    {
                        _logger.LogWarning("Blob {Blob} contains no users, skipping.", blobName);
                        continue;
                    }

                    _logger.LogInformation("Enqueuing {Count} users from {Blob}", users.Count, blobName);

                    foreach (var user in users)
                    {
                        if (cancellationToken.IsCancellationRequested) break;

                        // Enrich with MFA phone number from phone-harvest phase
                        if (user.Id != null && phoneLookup.TryGetValue(user.Id, out var mfaPhone))
                        {
                            user.MfaPhoneNumber = mfaPhone;
                        }

                        // ---- Apply all transformations before enqueueing ----

                        ApplyAttributeMappings(user);

                        if (_options.Import.MigrationAttributes.StoreB2CObjectId)
                        {
                            var b2cObjectIdAttr = GetB2CObjectIdAttributeName();
                            user.ExtensionAttributes[b2cObjectIdAttr] = user.Id!;

                            if (_options.VerboseLogging)
                                _logger.LogDebug("Storing B2C ObjectId {ObjectId} as {AttrName}", user.Id, b2cObjectIdAttr);
                        }

                        if (_options.Import.MigrationAttributes.SetRequireMigration)
                        {
                            var requireMigrationAttr = GetRequireMigrationAttributeName();
                            user.ExtensionAttributes[requireMigrationAttr] = true;

                            if (_options.VerboseLogging)
                                _logger.LogDebug("Setting migration flag to true as {AttrName}", requireMigrationAttr);
                        }

                        if (!string.IsNullOrEmpty(user.UserPrincipalName))
                        {
                            user.UserPrincipalName = TransformUpnForExternalId(user.UserPrincipalName);
                        }

                        EnsureEmailIdentity(user);

                        if (user.Identities != null && user.Identities.Any())
                        {
                            foreach (var identity in user.Identities)
                            {
                                identity.Issuer = _options.ExternalId.TenantDomain;

                                if (identity.SignInType?.ToLower() == "userprincipalname" &&
                                    !string.IsNullOrEmpty(identity.IssuerAssignedId))
                                {
                                    identity.IssuerAssignedId = TransformUpnForExternalId(identity.IssuerAssignedId);
                                }
                            }

                            if (_options.VerboseLogging)
                            {
                                _logger.LogDebug("User has {Count} identities: {Types}",
                                    user.Identities.Count,
                                    string.Join(", ", user.Identities.Select(i => i.SignInType)));
                            }
                        }

                        user.PasswordProfile = new PasswordProfile
                        {
                            Password = GenerateRandomPassword(),
                            ForceChangePasswordNextSignIn = false
                        };

                        // ---- Enqueue to users-to-import ----
                        var userJson = JsonSerializer.Serialize(user);
                        await _queueClient.SendMessageAsync(importQueueName, userJson, cancellationToken);
                        usersEnqueued++;

                        summary.TotalItems++;
                        summary.SuccessCount++;

                        // ---- Optionally enqueue to phone-registration ----
                        if (_options.Import.PhoneRegistration.EnqueuePhoneRegistration &&
                            !string.IsNullOrWhiteSpace(user.MfaPhoneNumber) &&
                            !string.IsNullOrWhiteSpace(user.UserPrincipalName))
                        {
                            var phoneMsg = new PhoneRegistrationMessage
                            {
                                Upn = user.UserPrincipalName,
                                PhoneNumber = user.MfaPhoneNumber
                            };
                            var phoneMsgJson = JsonSerializer.Serialize(phoneMsg);
                            await _queueClient.SendMessageAsync(
                                _options.PhoneRegistration.QueueName, phoneMsgJson, cancellationToken);
                            phonesEnqueued++;
                        }

                        // Progress log every 1 000 users
                        if (usersEnqueued % 1000 == 0)
                        {
                            _logger.LogInformation(
                                "Progress: {Users:N0} users enqueued ({Phones:N0} with phones)",
                                usersEnqueued, phonesEnqueued);
                        }
                    }

                    _telemetry.IncrementCounter("Import.BlobsProcessed");
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to process blob {Blob}", blobName);
                    summary.FailureCount++;
                }
            }

            summary.EndTime = DateTimeOffset.UtcNow;

            _logger.LogInformation(
                "=== IMPORT MASTER SUMMARY ===\n" +
                "Users enqueued to '{ImportQueue}' : {Users:N0}\n" +
                "Phones enqueued to '{PhoneQueue}'  : {Phones:N0}\n" +
                "Blobs failed                        : {Failed}\n" +
                "Blob data read                      : {Bytes:N0} bytes\n" +
                "Duration                            : {Duration}",
                importQueueName, usersEnqueued,
                _options.PhoneRegistration.QueueName, phonesEnqueued,
                summary.FailureCount,
                totalBlobBytesRead,
                summary.Duration);

            _logger.LogInformation(
                "Next step: run 'worker-import' on one or more consoles (each with its own --config).");

            _telemetry.TrackMetric("import.blob.read.bytes", totalBlobBytesRead);
            _telemetry.TrackMetric("import.users.enqueued", usersEnqueued);
            _telemetry.TrackMetric("import.phones.enqueued", phonesEnqueued);

            _telemetry.TrackEvent("Import.Completed", new Dictionary<string, string>
            {
                { "UsersEnqueued", usersEnqueued.ToString() },
                { "PhonesEnqueued", phonesEnqueued.ToString() },
                { "BlobsFailed", summary.FailureCount.ToString() },
                { "Duration", summary.Duration.ToString() }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = summary.FailureCount == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Import master failed");
            _telemetry.TrackException(ex);

            return new ExecutionResult
            {
                Success = false,
                ErrorMessage = ex.Message,
                Exception = ex,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers (all transformations — identical logic to export-time prep)
    // -------------------------------------------------------------------------

    private void ValidateExtensionAttributes()
    {
        _logger.LogInformation("Validating extension attributes configuration...");

        if (string.IsNullOrWhiteSpace(_options.ExternalId.ExtensionAppId))
        {
            throw new InvalidOperationException(
                "Extension App ID is not configured. Please set Migration.ExternalId.ExtensionAppId in your configuration.");
        }

        if (_options.ExternalId.ExtensionAppId.Contains("-"))
        {
            throw new InvalidOperationException(
                $"Extension App ID must not contain dashes. Current value: {_options.ExternalId.ExtensionAppId}. " +
                "Please remove all dashes from the GUID.");
        }

        _logger.LogInformation("Import configuration:");
        _logger.LogInformation("  - Import queue           : {Queue}", _options.Import.QueueName);
        _logger.LogInformation("  - Attribute mappings     : {Count}", _options.Import.AttributeMappings.Count);
        _logger.LogInformation("  - Exclude fields         : {Count}", _options.Import.ExcludeFields.Count);
        _logger.LogInformation("  - Store B2C ObjectId     : {StoreB2C}", _options.Import.MigrationAttributes.StoreB2CObjectId);
        _logger.LogInformation("  - Set RequireMigration   : {SetMigrated}", _options.Import.MigrationAttributes.SetRequireMigration);
        _logger.LogInformation("  - EnqueuePhoneRegistration: {EnqueuePhone}", _options.Import.PhoneRegistration.EnqueuePhoneRegistration);

        if (_options.Import.MigrationAttributes.StoreB2CObjectId)
        {
            var b2cAttr = GetB2CObjectIdAttributeName();
            _logger.LogInformation("  - B2CObjectId target     : {Attr}", b2cAttr);
        }

        if (_options.Import.MigrationAttributes.SetRequireMigration)
        {
            var requireMigrationAttr = GetRequireMigrationAttributeName();
            _logger.LogInformation("  - Migration flag target  : {Attr} (will be set to true)", requireMigrationAttr);
        }

        if (_options.Import.AttributeMappings.Any())
        {
            _logger.LogInformation("Attribute mappings:");
            foreach (var mapping in _options.Import.AttributeMappings)
            {
                _logger.LogInformation("  - {Source} → {Target}", mapping.Key, mapping.Value);
            }
        }

        _logger.LogWarning(
            "⚠️  IMPORTANT: Ensure all target custom attributes exist in External ID tenant at " +
            "External Identities > Custom user attributes. " +
            "If they don't exist, worker-import will fail. " +
            "See User Guide for instructions on creating them.");
    }

    private void ApplyAttributeMappings(UserProfile user)
    {
        if (_options.Import.AttributeMappings.Any())
        {
            var mappedAttributes = new Dictionary<string, object>();

            foreach (var kvp in user.ExtensionAttributes)
            {
                var sourceAttr = kvp.Key;
                var value = kvp.Value;

                if (_options.Import.AttributeMappings.ContainsKey(sourceAttr))
                {
                    var targetAttr = _options.Import.AttributeMappings[sourceAttr];
                    mappedAttributes[targetAttr] = value;

                    if (_options.VerboseLogging)
                        _logger.LogDebug("Mapping attribute {Source} → {Target}", sourceAttr, targetAttr);
                }
                else if (!_options.Import.ExcludeFields.Contains(sourceAttr))
                {
                    mappedAttributes[sourceAttr] = value;
                }
                else if (_options.VerboseLogging)
                {
                    _logger.LogDebug("Excluding attribute {Attr}", sourceAttr);
                }
            }

            user.ExtensionAttributes = mappedAttributes;
        }
        else if (_options.Import.ExcludeFields.Any())
        {
            foreach (var excludeField in _options.Import.ExcludeFields)
            {
                if (user.ExtensionAttributes.Remove(excludeField) && _options.VerboseLogging)
                    _logger.LogDebug("Excluding attribute {Attr}", excludeField);
            }
        }
    }

    private string GetB2CObjectIdAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.B2CObjectIdTarget))
            return _options.Import.MigrationAttributes.B2CObjectIdTarget;

        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.B2CObjectId);
    }

    private string GetRequireMigrationAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.RequireMigrationTarget))
            return _options.Import.MigrationAttributes.RequireMigrationTarget;

        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.RequiresMigration);
    }

    private string TransformUpnForExternalId(string b2cUpn)
    {
        if (string.IsNullOrEmpty(b2cUpn))
            return b2cUpn;

        var atIndex = b2cUpn.IndexOf('@');
        if (atIndex == -1)
            return b2cUpn;

        var localPart = b2cUpn.Substring(0, atIndex);

        if (string.IsNullOrEmpty(localPart))
            localPart = Guid.NewGuid().ToString("N").Substring(0, 8);

        var newUpn = $"{localPart}@{_options.ExternalId.TenantDomain}";

        if (_options.VerboseLogging)
            _logger.LogDebug("Transformed UPN: {OldUpn} → {NewUpn}", b2cUpn, newUpn);

        return newUpn;
    }

    private void EnsureEmailIdentity(UserProfile user)
    {
        var hasEmailIdentity = user.Identities?.Any(i =>
            string.Equals(i.SignInType, "emailAddress", StringComparison.OrdinalIgnoreCase)) ?? false;

        if (!hasEmailIdentity)
        {
            var email = user.Mail;

            if (string.IsNullOrEmpty(email))
            {
                email = user.UserPrincipalName;

                if (_options.VerboseLogging)
                {
                    _logger.LogWarning(
                        "User {UPN} has no email in 'mail' field. Using userPrincipalName as email fallback.",
                        user.UserPrincipalName);
                }
            }

            user.Identities ??= new List<ObjectIdentity>();
            user.Identities.Add(new ObjectIdentity
            {
                SignInType = "emailAddress",
                Issuer = _options.ExternalId.TenantDomain,
                IssuerAssignedId = email
            });

            if (_options.VerboseLogging)
                _logger.LogDebug("Added email identity (password-based): {Email}", email);
        }
    }

    private static string GenerateRandomPassword()
    {
        const string uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lowercase = "abcdefghijkmnpqrstuvwxyz";
        const string digits = "23456789";
        const string special = "!@#$%^&*";
        const string allChars = uppercase + lowercase + digits + special;

        var random = new Random();
        var password = new List<char>();

        password.Add(uppercase[random.Next(uppercase.Length)]);
        password.Add(lowercase[random.Next(lowercase.Length)]);
        password.Add(digits[random.Next(digits.Length)]);
        password.Add(special[random.Next(special.Length)]);

        for (int i = 4; i < 16; i++)
            password.Add(allChars[random.Next(allChars.Length)]);

        for (int i = password.Count - 1; i > 0; i--)
        {
            int j = random.Next(i + 1);
            (password[i], password[j]) = (password[j], password[i]);
        }

        return new string(password.ToArray());
    }
}


        // Track aggregated metrics for cost estimation
        long totalBlobBytesRead = 0;
        int totalGraphApiCalls = 0;

        try
        {
            _logger.LogInformation("Starting External ID user import");
            _telemetry.TrackEvent("Import.Started");

            // Validate extension attributes configuration
            ValidateExtensionAttributes();

            // Ensure import audit container exists
            await _blobClient.EnsureContainerExistsAsync(
                _options.Storage.ImportAuditContainerName,
                cancellationToken);

            _logger.LogInformation("Import audit logs will be saved to container: {Container}",
                _options.Storage.ImportAuditContainerName);

            // ---------------------------------------------------------------
            // Load phone-harvest lookup (phones_*.json blobs written by phone-harvest workers)
            // ---------------------------------------------------------------
            var phoneLookup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var phoneBlobs = (await _blobClient.ListBlobsAsync(
                _options.Storage.ExportContainerName,
                "phones_",
                cancellationToken)).ToList();

            foreach (var phoneBlobName in phoneBlobs)
            {
                try
                {
                    var phoneJson = await _blobClient.ReadBlobAsync(
                        _options.Storage.ExportContainerName,
                        phoneBlobName,
                        cancellationToken);
                    var phoneEntries = JsonSerializer.Deserialize<List<PhoneLookupEntry>>(phoneJson);
                    if (phoneEntries != null)
                    {
                        foreach (var entry in phoneEntries)
                        {
                            phoneLookup[entry.UserId] = entry.PhoneNumber;
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Could not read phone lookup blob {Blob} — skipping.", phoneBlobName);
                }
            }

            _logger.LogInformation(
                "Phone lookup loaded: {Count:N0} users have an MFA phone number (from {BlobCount} phone blobs).",
                phoneLookup.Count, phoneBlobs.Count());

            // ---------------------------------------------------------------
            // List all export blobs
            var blobs = await _blobClient.ListBlobsAsync(
                _options.Storage.ExportContainerName,
                _options.Storage.ExportBlobPrefix,
                cancellationToken);

            var blobList = blobs.OrderBy(b => b).ToList();
            _logger.LogInformation("Found {Count} export files to process", blobList.Count);

            foreach (var blobName in blobList)
            {
                if (cancellationToken.IsCancellationRequested) break;

                try
                {
                    // Read users from blob
                    var json = await _blobClient.ReadBlobAsync(
                        _options.Storage.ExportContainerName,
                        blobName,
                        cancellationToken);

                    // Track blob bytes for cost estimation
                    totalBlobBytesRead += System.Text.Encoding.UTF8.GetByteCount(json);

                    var users = JsonSerializer.Deserialize<List<UserProfile>>(json);

                    if (users == null || !users.Any())
                    {
                        _logger.LogWarning("Blob {Blob} contains no users", blobName);
                        continue;
                    }

                    _logger.LogInformation("Processing {Count} users from {Blob}", users.Count, blobName);

                    var batchNumber = 0;

                    // Process users in batches
                    foreach (var batch in users.Chunk(_options.BatchSize))
                    {
                        var batchStartTime = DateTimeOffset.UtcNow;
                        var originalUserIds = new Dictionary<int, string>();

                        // Store original IDs for audit log
                        for (int i = 0; i < batch.Length; i++)
                        {
                            originalUserIds[i] = batch[i].Id ?? "unknown";
                        }
                        // Prepare users for import
                        foreach (var user in batch)
                        {
                            // Enrich with MFA phone number from phone-harvest phase
                            if (user.Id != null && phoneLookup.TryGetValue(user.Id, out var mfaPhone))
                            {
                                user.MfaPhoneNumber = mfaPhone;
                            }

                            // Apply attribute mappings and transformations
                            ApplyAttributeMappings(user);

                            // Store original B2C ObjectId (if configured)
                            if (_options.Import.MigrationAttributes.StoreB2CObjectId)
                            {
                                var b2cObjectIdAttr = GetB2CObjectIdAttributeName();
                                user.ExtensionAttributes[b2cObjectIdAttr] = user.Id!;

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("Storing B2C ObjectId {ObjectId} as {AttrName}", user.Id, b2cObjectIdAttr);
                                }
                            }

                            // Set RequiresMigration flag (if configured)
                            if (_options.Import.MigrationAttributes.SetRequireMigration)
                            {
                                var requireMigrationAttr = GetRequireMigrationAttributeName();
                                user.ExtensionAttributes[requireMigrationAttr] = true; // Set to true - user REQUIRES JIT migration on first login

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("Setting migration flag to true (requires migration) as {AttrName}", requireMigrationAttr);
                                }
                            }

                            // Transform UPN from B2C to External ID compatible format
                            if (!string.IsNullOrEmpty(user.UserPrincipalName))
                            {
                                user.UserPrincipalName = TransformUpnForExternalId(user.UserPrincipalName);
                            }

                            // Ensure user has an email identity (required for OTP and password reset in External ID)
                            EnsureEmailIdentity(user);

                            // Update identities issuer and issuerAssignedId
                            if (user.Identities != null && user.Identities.Any())
                            {
                                foreach (var identity in user.Identities)
                                {
                                    // ALWAYS update issuer to External ID domain (for cross-tenant migration)
                                    // This is required because External ID validates that issuer matches tenant domain
                                    identity.Issuer = _options.ExternalId.TenantDomain;

                                    // Preserve userPrincipalName identity (External ID supports it)
                                    // Only update the domain in the issuerAssignedId
                                    if (identity.SignInType?.ToLower() == "userprincipalname" &&
                                        !string.IsNullOrEmpty(identity.IssuerAssignedId))
                                    {
                                        // Keep signInType as "userPrincipalName" (don't convert to userName)
                                        // Update the issuerAssignedId domain to External ID tenant
                                        identity.IssuerAssignedId = TransformUpnForExternalId(identity.IssuerAssignedId);
                                    }
                                }

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("User has {Count} identities: {Types}",
                                        user.Identities.Count,
                                        string.Join(", ", user.Identities.Select(i => i.SignInType)));
                                }
                            }

                            // Set random password with forceChangePasswordNextSignIn = false
                            // External ID requires false for JIT migration scenarios
                            user.PasswordProfile = new PasswordProfile
                            {
                                Password = GenerateRandomPassword(),
                                ForceChangePasswordNextSignIn = false
                            };
                        }

                        // Batch create users
                        var result = await _externalIdGraphClient.CreateUsersBatchAsync(
                            batch,
                            cancellationToken);

                        // Track Graph API call for cost estimation
                        totalGraphApiCalls++;

                        summary.TotalItems += result.TotalItems;
                        summary.SuccessCount += result.SuccessCount;
                        summary.FailureCount += result.FailureCount;
                        summary.SkippedCount += result.SkippedCount;

                        if (result.WasThrottled)
                        {
                            summary.ThrottleCount++;
                        }

                        _logger.LogInformation("Batch result: {Success} succeeded, {Skipped} skipped (already exist), {Failed} failed",
                            result.SuccessCount, result.SkippedCount, result.FailureCount);

                        // Update extension attributes for duplicate users if configured
                        if (_options.Import.MigrationAttributes.OverwriteExtensionAttributes && result.DuplicateUsers.Any())
                        {
                            _logger.LogInformation("OverwriteExtensionAttributes enabled - updating {Count} duplicate users",
                                result.DuplicateUsers.Count);

                            var updateCount = await UpdateExtensionAttributesForDuplicatesAsync(
                                result.DuplicateUsers,
                                cancellationToken);

                            _logger.LogInformation("Updated extension attributes for {Count} duplicate users", updateCount);
                        }

                        // Enqueue phone-registration tasks for users with a mobile phone (opt-in)
                        if (_options.Import.PhoneRegistration.EnqueuePhoneRegistration)
                        {
                            await EnqueuePhoneRegistrationTasksAsync(batch, result, cancellationToken);
                        }

                        // Create and save audit log for this batch
                        var auditLog = CreateAuditLog(
                            blobName,
                            batchNumber,
                            batch,
                            originalUserIds,
                            result,
                            batchStartTime);

                        await SaveAuditLogAsync(auditLog, blobName, batchNumber, cancellationToken);

                        batchNumber++;

                        // Add delay between batches
                        if (_options.BatchDelayMs > 0)
                        {
                            await Task.Delay(_options.BatchDelayMs, cancellationToken);
                        }
                    }

                    _telemetry.IncrementCounter("Import.BlobsProcessed");
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to process blob {Blob}", blobName);
                    summary.FailureCount++;
                }
            }

            summary.EndTime = DateTimeOffset.UtcNow;

            _logger.LogInformation(summary.ToString());

            // Track aggregated metrics for cost estimation
            _telemetry.TrackMetric("import.blob.read.bytes", totalBlobBytesRead);
            _telemetry.TrackMetric("import.graph.api.calls", totalGraphApiCalls);

            _telemetry.TrackEvent("Import.Completed", new Dictionary<string, string>
            {
                { "TotalUsers", summary.TotalItems.ToString() },
                { "SuccessCount", summary.SuccessCount.ToString() },
                { "SkippedCount", summary.SkippedCount.ToString() },
                { "FailureCount", summary.FailureCount.ToString() },
                { "Duration", summary.Duration.ToString() }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = summary.FailureCount == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Import failed");
            _telemetry.TrackException(ex);

            return new ExecutionResult
            {
                Success = false,
                ErrorMessage = ex.Message,
                Exception = ex,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
    }

    private void ValidateExtensionAttributes()
    {
        _logger.LogInformation("Validating extension attributes configuration...");

        if (string.IsNullOrWhiteSpace(_options.ExternalId.ExtensionAppId))
        {
            throw new InvalidOperationException(
                "Extension App ID is not configured. Please set Migration.ExternalId.ExtensionAppId in your configuration.");
        }

        // Check if Extension App ID contains dashes (common mistake)
        if (_options.ExternalId.ExtensionAppId.Contains("-"))
        {
            throw new InvalidOperationException(
                $"Extension App ID must not contain dashes. Current value: {_options.ExternalId.ExtensionAppId}. " +
                "Please remove all dashes from the GUID.");
        }

        _logger.LogInformation("Import configuration:");
        _logger.LogInformation("  - Attribute mappings: {Count}", _options.Import.AttributeMappings.Count);
        _logger.LogInformation("  - Exclude fields: {Count}", _options.Import.ExcludeFields.Count);
        _logger.LogInformation("  - Store B2C ObjectId: {StoreB2C}", _options.Import.MigrationAttributes.StoreB2CObjectId);
        _logger.LogInformation("  - Set RequireMigration: {SetMigrated}", _options.Import.MigrationAttributes.SetRequireMigration);

        if (_options.Import.MigrationAttributes.StoreB2CObjectId)
        {
            var b2cAttr = GetB2CObjectIdAttributeName();
            _logger.LogInformation("  - B2CObjectId target: {Attr}", b2cAttr);
        }

        if (_options.Import.MigrationAttributes.SetRequireMigration)
        {
            var requireMigrationAttr = GetRequireMigrationAttributeName();
            _logger.LogInformation("  - Migration flag target: {Attr} (will be set to true)", requireMigrationAttr);
        }

        if (_options.Import.AttributeMappings.Any())
        {
            _logger.LogInformation("Attribute mappings:");
            foreach (var mapping in _options.Import.AttributeMappings)
            {
                _logger.LogInformation("  - {Source} → {Target}", mapping.Key, mapping.Value);
            }
        }

        _logger.LogWarning(
            "⚠️  IMPORTANT: Ensure all target custom attributes exist in External ID tenant at " +
            "External Identities > Custom user attributes. " +
            "If they don't exist, the import will fail. " +
            "See User Guide for instructions on creating them.");
    }

    private void ApplyAttributeMappings(UserProfile user)
    {
        // Apply attribute name mappings
        if (_options.Import.AttributeMappings.Any())
        {
            var mappedAttributes = new Dictionary<string, object>();

            foreach (var kvp in user.ExtensionAttributes)
            {
                var sourceAttr = kvp.Key;
                var value = kvp.Value;

                // Check if this attribute should be mapped to a different name
                if (_options.Import.AttributeMappings.ContainsKey(sourceAttr))
                {
                    var targetAttr = _options.Import.AttributeMappings[sourceAttr];
                    mappedAttributes[targetAttr] = value;

                    if (_options.VerboseLogging)
                    {
                        _logger.LogDebug("Mapping attribute {Source} → {Target}", sourceAttr, targetAttr);
                    }
                }
                else if (!_options.Import.ExcludeFields.Contains(sourceAttr))
                {
                    // Keep as-is if not excluded
                    mappedAttributes[sourceAttr] = value;
                }
                else if (_options.VerboseLogging)
                {
                    _logger.LogDebug("Excluding attribute {Attr}", sourceAttr);
                }
            }

            user.ExtensionAttributes = mappedAttributes;
        }
        else if (_options.Import.ExcludeFields.Any())
        {
            // Just apply exclusions if no mappings
            foreach (var excludeField in _options.Import.ExcludeFields)
            {
                if (user.ExtensionAttributes.Remove(excludeField) && _options.VerboseLogging)
                {
                    _logger.LogDebug("Excluding attribute {Attr}", excludeField);
                }
            }
        }
    }

    private string GetB2CObjectIdAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.B2CObjectIdTarget))
        {
            return _options.Import.MigrationAttributes.B2CObjectIdTarget;
        }

        // Default: extension_{appId}_B2CObjectId
        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.B2CObjectId);
    }

    private string GetRequireMigrationAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.RequireMigrationTarget))
        {
            return _options.Import.MigrationAttributes.RequireMigrationTarget;
        }

        // Default: extension_{appId}_RequireMigration
        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.RequiresMigration);
    }

    private ImportAuditLog CreateAuditLog(
        string sourceBlobName,
        int batchNumber,
        UserProfile[] batch,
        Dictionary<int, string> originalUserIds,
        BatchResult result,
        DateTimeOffset batchStartTime)
    {
        var auditLog = new ImportAuditLog
        {
            Timestamp = DateTimeOffset.UtcNow,
            SourceBlobName = sourceBlobName,
            BatchNumber = batchNumber,
            TotalUsers = batch.Length,
            SuccessCount = result.SuccessCount,
            FailureCount = result.FailureCount,
            SkippedCount = result.SkippedCount,
            DurationMs = (DateTimeOffset.UtcNow - batchStartTime).TotalMilliseconds
        };

        // Categorize users based on batch result
        for (int i = 0; i < batch.Length; i++)
        {
            var user = batch[i];
            var originalId = originalUserIds.ContainsKey(i) ? originalUserIds[i] : "unknown";
            var upn = user.UserPrincipalName ?? "unknown";

            // Check if this user was skipped (duplicate)
            if (result.SkippedUserIds.Contains(upn))
            {
                auditLog.SkippedUsers.Add(new SkippedUserRecord
                {
                    B2CObjectId = originalId,
                    UserPrincipalName = upn,
                    DisplayName = user.DisplayName ?? "unknown",
                    Reason = "Duplicate - User already exists",
                    SkippedAt = DateTimeOffset.UtcNow
                });
            }
            // Otherwise assume success (failures would need more detailed tracking)
            else if (result.SuccessCount > 0)
            {
                auditLog.SuccessfulUsers.Add(new ImportedUserRecord
                {
                    B2CObjectId = originalId,
                    ExternalIdObjectId = user.Id ?? "created",
                    UserPrincipalName = upn,
                    DisplayName = user.DisplayName ?? "unknown",
                    ImportedAt = DateTimeOffset.UtcNow
                });
            }
        }

        // Note: Failed users are tracked via result.Failures
        // For detailed failure tracking, we would need to enhance the batch operation response handling

        return auditLog;
    }

    private async Task SaveAuditLogAsync(
        ImportAuditLog auditLog,
        string sourceBlobName,
        int batchNumber,
        CancellationToken cancellationToken)
    {
        try
        {
            // Generate audit log blob name: import-audit_{sourceBlobName}_batch{batchNumber}_{timestamp}.json
            var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss");
            var cleanBlobName = sourceBlobName.Replace(".json", "").Replace(_options.Storage.ExportBlobPrefix, "");
            var auditBlobName = $"import-audit_{cleanBlobName}_batch{batchNumber:D3}_{timestamp}.json";

            var json = JsonSerializer.Serialize(auditLog, new JsonSerializerOptions
            {
                WriteIndented = true
            });

            await _blobClient.WriteBlobAsync(
                _options.Storage.ImportAuditContainerName,
                auditBlobName,
                json,
                cancellationToken);

            if (_options.VerboseLogging)
            {
                _logger.LogDebug("Saved audit log: {AuditBlobName}", auditBlobName);
            }

            _telemetry.IncrementCounter("Import.AuditLogsSaved");
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to save audit log for batch {BatchNumber} from {SourceBlob}",
                batchNumber, sourceBlobName);
            // Don't fail the import if audit log save fails
        }
    }

    private string TransformUpnForExternalId(string b2cUpn)
    {
        // Transform B2C UPN to External ID compatible format by replacing domain only
        // Examples:
        //   testuser@b2c.onmicrosoft.com → testuser@externalid.onmicrosoft.com
        //   user@source.onmicrosoft.com → user@target.onmicrosoft.com
        //   05001e5c-946f-49d6-ba39-23d5292d1c3d@b2c.onmicrosoft.com → 05001e5c-946f-49d6-ba39-23d5292d1c3d@externalid.onmicrosoft.com

        if (string.IsNullOrEmpty(b2cUpn))
            return b2cUpn;

        var atIndex = b2cUpn.IndexOf('@');
        if (atIndex == -1)
            return b2cUpn; // Invalid format, return as-is

        // Preserve the local part (everything before @) exactly as-is
        var localPart = b2cUpn.Substring(0, atIndex);
        
        // Ensure local part is not empty
        if (string.IsNullOrEmpty(localPart))
        {
            localPart = Guid.NewGuid().ToString("N").Substring(0, 8); // Use first 8 chars of GUID
        }

        // Replace domain with External ID tenant domain
        var newUpn = $"{localPart}@{_options.ExternalId.TenantDomain}";

        if (_options.VerboseLogging)
        {
            _logger.LogDebug("Transformed UPN: {OldUpn} → {NewUpn}", b2cUpn, newUpn);
        }

        return newUpn;
    }

    private void EnsureEmailIdentity(UserProfile user)
    {
        // Check if user already has an emailAddress identity
        var hasEmailIdentity = user.Identities?.Any(i =>
            string.Equals(i.SignInType, "emailAddress", StringComparison.OrdinalIgnoreCase)) ?? false;

        if (!hasEmailIdentity)
        {
            // Determine email to use:
            // 1. Prefer mail field if available
            // 2. Fallback to userPrincipalName if user only has userName + userPrincipalName (no email in B2C)
            var email = user.Mail;

            if (string.IsNullOrEmpty(email))
            {
                // No email in mail field - use userPrincipalName as email
                // This handles B2C users with only userName + userPrincipalName identities
                email = user.UserPrincipalName;
                
                if (_options.VerboseLogging)
                {
                    _logger.LogWarning("User {UPN} has no email in 'mail' field. Using userPrincipalName as email fallback.", 
                        user.UserPrincipalName);
                }
            }

            // Add emailAddress identity for Email + Password (with JIT migration)
            user.Identities ??= new List<ObjectIdentity>();
            user.Identities.Add(new ObjectIdentity
            {
                SignInType = "emailAddress",
                Issuer = _options.ExternalId.TenantDomain,
                IssuerAssignedId = email
            });
            
            if (_options.VerboseLogging)
            {
                _logger.LogDebug("Added email identity (password-based): {Email}", email);
            }
        }
    }

    private static string MaskPhoneNumber(string phoneNumber)
    {
        if (string.IsNullOrEmpty(phoneNumber) || phoneNumber.Length < 4)
            return "***";

        // Show last 4 digits only
        return $"***{phoneNumber.Substring(phoneNumber.Length - 4)}";
    }

    private static string GenerateRandomPassword()
    {
        // External ID password requirements:
        // - Minimum 8 characters
        // - At least one uppercase letter
        // - At least one lowercase letter
        // - At least one digit
        // - At least one special character
        
        const string uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lowercase = "abcdefghijkmnpqrstuvwxyz";
        const string digits = "23456789";
        const string special = "!@#$%^&*";
        const string allChars = uppercase + lowercase + digits + special;
        
        var random = new Random();
        var password = new List<char>();
        
        // Guarantee at least one of each required type
        password.Add(uppercase[random.Next(uppercase.Length)]);
        password.Add(lowercase[random.Next(lowercase.Length)]);
        password.Add(digits[random.Next(digits.Length)]);
        password.Add(special[random.Next(special.Length)]);
        
        // Fill remaining 12 characters randomly
        for (int i = 4; i < 16; i++)
        {
            password.Add(allChars[random.Next(allChars.Length)]);
        }
        
        // Shuffle to avoid predictable pattern (first chars always have one of each type)
        for (int i = password.Count - 1; i > 0; i--)
        {
            int j = random.Next(i + 1);
            (password[i], password[j]) = (password[j], password[i]);
        }
        
        return new string(password.ToArray());
    }

    /// <summary>
    /// Updates extension attributes for duplicate users (users that already exist).
    /// Used when OverwriteExtensionAttributes is enabled.
    /// </summary>
    private async Task<int> UpdateExtensionAttributesForDuplicatesAsync(
        List<UserProfile> duplicateUsers,
        CancellationToken cancellationToken)
    {
        int updateCount = 0;
        var b2cAttr = MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.B2CObjectId);
        var requireMigrationAttr = GetRequireMigrationAttributeName();

        foreach (var user in duplicateUsers)
        {
            try
            {
                // Find user by UPN using filter
                var filter = $"userPrincipalName eq '{user.UserPrincipalName}'";
                var result = await _externalIdGraphClient.GetUsersAsync(
                    pageSize: 1,
                    select: $"id,{b2cAttr},{requireMigrationAttr}",
                    filter: filter,
                    cancellationToken: cancellationToken);

                var existingUser = result.Items.FirstOrDefault();
                if (existingUser == null)
                {
                    _logger.LogWarning("Could not find existing user {UPN} for extension attribute update", 
                        user.UserPrincipalName);
                    continue;
                }

                // Prepare extension attribute updates
                var updates = new Dictionary<string, object>();

                if (_options.Import.MigrationAttributes.StoreB2CObjectId && user.ExtensionAttributes.ContainsKey(b2cAttr))
                {
                    updates[b2cAttr] = user.ExtensionAttributes[b2cAttr];
                }

                if (_options.Import.MigrationAttributes.SetRequireMigration && user.ExtensionAttributes.ContainsKey(requireMigrationAttr))
                {
                    updates[requireMigrationAttr] = user.ExtensionAttributes[requireMigrationAttr];
                }

                if (updates.Any())
                {
                    await _externalIdGraphClient.UpdateUserAsync(existingUser.Id!, updates, cancellationToken);
                    updateCount++;
                    _logger.LogDebug("Updated extension attributes for user {UPN}", user.UserPrincipalName);
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to update extension attributes for duplicate user {UPN}", 
                    user.UserPrincipalName);
            }
        }

        return updateCount;
    }

    /// <summary>
    /// Enqueues phone-registration tasks for users in the batch that have a mobile phone
    /// and were not hard-failed during creation.
    /// Called only when <see cref="PhoneRegistrationImportOptions.EnqueuePhoneRegistration"/> is true.
    /// </summary>
    private async Task EnqueuePhoneRegistrationTasksAsync(
        UserProfile[] batch,
        BatchResult batchResult,
        CancellationToken cancellationToken)
    {
        var phoneQueueName = _options.PhoneRegistration.QueueName;

        // Ensure queue exists (idempotent)
        await _queueClient.CreateQueueIfNotExistsAsync(phoneQueueName, cancellationToken);

        // Build a set of failed batch indices so we can skip users that were never created
        var failedIndices = new HashSet<int>(batchResult.Failures.Select(f => f.Index));

        int enqueued = 0;
        int skipped = 0;

        for (int i = 0; i < batch.Length; i++)
        {
            var user = batch[i];

            // Skip users whose creation hard-failed (they don't exist in EEID)
            if (failedIndices.Contains(i))
            {
                skipped++;
                continue;
            }

            if (string.IsNullOrWhiteSpace(user.MfaPhoneNumber) ||
                string.IsNullOrWhiteSpace(user.UserPrincipalName))
            {
                skipped++;
                continue;
            }

            var msg = new PhoneRegistrationMessage
            {
                Upn = user.UserPrincipalName,
                PhoneNumber = user.MfaPhoneNumber
            };

            var json = JsonSerializer.Serialize(msg);
            await _queueClient.SendMessageAsync(phoneQueueName, json, cancellationToken);
            enqueued++;
        }

        if (enqueued > 0 || _options.VerboseLogging)
        {
            _logger.LogInformation(
                "[PhoneReg] Enqueued {Count} phone-registration tasks (skipped {Skip} — no phone or creation failed)",
                enqueued, skipped);
        }

        _telemetry.IncrementCounter("Import.PhoneRegistrationEnqueued", enqueued);
    }
}
