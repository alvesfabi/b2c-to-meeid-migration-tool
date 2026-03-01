// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Queue message payload for an async phone-authentication-method registration task.
/// Produced by ImportOrchestrator, consumed by PhoneRegistrationWorker.
/// </summary>
public class PhoneRegistrationMessage
{
    /// <summary>
    /// The user's UPN in Entra External ID after import (e.g. user_contoso.com#EXT#@tenant.onmicrosoft.com).
    /// Used as the identifier for POST /users/{upn}/authentication/phoneMethods.
    /// </summary>
    public string Upn { get; set; } = string.Empty;

    /// <summary>
    /// The phone number exported from B2C (mobilePhone field).
    /// Must be in E.164-ish format accepted by Graph: "+{cc} {number}", e.g. "+1 2065551234".
    /// </summary>
    public string PhoneNumber { get; set; } = string.Empty;

    /// <summary>
    /// Number of times this message has been retried (incremented by the worker on transient failure).
    /// </summary>
    public int RetryCount { get; set; } = 0;
}
