// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a queue message for asynchronous phone MFA migration.
/// Enqueued after successful JIT password migration or during bulk import.
/// </summary>
public class PhoneMigrationMessage
{
    /// <summary>
    /// Gets or sets the External ID user object ID.
    /// </summary>
    public string UserId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user principal name (for logging/correlation).
    /// </summary>
    public string? UserPrincipalName { get; set; }

    /// <summary>
    /// Gets or sets the correlation ID for tracing across operations.
    /// </summary>
    public string CorrelationId { get; set; } = Guid.NewGuid().ToString();

    /// <summary>
    /// Gets or sets the timestamp when the message was created.
    /// </summary>
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>
    /// Gets or sets the source of the migration request (JIT or BulkImport).
    /// </summary>
    public string Source { get; set; } = "JIT";
}
