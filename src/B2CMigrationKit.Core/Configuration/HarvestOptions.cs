// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for the Harvest (Master/Producer) phase.
///
/// The master performs a single, extremely fast pass through all B2C users
/// requesting ONLY the 'id' field (up to 999 per page). It groups the IDs
/// into batches and enqueues each batch as one Azure Queue message.
/// Workers (WorkerExportOrchestrator) then dequeue messages independently,
/// fetch full user profiles via the Graph $batch API, and upload the results
/// to Blob Storage — all without any file I/O or inter-process coordination.
/// </summary>
public class HarvestOptions
{
    /// <summary>
    /// Gets or sets the Azure Queue name where user-ID batches will be enqueued.
    /// All workers must point to the same queue name.
    /// Default: "user-ids-to-process"
    /// </summary>
    public string QueueName { get; set; } = "user-ids-to-process";

    /// <summary>
    /// Gets or sets how many user IDs to pack into each queue message.
    /// Keep at 20 (the Graph $batch limit) so each worker can resolve one
    /// message with a single $batch call. Default: 20.
    /// </summary>
    [Range(1, 20)]
    public int IdsPerMessage { get; set; } = 20;

    /// <summary>
    /// Gets or sets the page size used when fetching user IDs from B2C.
    /// B2C supports up to 999 when selecting only 'id'. Default: 999.
    /// </summary>
    [Range(1, 999)]
    public int PageSize { get; set; } = 999;

    /// <summary>
    /// Gets or sets the message visibility timeout for worker processing.
    /// If a worker does not delete the message within this time the message
    /// becomes visible again and another worker can retry it.
    /// Default: 5 minutes.
    /// </summary>
    public TimeSpan MessageVisibilityTimeout { get; set; } = TimeSpan.FromMinutes(5);
}
