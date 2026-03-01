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
/// Master / Producer phase of the Master-Worker export pattern.
///
/// Performs a single, extremely fast pass through all B2C users requesting
/// ONLY the 'id' field (page size up to 999). IDs are grouped into batches of
/// <see cref="HarvestOptions.IdsPerMessage"/> and each batch is enqueued as one
/// Azure Queue message (JSON array of strings).
///
/// Workers (<see cref="WorkerExportOrchestrator"/>) independently dequeue messages,
/// resolve full user profiles via the Graph $batch API, and upload results to
/// Blob Storage — with no file I/O and no inter-process coordination needed.
/// Azure Queue's visibility-timeout provides free retry semantics: if a worker
/// crashes, the message reappears after the timeout and another worker picks it up.
/// </summary>
public class HarvestOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<HarvestOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public HarvestOrchestrator(
        IGraphClient b2cGraphClient,
        IQueueClient queueClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<HarvestOrchestrator> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    /// <summary>
    /// Pages through B2C with $select=id, groups IDs into batches, and enqueues
    /// each batch as a single Azure Queue message.
    /// </summary>
    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "B2C User ID Harvest (Master/Producer phase)",
            StartTime = DateTimeOffset.UtcNow
        };

        var harvestOpts = _options.Harvest;
        var queueName = harvestOpts.QueueName;
        var idsPerMessage = harvestOpts.IdsPerMessage;
        var pageSize = harvestOpts.PageSize;

        try
        {
            _logger.LogInformation("=== HARVEST PHASE START ===");
            _logger.LogInformation("Queue           : {Queue}", queueName);
            _logger.LogInformation("IDs per message : {IdsPerMessage}", idsPerMessage);
            _logger.LogInformation("B2C page size   : {PageSize} (requesting only 'id')", pageSize);
            _telemetry.TrackEvent("Harvest.Started");

            // Ensure the queue exists
            await _queueClient.CreateQueueIfNotExistsAsync(queueName, cancellationToken);

            var pageNumber = 0;
            var messagesEnqueued = 0;
            string? skipToken = null;
            var pendingIds = new List<string>(idsPerMessage);
            var overallStart = DateTimeOffset.UtcNow;

            do
            {
                var page = await _b2cGraphClient.GetUsersAsync(
                    pageSize: pageSize,
                    select: "id",           // Only request the ID – maximises throughput
                    skipToken: skipToken,
                    cancellationToken: cancellationToken);

                foreach (var user in page.Items)
                {
                    if (string.IsNullOrWhiteSpace(user.Id)) continue;

                    pendingIds.Add(user.Id);
                    summary.TotalItems++;

                    // Flush a full batch to the queue
                    if (pendingIds.Count >= idsPerMessage)
                    {
                        await EnqueueBatchAsync(queueName, pendingIds, cancellationToken);
                        messagesEnqueued++;
                        pendingIds = new List<string>(idsPerMessage);
                    }
                }

                var elapsed = (DateTimeOffset.UtcNow - overallStart).TotalSeconds;
                var rate = elapsed > 0 ? summary.TotalItems / elapsed : 0;

                _logger.LogInformation(
                    "Harvest page {Page}: +{PageCount} IDs | Total: {Total:N0} | " +
                    "Messages enqueued: {Messages} | Elapsed: {Elapsed:F1}s | Rate: {Rate:F0} IDs/s",
                    pageNumber, page.Items.Count, summary.TotalItems,
                    messagesEnqueued, elapsed, rate);

                _telemetry.IncrementCounter("Harvest.IdsHarvested", page.Items.Count);

                skipToken = page.NextPageToken;
                pageNumber++;

                if (_options.BatchDelayMs > 0 && page.HasMorePages)
                {
                    await Task.Delay(_options.BatchDelayMs, cancellationToken);
                }

            } while (!string.IsNullOrEmpty(skipToken) && !cancellationToken.IsCancellationRequested);

            // Flush any remaining IDs that did not fill a complete batch
            if (pendingIds.Count > 0)
            {
                await EnqueueBatchAsync(queueName, pendingIds, cancellationToken);
                messagesEnqueued++;
            }

            summary.SuccessCount = summary.TotalItems;
            summary.EndTime = DateTimeOffset.UtcNow;

            var totalElapsed = summary.Duration.TotalSeconds;
            var finalRate = totalElapsed > 0 ? summary.TotalItems / totalElapsed : 0;

            _logger.LogInformation(
                "=== HARVEST SUMMARY ===\n" +
                "User IDs harvested : {Total:N0}\n" +
                "Messages enqueued  : {Messages:N0} (queue: '{Queue}')\n" +
                "B2C pages fetched  : {Pages}\n" +
                "Duration           : {Duration}\n" +
                "Rate               : {Rate:F1} IDs/second\n" +
                "\n--- NEXT STEP: start workers (any number, each with its own config) ---\n" +
                "  worker-export --config appsettings.app1.json\n" +
                "  worker-export --config appsettings.app2.json\n" +
                "  worker-export --config appsettings.app3.json",
                summary.TotalItems, messagesEnqueued, queueName,
                pageNumber, summary.Duration, finalRate);

            _telemetry.TrackEvent("Harvest.Completed", new Dictionary<string, string>
            {
                { "TotalIds", summary.TotalItems.ToString() },
                { "MessagesEnqueued", messagesEnqueued.ToString() },
                { "Duration", summary.Duration.ToString() },
                { "Rate", finalRate.ToString("F1") }
            });

            _telemetry.TrackMetric("Harvest.TotalIds", summary.TotalItems);
            _telemetry.TrackMetric("Harvest.MessagesEnqueued", messagesEnqueued);

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = true,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Harvest phase failed");
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

    private async Task EnqueueBatchAsync(
        string queueName,
        IReadOnlyList<string> ids,
        CancellationToken cancellationToken)
    {
        // Each message is a compact JSON array of user-ID strings.
        // WorkerExportOrchestrator deserializes this to get the IDs to fetch.
        var message = JsonSerializer.Serialize(ids);
        await _queueClient.SendMessageAsync(queueName, message, cancellationToken);
        _telemetry.IncrementCounter("Harvest.MessagesEnqueued");
    }
}
