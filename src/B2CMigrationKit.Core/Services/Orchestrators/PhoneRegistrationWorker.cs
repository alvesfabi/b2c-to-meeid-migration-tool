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
/// main /users endpoint. Running it inline during import would stall the entire pipeline.
/// Instead, ImportOrchestrator just enqueues { upn, phoneNumber } messages, and this worker
/// drains the queue independently at a configurable, throttle-safe rate.
///
/// Throttle strategy
/// -----------------
/// - A fixed <see cref="PhoneRegistrationOptions.ThrottleDelayMs"/> delay is applied after
///   every API call (success or failure).  This hard-limits throughput to
///   ~(1000 / ThrottleDelayMs) calls/second regardless of concurrency.
/// - Transient errors (including 429) are retried by the GraphClient's Polly pipeline with
///   exponential back-off.  If all retries are exhausted the message is NOT deleted; it
///   becomes visible again after the visibility timeout for another attempt.
/// - HTTP 409 (already registered) is treated as success by GraphClient.RegisterPhoneAuthMethodAsync.
/// </summary>
public class PhoneRegistrationWorker : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _externalIdGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<PhoneRegistrationWorker> _logger;
    private readonly MigrationOptions _options;

    public PhoneRegistrationWorker(
        IGraphClient externalIdGraphClient,
        IQueueClient queueClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<PhoneRegistrationWorker> logger)
    {
        _externalIdGraphClient = externalIdGraphClient ?? throw new ArgumentNullException(nameof(externalIdGraphClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
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

        _logger.LogInformation(
            "[PhoneReg] Starting worker | Queue: {Queue} | ThrottleDelay: {Delay}ms | VisibilityTimeout: {Timeout}s",
            queueName, opts.ThrottleDelayMs, opts.MessageVisibilityTimeoutSeconds);

        _telemetry.TrackEvent("PhoneRegistration.Started");

        try
        {
            await _queueClient.CreateQueueIfNotExistsAsync(queueName, cancellationToken);

            int emptyPolls = 0;
            int processed = 0;
            int succeeded = 0;
            int failed = 0;

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
                processed++;

                var (messageId, popReceipt, messageText) = message.Value;

                PhoneRegistrationMessage? task = null;
                try
                {
                    task = JsonSerializer.Deserialize<PhoneRegistrationMessage>(
                        messageText,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                }
                catch (JsonException ex)
                {
                    _logger.LogError(ex,
                        "[PhoneReg] ❌ Failed to deserialize message {Id} — skipping and deleting.", messageId);
                    await SafeDeleteAsync(queueName, messageId, popReceipt, cancellationToken);
                    failed++;
                    continue;
                }

                if (task is null || string.IsNullOrWhiteSpace(task.Upn) || string.IsNullOrWhiteSpace(task.PhoneNumber))
                {
                    _logger.LogWarning(
                        "[PhoneReg] Message {Id} has empty UPN or phone number — deleting.", messageId);
                    await SafeDeleteAsync(queueName, messageId, popReceipt, cancellationToken);
                    failed++;
                    continue;
                }

                _logger.LogDebug(
                    "[PhoneReg] Processing UPN: {Upn} | Phone: {Phone} | RetryCount: {Retry}",
                    task.Upn, MaskPhone(task.PhoneNumber), task.RetryCount);

                try
                {
                    await _externalIdGraphClient.RegisterPhoneAuthMethodAsync(
                        task.Upn,
                        task.PhoneNumber,
                        cancellationToken);

                    // Delete message only after confirmed success (or 409-already-exists, handled inside GraphClient)
                    await SafeDeleteAsync(queueName, messageId, popReceipt, cancellationToken);
                    succeeded++;

                    _logger.LogInformation(
                        "[PhoneReg] ✅ Registered phone for {Upn}", task.Upn);

                    _telemetry.TrackEvent("PhoneRegistration.Success", new Dictionary<string, string>
                    {
                        { "Upn", task.Upn }
                    });
                }
                catch (OperationCanceledException)
                {
                    _logger.LogWarning("[PhoneReg] Operation cancelled — leaving message {Id} visible for retry.", messageId);
                    break;
                }
                catch (Exception ex)
                {
                    // Do NOT delete the message — it will become visible again after visibilityTimeout
                    // and be retried (by this worker or another instance).
                    failed++;

                    _logger.LogWarning(ex,
                        "[PhoneReg] ❌ Failed to register phone for {Upn} (attempt {Attempt}) — message will be retried after visibility timeout.",
                        task.Upn, task.RetryCount + 1);

                    _telemetry.TrackEvent("PhoneRegistration.Failed", new Dictionary<string, string>
                    {
                        { "Upn", task.Upn },
                        { "RetryCount", task.RetryCount.ToString() },
                        { "Error", ex.Message }
                    });
                }

                // Throttle: always wait between calls regardless of outcome
                if (!cancellationToken.IsCancellationRequested && opts.ThrottleDelayMs > 0)
                {
                    await Task.Delay(opts.ThrottleDelayMs, cancellationToken);
                }
            }

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

    /// <summary>Masks a phone number for safe logging: "+1 206555****"</summary>
    private static string MaskPhone(string phone)
    {
        if (phone.Length <= 4) return "****";
        return phone[..^4] + "****";
    }
}
