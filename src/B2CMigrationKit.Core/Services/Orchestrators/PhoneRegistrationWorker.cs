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
/// Asynchronous worker that consumes the phone-registration queue and registers each
/// user's MFA phone number in Entra External ID via POST /authentication/phoneMethods.
///
/// Design rationale
/// ----------------
/// The /authentication/phoneMethods endpoint has a much lower throttle budget than the
/// main /users endpoint. Running it inline during WorkerMigrateOrchestrator would stall
/// the entire create pipeline. Instead, WorkerMigrateOrchestrator enqueues lightweight
/// { B2CUserId, EEIDUpn } messages (no phone number stored in the queue), and this worker
/// fetches the phone number from B2C at drain time, then registers it in EEID.
///
/// Throttle strategy
/// -----------------
/// The phoneMethods API has a significantly lower throttle budget than the main Users API.
/// GET and POST/PATCH calls count together against the same per-app budget.
///
/// Each message = 1 GET (B2C tenant) + 1 POST (EEID tenant). Because B2C and EEID are
/// different tenants, each call is counted against a different tenant's quota — they do not
/// share a budget. ThrottleDelayMs controls throughput on the client side; increase it if
/// you observe sustained HTTP 429 responses on either tenant.
///
/// - A fixed <see cref="PhoneRegistrationOptions.ThrottleDelayMs"/> delay is applied after
///   every processed message (success or failure). This hard-limits throughput to
///   ~(1000 / ThrottleDelayMs) pairs/second regardless of concurrency.
/// - Transient errors (including 429) are retried by the GraphClient's Polly pipeline with
///   exponential back-off.  If all retries are exhausted the message is NOT deleted; it
///   becomes visible again after the visibility timeout for another attempt.
/// - HTTP 409 (already registered) is treated as success by GraphClient.RegisterPhoneAuthMethodAsync.
/// - All outcomes (PhoneRegistered / PhoneSkipped / PhoneFailed) are written to Azure
///   Table Storage via <see cref="ITableStorageClient"/>.
/// </summary>
public class PhoneRegistrationWorker : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IGraphClient _eeidGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly ITableStorageClient _tableClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<PhoneRegistrationWorker> _logger;
    private readonly MigrationOptions _options;

    public PhoneRegistrationWorker(
        IGraphClient b2cGraphClient,
        IGraphClient eeidGraphClient,
        IQueueClient queueClient,
        ITableStorageClient tableClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<PhoneRegistrationWorker> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _eeidGraphClient = eeidGraphClient ?? throw new ArgumentNullException(nameof(eeidGraphClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _tableClient = tableClient ?? throw new ArgumentNullException(nameof(tableClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var opts = _options.PhoneRegistration;
        var queueName = opts.QueueName;
        var visibilityTimeout = TimeSpan.FromSeconds(opts.MessageVisibilityTimeoutSeconds);

        var summary = new RunSummary
        {
            OperationName = "Phone Auth Method Registration",
            StartTime = DateTimeOffset.UtcNow
        };

        var auditTable = _options.Storage.AuditTableName;

        _logger.LogInformation(
            "[PhoneReg] Starting worker | Queue: {Queue} | ThrottleDelay: {Delay}ms | Concurrency: {Concurrency} | VisibilityTimeout: {Timeout}s | AuditTable: {Table}",
            queueName, opts.ThrottleDelayMs, opts.MaxConcurrency, opts.MessageVisibilityTimeoutSeconds, auditTable);

        _telemetry.TrackEvent("PhoneRegistration.Started");

        try
        {
            await _queueClient.CreateQueueIfNotExistsAsync(queueName, cancellationToken);
            await _tableClient.EnsureTableExistsAsync(auditTable, cancellationToken);

            int emptyPolls = 0;
            int processed = 0;
            int succeeded = 0;
            int failed = 0;
            using var semaphore = new SemaphoreSlim(opts.MaxConcurrency);
            var activeTasks = new List<Task>();

            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await _queueClient.ReceiveMessageAsync(
                    queueName,
                    visibilityTimeout,
                    cancellationToken);

                if (message is null)
                {
                    emptyPolls++;

                    if (opts.MaxEmptyPolls > 0 && emptyPolls >= opts.MaxEmptyPolls)
                    {
                        _logger.LogInformation(
                            "[PhoneReg] Queue empty after {Count} consecutive polls — stopping worker.",
                            emptyPolls);
                        break;
                    }

                    _logger.LogDebug("[PhoneReg] Queue empty, waiting {Delay}ms before next poll...",
                        opts.EmptyQueuePollDelayMs);
                    await Task.Delay(opts.EmptyQueuePollDelayMs, cancellationToken);
                    continue;
                }

                // Reset empty-poll counter on any message received
                emptyPolls = 0;
                Interlocked.Increment(ref processed);

                var (messageId, popReceipt, messageText) = message.Value;

                PhoneRegistrationMessage? phoneTask = null;
                try
                {
                    phoneTask = JsonSerializer.Deserialize<PhoneRegistrationMessage>(
                        messageText,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                }
                catch (JsonException ex)
                {
                    _logger.LogError(ex,
                        "[PhoneReg] ❌ Failed to deserialize message {Id} — skipping and deleting.", messageId);
                    await SafeDeleteAsync(queueName, messageId, popReceipt, cancellationToken);
                    Interlocked.Increment(ref failed);
                    continue;
                }

                if (phoneTask is null || string.IsNullOrWhiteSpace(phoneTask.B2CUserId) || string.IsNullOrWhiteSpace(phoneTask.EEIDUpn))
                {
                    _logger.LogWarning(
                        "[PhoneReg] Message {Id} is missing B2CUserId or EEIDUpn — deleting.", messageId);
                    await SafeDeleteAsync(queueName, messageId, popReceipt, cancellationToken);
                    Interlocked.Increment(ref failed);
                    continue;
                }

                _logger.LogDebug(
                    "[PhoneReg] Processing B2CUserId: {B2CId} | EEIDUpn: {Upn} | RetryCount: {Retry}",
                    phoneTask.B2CUserId, phoneTask.EEIDUpn, phoneTask.RetryCount);

                await semaphore.WaitAsync(cancellationToken);

                // Capture loop variables for the closure
                var capturedMessageId  = messageId;
                var capturedPopReceipt = popReceipt;
                var capturedTask       = phoneTask;

                var slotTask = Task.Run(async () =>
                {
                    try
                    {
                        var opStart = DateTimeOffset.UtcNow;
                        try
                        {
                            // 1. Fetch MFA phone number from B2C (not stored in the queue message)
                            var phoneNumber = await _b2cGraphClient.GetMfaPhoneNumberAsync(
                                capturedTask.B2CUserId, cancellationToken);

                            if (string.IsNullOrWhiteSpace(phoneNumber))
                            {
                                var skipMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;
                                _logger.LogInformation(
                                    "[PhoneReg] No phone found for B2CUserId {B2CId} ({Upn}) — skipping.",
                                    capturedTask.B2CUserId, capturedTask.EEIDUpn);

                                await _tableClient.UpsertAuditRecordAsync(
                                    MigrationAuditRecord.CreatePhone(
                                        capturedTask.B2CUserId, capturedTask.EEIDUpn, "PhoneSkipped", skipMs),
                                    auditTable, cancellationToken);

                                await SafeDeleteAsync(queueName, capturedMessageId, capturedPopReceipt, cancellationToken);
                                Interlocked.Increment(ref succeeded);
                                _telemetry.IncrementCounter("PhoneRegistration.Skipped");
                                return;
                            }

                            // 2. Register the phone in EEID
                            await _eeidGraphClient.RegisterPhoneAuthMethodAsync(
                                capturedTask.EEIDUpn, phoneNumber, cancellationToken);

                            var regMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;

                            await _tableClient.UpsertAuditRecordAsync(
                                MigrationAuditRecord.CreatePhone(
                                    capturedTask.B2CUserId, capturedTask.EEIDUpn, "PhoneRegistered", regMs),
                                auditTable, cancellationToken);

                            await SafeDeleteAsync(queueName, capturedMessageId, capturedPopReceipt, cancellationToken);
                            Interlocked.Increment(ref succeeded);

                            _logger.LogInformation(
                                "[PhoneReg] Registered phone for {Upn} (B2C: {B2CId}) in {Ms}ms",
                                capturedTask.EEIDUpn, capturedTask.B2CUserId, regMs);

                            _telemetry.TrackEvent("PhoneRegistration.Success", new Dictionary<string, string>
                            {
                                { "EEIDUpn", capturedTask.EEIDUpn },
                                { "B2CUserId", capturedTask.B2CUserId }
                            });
                        }
                        catch (OperationCanceledException)
                        {
                            _logger.LogWarning("[PhoneReg] Operation cancelled — leaving message {Id} visible for retry.", capturedMessageId);
                        }
                        catch (Exception ex)
                        {
                            var failMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;
                            Interlocked.Increment(ref failed);

                            var errCode = ex is Microsoft.Graph.Models.ODataErrors.ODataError oErr
                                ? oErr.ResponseStatusCode.ToString()
                                : ex.GetType().Name;

                            await _tableClient.UpsertAuditRecordAsync(
                                MigrationAuditRecord.CreatePhone(
                                    capturedTask.B2CUserId, capturedTask.EEIDUpn, "PhoneFailed", failMs,
                                    errCode, ex.Message),
                                auditTable, cancellationToken);

                            _logger.LogWarning(ex,
                                "[PhoneReg] Failed to register phone for {Upn} / B2C {B2CId} (attempt {Attempt}) — will retry after visibility timeout.",
                                capturedTask.EEIDUpn, capturedTask.B2CUserId, capturedTask.RetryCount + 1);

                            _telemetry.TrackEvent("PhoneRegistration.Failed", new Dictionary<string, string>
                            {
                                { "EEIDUpn", capturedTask.EEIDUpn },
                                { "B2CUserId", capturedTask.B2CUserId },
                                { "RetryCount", capturedTask.RetryCount.ToString() },
                                { "Error", ex.Message }
                            });
                        }

                        // Per-slot throttle delay
                        if (!cancellationToken.IsCancellationRequested && opts.ThrottleDelayMs > 0)
                            await Task.Delay(opts.ThrottleDelayMs, cancellationToken);
                    }
                    finally
                    {
                        semaphore.Release();
                    }
                }, cancellationToken);

                activeTasks.Add(slotTask);

                // Prune completed tasks to keep the list bounded
                activeTasks.RemoveAll(t => t.IsCompleted);
            }

            // Wait for any in-flight slots before reporting summary
            await Task.WhenAll(activeTasks);

            summary.TotalItems = processed;
            summary.SuccessCount = succeeded;
            summary.FailureCount = failed;
            summary.EndTime = DateTimeOffset.UtcNow;

            _logger.LogInformation(
                "[PhoneReg] Worker finished | Processed: {Total} | Succeeded: {Ok} | Failed: {Fail} | Duration: {Duration}",
                processed, succeeded, failed, summary.Duration);

            _telemetry.TrackEvent("PhoneRegistration.Completed", new Dictionary<string, string>
            {
                { "Processed", processed.ToString() },
                { "Succeeded", succeeded.ToString() },
                { "Failed", failed.ToString() },
                { "Duration", summary.Duration.ToString() }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = failed == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;

            _logger.LogError(ex, "[PhoneReg] Fatal error in PhoneRegistrationWorker");
            _telemetry.TrackException(ex);

            return new ExecutionResult
            {
                Success = false,
                ErrorMessage = ex.Message,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
    }

    private async Task SafeDeleteAsync(
        string queueName,
        string messageId,
        string popReceipt,
        CancellationToken cancellationToken)
    {
        try
        {
            await _queueClient.DeleteMessageAsync(queueName, messageId, popReceipt, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "[PhoneReg] Failed to delete message {Id} from queue — it may be processed again.", messageId);
        }
    }

}
