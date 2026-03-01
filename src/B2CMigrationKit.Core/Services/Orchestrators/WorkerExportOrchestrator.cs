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
/// Worker / Consumer phase of the Master-Worker export pattern.
///
/// Each worker instance independently:
///   1. Dequeues one message from the Azure Queue (a JSON array of user IDs
///      enqueued by <see cref="HarvestOrchestrator"/>).
///   2. Calls the Graph $batch API to fetch the full profile of those up to 20 users.
///   3. Serializes the profiles and uploads them as a blob to Azure Blob Storage.
///   4. Deletes the message from the queue.
///   5. Repeats until the queue is empty.
///
/// Multiple worker instances can run simultaneously, each using a different
/// B2C App Registration, multiplying the effective API throttling limit.
/// Azure Queue's visibility timeout provides automatic retry: if a worker
/// crashes before deleting the message, it reappears after the timeout.
/// </summary>
public class WorkerExportOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IBlobStorageClient _blobClient;
    private readonly IQueueClient _queueClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<WorkerExportOrchestrator> _logger;
    private readonly MigrationOptions _options;

    // Unique prefix for this worker run so concurrent workers don't overwrite blobs.
    private readonly string _blobPrefix;

    public WorkerExportOrchestrator(
        IGraphClient b2cGraphClient,
        IBlobStorageClient blobClient,
        IQueueClient queueClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<WorkerExportOrchestrator> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _blobClient = blobClient ?? throw new ArgumentNullException(nameof(blobClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));

        // Determine blob prefix for this worker instance.
        // Explicit config wins; otherwise auto-generate a unique suffix so
        // multiple workers can coexist in the same container.
        var configuredPrefix = _options.Export.WorkerBlobPrefix;
        _blobPrefix = !string.IsNullOrWhiteSpace(configuredPrefix)
            ? configuredPrefix
            : $"{_options.Storage.ExportBlobPrefix}worker_{GenerateShortId()}_";
    }

    /// <summary>
    /// Drains the harvest queue: dequeue → Graph $batch → upload blob → delete message.
    /// Returns when the queue is empty or cancellation is requested.
    /// </summary>
    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "B2C Worker Export (Consumer phase)",
            StartTime = DateTimeOffset.UtcNow
        };

        var queueName = _options.Harvest.QueueName;
        var visibilityTimeout = _options.Harvest.MessageVisibilityTimeout;
        var selectFields = _options.Export.SelectFields;
        var blobCounter = 0;

        try
        {
            _logger.LogInformation("=== WORKER EXPORT START ===");
            _logger.LogInformation("Queue          : {Queue}", queueName);
            _logger.LogInformation("Blob prefix    : {Prefix}", _blobPrefix);
            _logger.LogInformation("Select fields  : {Fields}", selectFields);
            _logger.LogInformation("Visibility TTL : {Timeout}", visibilityTimeout);
            _telemetry.TrackEvent("WorkerExport.Started");

            // Ensure the export container exists
            await _blobClient.EnsureContainerExistsAsync(
                _options.Storage.ExportContainerName,
                cancellationToken);

            var overallStart = DateTimeOffset.UtcNow;
            var consecutiveEmptyPolls = 0;
            const int MaxConsecutiveEmptyPolls = 3; // Stop after 3 consecutive empty dequeues

            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await _queueClient.ReceiveMessageAsync(
                    queueName,
                    visibilityTimeout,
                    cancellationToken);

                if (message is null)
                {
                    consecutiveEmptyPolls++;
                    _logger.LogInformation(
                        "Queue empty (poll {Attempt}/{Max}). Waiting 2 seconds before retry…",
                        consecutiveEmptyPolls, MaxConsecutiveEmptyPolls);

                    if (consecutiveEmptyPolls >= MaxConsecutiveEmptyPolls)
                    {
                        _logger.LogInformation("Queue confirmed empty after {Max} consecutive polls. Worker done.",
                            MaxConsecutiveEmptyPolls);
                        break;
                    }

                    await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
                    continue;
                }

                consecutiveEmptyPolls = 0; // Reset counter on a successful dequeue

                var (messageId, popReceipt, messageText) = message.Value;

                try
                {
                    // Deserialize the list of user IDs from the message body
                    var userIds = JsonSerializer.Deserialize<List<string>>(messageText);
                    if (userIds is null || userIds.Count == 0)
                    {
                        _logger.LogWarning("Received empty or invalid message {MessageId}, deleting.", messageId);
                        await _queueClient.DeleteMessageAsync(queueName, messageId, popReceipt, cancellationToken);
                        continue;
                    }

                    var batchStart = DateTimeOffset.UtcNow;

                    // Fetch full user profiles via the Graph $batch API (1 HTTP call for up to 20 users)
                    var profiles = await _b2cGraphClient.GetUsersByIdsAsync(
                        userIds,
                        selectFields,
                        cancellationToken);

                    var fetchMs = (DateTimeOffset.UtcNow - batchStart).TotalMilliseconds;

                    if (profiles.Count > 0)
                    {
                        // Upload the profiles as a blob
                        var blobName = $"{_blobPrefix}{blobCounter:D6}.json";
                        var json = JsonSerializer.Serialize(profiles, new JsonSerializerOptions
                        {
                            WriteIndented = false   // Compact JSON for storage efficiency
                        });

                        var uploadStart = DateTimeOffset.UtcNow;
                        await _blobClient.WriteBlobAsync(
                            _options.Storage.ExportContainerName,
                            blobName,
                            json,
                            cancellationToken);

                        var uploadMs = (DateTimeOffset.UtcNow - uploadStart).TotalMilliseconds;
                        var totalMs = (DateTimeOffset.UtcNow - batchStart).TotalMilliseconds;

                        summary.TotalItems += profiles.Count;
                        summary.SuccessCount += profiles.Count;
                        blobCounter++;

                        var elapsed = (DateTimeOffset.UtcNow - overallStart).TotalSeconds;
                        var rate = elapsed > 0 ? summary.TotalItems / elapsed : 0;

                        _logger.LogInformation(
                            "Blob {BlobCounter}: {Count} users → {BlobName} | " +
                            "Fetch: {FetchMs:F0}ms | Upload: {UploadMs:F0}ms | Total: {TotalMs:F0}ms | " +
                            "Total exported: {Total:N0} ({Rate:F1} users/s)",
                            blobCounter, profiles.Count, blobName,
                            fetchMs, uploadMs, totalMs,
                            summary.TotalItems, rate);

                        _telemetry.IncrementCounter("WorkerExport.UsersExported", profiles.Count);
                        _telemetry.TrackMetric("WorkerExport.BatchTotalMs", totalMs);
                        _telemetry.TrackMetric("WorkerExport.FetchMs", fetchMs);
                        _telemetry.TrackMetric("WorkerExport.UploadMs", uploadMs);
                    }
                    else
                    {
                        // All requested IDs returned errors (deleted users, etc.)
                        summary.SkippedCount += userIds.Count;
                        _logger.LogWarning(
                            "Message {MessageId}: all {Count} user IDs returned no results (users may have been deleted).",
                            messageId, userIds.Count);
                    }

                    // ACK: remove the message from the queue
                    await _queueClient.DeleteMessageAsync(queueName, messageId, popReceipt, cancellationToken);

                    // Optional inter-batch delay
                    if (_options.BatchDelayMs > 0)
                    {
                        await Task.Delay(_options.BatchDelayMs, cancellationToken);
                    }
                }
                catch (Exception ex)
                {
                    // Do NOT delete the message – let it reappear after visibilityTimeout
                    // so another worker (or this one on retry) can process it.
                    summary.FailureCount++;
                    _logger.LogError(ex,
                        "Failed to process message {MessageId}. " +
                        "Message will reappear in queue after visibility timeout ({Timeout}).",
                        messageId, visibilityTimeout);
                    _telemetry.TrackException(ex);
                }
            }

            summary.EndTime = DateTimeOffset.UtcNow;

            var totalElapsed = summary.Duration.TotalSeconds;
            var finalRate = totalElapsed > 0 ? summary.TotalItems / totalElapsed : 0;

            _logger.LogInformation(
                "=== WORKER EXPORT SUMMARY ===\n" +
                "Users exported  : {Total:N0}\n" +
                "Blobs created   : {Blobs}\n" +
                "Skipped (404s)  : {Skipped}\n" +
                "Failed messages : {Failed}\n" +
                "Duration        : {Duration}\n" +
                "Throughput      : {Rate:F2} users/second",
                summary.TotalItems, blobCounter, summary.SkippedCount,
                summary.FailureCount, summary.Duration, finalRate);

            _telemetry.TrackEvent("WorkerExport.Completed", new Dictionary<string, string>
            {
                { "TotalUsers", summary.TotalItems.ToString() },
                { "BlobsCreated", blobCounter.ToString() },
                { "Duration", summary.Duration.ToString() },
                { "Throughput", finalRate.ToString("F2") }
            });

            _telemetry.TrackMetric("WorkerExport.TotalUsers", summary.TotalItems);
            _telemetry.TrackMetric("WorkerExport.BlobsCreated", blobCounter);

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = summary.FailureCount == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary,
                ErrorMessage = summary.FailureCount > 0
                    ? $"{summary.FailureCount} message(s) failed to process."
                    : null
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Worker export failed");
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
    // Private helpers
    // -------------------------------------------------------------------------

    /// <summary>
    /// Generates a short, URL-safe unique identifier for use as a blob prefix
    /// when no explicit <see cref="ExportOptions.WorkerBlobPrefix"/> is configured.
    /// </summary>
    private static string GenerateShortId()
        => Convert.ToBase64String(Guid.NewGuid().ToByteArray())
            .Replace("+", "")
            .Replace("/", "")
            .Replace("=", "")
            [..8]
            .ToLowerInvariant();
}
