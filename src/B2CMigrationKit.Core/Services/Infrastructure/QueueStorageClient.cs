// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Azure.Storage.Queues;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Azure Queue Storage client for async migration task processing.
/// </summary>
public class QueueStorageClient : IQueueClient
{
    private readonly QueueServiceClient _serviceClient;
    private readonly ILogger<QueueStorageClient> _logger;
    private readonly StorageOptions _options;

    public QueueStorageClient(
        IOptions<StorageOptions> options,
        ILogger<QueueStorageClient> logger)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        if (_options.UseManagedIdentity)
        {
            var credential = new DefaultAzureCredential();
            _serviceClient = new QueueServiceClient(new Uri(_options.ConnectionStringOrUri), credential);
            _logger.LogInformation("Queue storage client initialized with Managed Identity");
        }
        else
        {
            _serviceClient = new QueueServiceClient(_options.ConnectionStringOrUri);
            _logger.LogInformation("Queue storage client initialized with connection string");
        }
    }

    public async Task SendMessageAsync(
        string queueName,
        object message,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            var json = JsonSerializer.Serialize(message, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            });

            // Base64 encode for Azure Functions queue trigger compatibility
            var base64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json));
            await queueClient.SendMessageAsync(base64, cancellationToken);

            _logger.LogDebug("Sent message to queue {Queue} ({Size} bytes)", queueName, json.Length);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send message to queue {Queue}", queueName);
            throw;
        }
    }

    public async Task EnsureQueueExistsAsync(
        string queueName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);
            _logger.LogInformation("Ensured queue exists: {Queue}", queueName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to ensure queue {Queue} exists", queueName);
            throw;
        }
    }
}
