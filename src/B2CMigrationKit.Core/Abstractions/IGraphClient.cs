// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Microsoft Graph API operations with built-in retry and throttling handling.
/// </summary>
public interface IGraphClient
{
    /// <summary>
    /// Gets users from the directory with paging support.
    /// </summary>
    /// <param name="pageSize">Number of users to retrieve per page.</param>
    /// <param name="select">Optional comma-separated list of properties to select.</param>
    /// <param name="filter">Optional OData filter expression.</param>
    /// <param name="skipToken">Optional skip token for pagination.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>A page of user profiles with a continuation token.</returns>
    Task<PagedResult<UserProfile>> GetUsersAsync(
        int pageSize = 100,
        string? select = null,
        string? filter = null,
        string? skipToken = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates a new user in the directory.
    /// </summary>
    /// <param name="user">The user profile to create.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The created user profile with assigned ID.</returns>
    Task<UserProfile> CreateUserAsync(
        UserProfile user,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates multiple users in a batch operation.
    /// </summary>
    /// <param name="users">The collection of users to create.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Results of the batch operation.</returns>
    Task<BatchResult> CreateUsersBatchAsync(
        IEnumerable<UserProfile> users,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Updates an existing user in the directory.
    /// </summary>
    /// <param name="userId">The ID of the user to update.</param>
    /// <param name="updates">Dictionary of property names and values to update.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task UpdateUserAsync(
        string userId,
        Dictionary<string, object> updates,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Gets a user by their object ID.
    /// </summary>
    /// <param name="userId">The user's object ID.</param>
    /// <param name="select">Optional comma-separated list of properties to select.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The user profile or null if not found.</returns>
    Task<UserProfile?> GetUserByIdAsync(
        string userId,
        string? select = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Searches for a user by extension attribute value.
    /// </summary>
    /// <param name="extensionAttributeName">The name of the extension attribute.</param>
    /// <param name="value">The value to search for.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The matching user profile or null if not found.</returns>
    Task<UserProfile?> FindUserByExtensionAttributeAsync(
        string extensionAttributeName,
        string value,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Sets a user's password.
    /// </summary>
    /// <param name="userId">The user's object ID.</param>
    /// <param name="password">The new password.</param>
    /// <param name="forceChangePasswordNextSignIn">Whether to force password change on next sign-in.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task SetUserPasswordAsync(
        string userId,
        string password,
        bool forceChangePasswordNextSignIn = false,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Gets phone authentication methods for multiple users in a single batch request.
    /// Uses Graph batch API to read /users/{id}/authentication/phoneMethods for each user.
    /// Only returns mobile-type phone methods (SMS-capable).
    /// </summary>
    /// <param name="userIds">Collection of user object IDs to query.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Dictionary mapping userId to their mobile MFA phone number (null if none).</returns>
    Task<Dictionary<string, string?>> GetPhoneAuthenticationMethodsBatchAsync(
        IEnumerable<string> userIds,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Registers a phone authentication method (SMS mobile) for a user in External ID.
    /// </summary>
    /// <param name="userId">The user's object ID in External ID.</param>
    /// <param name="phoneNumber">The phone number in E.164 format (e.g., "+1 5555551234").</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>True if the phone method was registered successfully.</returns>
    Task<bool> AddPhoneAuthenticationMethodAsync(
        string userId,
        string phoneNumber,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Checks if a user already has a mobile phone authentication method registered.
    /// </summary>
    /// <param name="userId">The user's object ID.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>True if the user already has a mobile phone method.</returns>
    Task<bool> HasPhoneAuthenticationMethodAsync(
        string userId,
        CancellationToken cancellationToken = default);
}
