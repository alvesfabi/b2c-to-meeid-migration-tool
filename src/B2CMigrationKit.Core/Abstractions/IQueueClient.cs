// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Azure Queue Storage operations for async migration tasks.
/// </summary>
public interface IQueueClient
{
    /// <summary>
    /// Sends a message to the specified queue.
    /// </summary>
    /// <param name="queueName">The name of the queue.</param>
    /// <param name="message">The message content (will be serialized to JSON).</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task SendMessageAsync(
        string queueName,
        object message,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Ensures the specified queue exists, creating it if necessary.
    /// </summary>
    /// <param name="queueName">The name of the queue.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task EnsureQueueExistsAsync(
        string queueName,
        CancellationToken cancellationToken = default);
}
