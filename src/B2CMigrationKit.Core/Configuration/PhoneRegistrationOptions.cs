// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for the asynchronous phone-authentication-method registration worker.
/// This is a separate, throttle-controlled operation that runs after import to register
/// MFA phone numbers in Entra External ID without impacting the main import throughput.
/// </summary>
public class PhoneRegistrationOptions
{
    /// <summary>
    /// Name of the Azure Queue used to buffer phone-registration tasks.
    /// Default: "phone-registration"
    /// </summary>
    public string QueueName { get; set; } = "phone-registration";

    /// <summary>
    /// Minimum delay (ms) between consecutive POST /authentication/phoneMethods calls.
    /// The phoneMethods API has a much lower throttle budget than the main Users API.
    /// Tune this to stay well below the tenant limit (typically ~30–50 req/min per tenant).
    /// Default: 1200 ms (~50 req/min with headroom)
    /// </summary>
    public int ThrottleDelayMs { get; set; } = 1200;

    /// <summary>
    /// How long (seconds) a dequeued message is invisible to other workers while being processed.
    /// If processing fails, the message becomes visible again after this timeout for a retry.
    /// Default: 120 seconds
    /// </summary>
    public int MessageVisibilityTimeoutSeconds { get; set; } = 120;

    /// <summary>
    /// How long the worker polls when the queue is empty before checking again.
    /// Default: 5000 ms
    /// </summary>
    public int EmptyQueuePollDelayMs { get; set; } = 5000;

    /// <summary>
    /// Maximum number of consecutive empty-queue polls before the worker exits.
    /// Set to 0 to run indefinitely (useful when running as a background service).
    /// Default: 3
    /// </summary>
    public int MaxEmptyPolls { get; set; } = 3;
}
