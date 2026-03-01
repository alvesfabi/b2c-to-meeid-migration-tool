// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Extensions;
using B2CMigrationKit.Core.Models;
using B2CMigrationKit.Core.Services.Infrastructure;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Function;

/// <summary>
/// Azure Function that processes phone MFA migration messages from Azure Queue Storage.
/// Reads the B2CMfaPhone extension attribute from the user and registers it as a
/// mobile phone authentication method in External ID.
/// 
/// Primary path: triggered after JIT password migration (user's first login).
/// The queue decouples the phone registration from the 2-second JIT timeout.
/// </summary>
public class PhoneMigrationFunction
{
    private readonly IGraphClient _externalIdGraphClient;
    private readonly ITelemetryService _telemetry;
    private readonly MigrationOptions _options;
    private readonly ILogger<PhoneMigrationFunction> _logger;

    public PhoneMigrationFunction(
        ServiceCollectionExtensions.ExternalIdGraphClientWrapper externalIdGraphClientWrapper,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<PhoneMigrationFunction> logger)
    {
        _externalIdGraphClient = externalIdGraphClientWrapper?.Client ?? throw new ArgumentNullException(nameof(externalIdGraphClientWrapper));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    [Function("PhoneMigration")]
    public async Task RunAsync(
        [QueueTrigger("phone-migration", Connection = "AzureWebJobsStorage")] string messageText,
        FunctionContext context)
    {
        PhoneMigrationMessage? message = null;

        try
        {
            message = JsonSerializer.Deserialize<PhoneMigrationMessage>(messageText, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            if (message == null || string.IsNullOrEmpty(message.UserId))
            {
                _logger.LogWarning("[Phone Migration] Invalid message received: {Message}", messageText);
                return; // Don't retry invalid messages
            }

            _logger.LogInformation(
                "[Phone Migration] Processing | UserId: {UserId} | UPN: {UPN} | Source: {Source} | CorrelationId: {CorrelationId}",
                message.UserId, message.UserPrincipalName, message.Source, message.CorrelationId);

            _telemetry.TrackEvent("PhoneMigration.Started", new Dictionary<string, string>
            {
                { "UserId", message.UserId },
                { "Source", message.Source },
                { "CorrelationId", message.CorrelationId }
            });

            // Step 1: Check if user already has a mobile phone method
            var hasExistingPhone = await _externalIdGraphClient.HasPhoneAuthenticationMethodAsync(
                message.UserId);

            if (hasExistingPhone)
            {
                _logger.LogInformation(
                    "[Phone Migration] User already has mobile phone method, skipping | UserId: {UserId}",
                    message.UserId);

                _telemetry.TrackEvent("PhoneMigration.Skipped", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Reason", "AlreadyHasPhoneMethod" },
                    { "CorrelationId", message.CorrelationId }
                });
                return;
            }

            // Step 2: Read B2CMfaPhone extension attribute from user
            var b2cMfaPhoneAttr = MigrationExtensionAttributes.GetFullAttributeName(
                _options.ExternalId.ExtensionAppId,
                MigrationExtensionAttributes.B2CMfaPhone);

            var user = await _externalIdGraphClient.GetUserByIdAsync(
                message.UserId,
                select: $"id,{b2cMfaPhoneAttr}");

            if (user == null)
            {
                _logger.LogWarning(
                    "[Phone Migration] User not found in External ID | UserId: {UserId}",
                    message.UserId);

                _telemetry.TrackEvent("PhoneMigration.Failed", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Reason", "UserNotFound" },
                    { "CorrelationId", message.CorrelationId }
                });
                return;
            }

            // Extract phone number from extension attribute
            string? phoneNumber = null;
            if (user.ExtensionAttributes.TryGetValue(b2cMfaPhoneAttr, out var phoneValue))
            {
                phoneNumber = phoneValue?.ToString();
            }

            if (string.IsNullOrEmpty(phoneNumber))
            {
                _logger.LogInformation(
                    "[Phone Migration] No B2C MFA phone found for user, skipping | UserId: {UserId}",
                    message.UserId);

                _telemetry.TrackEvent("PhoneMigration.Skipped", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Reason", "NoB2CMfaPhone" },
                    { "CorrelationId", message.CorrelationId }
                });
                return;
            }

            // Step 3: Validate phone number format (no normalization needed —
            // phone numbers from B2C's phoneMethods API are already in Graph API format)
            if (!PhoneNumberHelper.IsValidPhoneNumber(phoneNumber))
            {
                _logger.LogWarning(
                    "[Phone Migration] Invalid phone number format, skipping | UserId: {UserId} | Phone: {Phone}",
                    message.UserId, MaskPhoneNumber(phoneNumber));

                _telemetry.TrackEvent("PhoneMigration.Failed", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Reason", "InvalidPhoneFormat" },
                    { "CorrelationId", message.CorrelationId }
                });
                return;
            }

            // Step 4: Register mobile phone authentication method
            var success = await _externalIdGraphClient.AddPhoneAuthenticationMethodAsync(
                message.UserId, phoneNumber);

            if (success)
            {
                _logger.LogInformation(
                    "[Phone Migration] Successfully registered phone method | UserId: {UserId} | Phone: {Phone} | Source: {Source}",
                    message.UserId, MaskPhoneNumber(phoneNumber), message.Source);

                _telemetry.TrackEvent("PhoneMigration.Completed", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Source", message.Source },
                    { "CorrelationId", message.CorrelationId }
                });

                // Step 5: Clean up - remove the extension attribute (optional, keeps user clean)
                try
                {
                    await _externalIdGraphClient.UpdateUserAsync(
                        message.UserId,
                        new Dictionary<string, object> { { b2cMfaPhoneAttr, null! } });

                    _logger.LogDebug(
                        "[Phone Migration] Cleared B2CMfaPhone extension attribute | UserId: {UserId}",
                        message.UserId);
                }
                catch (Exception ex)
                {
                    // Non-critical - log but don't fail
                    _logger.LogWarning(ex,
                        "[Phone Migration] Failed to clear B2CMfaPhone attribute (non-blocking) | UserId: {UserId}",
                        message.UserId);
                }
            }
            else
            {
                _logger.LogWarning(
                    "[Phone Migration] Failed to register phone method | UserId: {UserId}",
                    message.UserId);

                _telemetry.TrackEvent("PhoneMigration.Failed", new Dictionary<string, string>
                {
                    { "UserId", message.UserId },
                    { "Reason", "RegistrationFailed" },
                    { "CorrelationId", message.CorrelationId }
                });

                // Throwing will cause the message to be retried by Azure Functions
                throw new InvalidOperationException(
                    $"Failed to register phone method for user {message.UserId}");
            }
        }
        catch (JsonException jsonEx)
        {
            _logger.LogError(jsonEx,
                "[Phone Migration] Failed to deserialize queue message: {Message}", messageText);
            // Don't retry JSON parse errors
        }
        catch (InvalidOperationException)
        {
            // Re-throw registration failures for retry
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "[Phone Migration] Unexpected error | UserId: {UserId} | CorrelationId: {CorrelationId}",
                message?.UserId ?? "unknown", message?.CorrelationId ?? "unknown");

            _telemetry.TrackException(ex, new Dictionary<string, string>
            {
                { "UserId", message?.UserId ?? "unknown" },
                { "CorrelationId", message?.CorrelationId ?? "unknown" }
            });

            throw; // Retry
        }
    }

    private static string MaskPhoneNumber(string phoneNumber)
    {
        if (string.IsNullOrEmpty(phoneNumber) || phoneNumber.Length < 4)
            return "***";

        return $"***{phoneNumber.Substring(phoneNumber.Length - 4)}";
    }
}
