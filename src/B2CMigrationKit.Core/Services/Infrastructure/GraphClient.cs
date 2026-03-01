// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Graph;
using Polly;
using Polly.Retry;
using System.Net;
using GraphModels = Microsoft.Graph.Models;
using CoreModels = B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Microsoft Graph client with retry logic and throttling handling.
/// </summary>
public class GraphClient : IGraphClient
{
    private readonly GraphServiceClient _client;
    private readonly ILogger<GraphClient> _logger;
    private readonly ITelemetryService _telemetry;
    private readonly RetryOptions _retryOptions;
    private readonly ResiliencePipeline _retryPipeline;

    public GraphClient(
        GraphServiceClient client,
        IOptions<RetryOptions> retryOptions,
        ILogger<GraphClient> logger,
        ITelemetryService telemetry)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _retryOptions = retryOptions?.Value ?? throw new ArgumentNullException(nameof(retryOptions));

        _retryPipeline = CreateRetryPipeline();
    }

    private ResiliencePipeline CreateRetryPipeline()
    {
        return new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                MaxRetryAttempts = _retryOptions.MaxRetries,
                Delay = TimeSpan.FromMilliseconds(_retryOptions.InitialDelayMs),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                OnRetry = args =>
                {
                    _logger.LogWarning("Retry attempt {Attempt} after {Delay}ms due to: {Exception}",
                        args.AttemptNumber, args.RetryDelay.TotalMilliseconds, args.Outcome.Exception?.Message);
                    _telemetry.IncrementCounter("GraphClient.Retries");
                    return ValueTask.CompletedTask;
                }
            })
            .AddTimeout(TimeSpan.FromSeconds(_retryOptions.OperationTimeoutSeconds))
            .Build();
    }

    public async Task<CoreModels.PagedResult<CoreModels.UserProfile>> GetUsersAsync(
        int pageSize = 100,
        string? select = null,
        string? filter = null,
        string? skipToken = null,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            GraphModels.UserCollectionResponse? response;

            // If we have a nextLink (full URL), use it directly for pagination
            if (!string.IsNullOrEmpty(skipToken) && skipToken.StartsWith("http", StringComparison.OrdinalIgnoreCase))
            {
                // Use the full OData nextLink URL for pagination
                var requestInfo = new Microsoft.Kiota.Abstractions.RequestInformation
                {
                    HttpMethod = Microsoft.Kiota.Abstractions.Method.GET,
                    URI = new Uri(skipToken)
                };
                requestInfo.Headers.Add("ConsistencyLevel", "eventual");
                
                response = await _client.RequestAdapter.SendAsync(
                    requestInfo, 
                    GraphModels.UserCollectionResponse.CreateFromDiscriminatorValue, 
                    cancellationToken: ct);
            }
            else
            {
                // First page request - build query parameters
                response = await _client.Users.GetAsync(config =>
                {
                    config.QueryParameters.Top = pageSize;
                    config.QueryParameters.Count = true;

                    if (!string.IsNullOrEmpty(select))
                    {
                        config.QueryParameters.Select = select.Split(',');
                    }

                    if (!string.IsNullOrEmpty(filter))
                    {
                        config.QueryParameters.Filter = filter;
                    }

                    config.Headers.Add("ConsistencyLevel", "eventual");
                }, ct);
            }

            var users = response?.Value?.Select(MapToUserProfile).ToList() ?? new List<CoreModels.UserProfile>();
            
            // Return the full nextLink URL as the token for next page
            var nextPageToken = response?.OdataNextLink;

            _telemetry.IncrementCounter("GraphClient.GetUsers", users.Count);

            return new CoreModels.PagedResult<CoreModels.UserProfile>
            {
                Items = users,
                NextPageToken = nextPageToken
            };
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile> CreateUserAsync(
        CoreModels.UserProfile user,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var graphUser = MapToGraphUser(user);
            var created = await _client.Users.PostAsync(graphUser, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.UserCreated");

            return MapToUserProfile(created!);
        }, cancellationToken);
    }

    public async Task<CoreModels.BatchResult> CreateUsersBatchAsync(
        IEnumerable<CoreModels.UserProfile> users,
        CancellationToken cancellationToken = default)
    {
        var result = new CoreModels.BatchResult
        {
            TotalItems = users.Count()
        };

        var batches = users.Chunk(20); // Graph API batch limit is 20

        foreach (var batch in batches)
        {
            try
            {
                var batchRequest = new Microsoft.Graph.BatchRequestContentCollection(_client);
                var requestIdToUser = new Dictionary<string, CoreModels.UserProfile>();

                foreach (var user in batch)
                {
                    var graphUser = MapToGraphUser(user);
                    var requestInfo = _client.Users.ToPostRequestInformation(graphUser);
                    var requestId = await batchRequest.AddBatchRequestStepAsync(requestInfo);
                    requestIdToUser[requestId] = user;
                }

                var batchResponse = await _client.Batch.PostAsync(batchRequest, cancellationToken: cancellationToken);

                // Check individual responses
                var successCount = 0;
                var failureCount = 0;
                var skippedCount = 0;

                foreach (var requestId in requestIdToUser.Keys)
                {
                    try
                    {
                        var response = await batchResponse.GetResponseByIdAsync(requestId);
                        var user = requestIdToUser[requestId];

                        if (response != null && response.IsSuccessStatusCode)
                        {
                            successCount++;
                        }
                        else
                        {
                            var statusCode = response?.StatusCode ?? HttpStatusCode.InternalServerError;
                            var errorContent = response != null ? await response.Content.ReadAsStringAsync() : "No response";

                            // Check if this is a duplicate user (ObjectConflict)
                            if (statusCode == HttpStatusCode.BadRequest &&
                                errorContent.Contains("ObjectConflict") &&
                                (errorContent.Contains("userPrincipalName already exists") ||
                                 errorContent.Contains("Another object with the same value")))
                            {
                                skippedCount++;
                                result.SkippedUserIds.Add(user.UserPrincipalName ?? user.Id ?? "unknown");
                                result.DuplicateUsers.Add(user); // Store for potential extension attribute update
                                _logger.LogInformation("User {UPN} already exists, skipping (RequestId: {RequestId})",
                                    user.UserPrincipalName, requestId);
                            }
                            else
                            {
                                failureCount++;
                                _logger.LogWarning("User creation failed (UPN: {UPN}, RequestId: {RequestId}, Status: {Status}): {Error}",
                                    user.UserPrincipalName, requestId, statusCode, errorContent);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        failureCount++;
                        var user = requestIdToUser[requestId];
                        _logger.LogWarning(ex, "Failed to get batch response for UPN: {UPN}, RequestId: {RequestId}",
                            user.UserPrincipalName, requestId);
                    }
                }

                result.SuccessCount += successCount;
                result.FailureCount += failureCount;
                result.SkippedCount += skippedCount;

                _logger.LogInformation("Batch completed: {Success} succeeded, {Skipped} skipped (duplicates), {Failed} failed",
                    successCount, skippedCount, failureCount);

                if (successCount > 0)
                {
                    _telemetry.IncrementCounter("GraphClient.UserCreatedBatch", successCount);
                }
            }
            catch (Exception ex)
            {
                result.FailureCount += batch.Count();
                _logger.LogError(ex, "Batch create failed for {Count} users", batch.Count());
            }
        }

        return result;
    }

    public async Task UpdateUserAsync(
        string userId,
        Dictionary<string, object> updates,
        CancellationToken cancellationToken = default)
    {
        await _retryPipeline.ExecuteAsync(async ct =>
        {
            var user = new GraphModels.User
            {
                AdditionalData = updates
            };

            await _client.Users[userId].PatchAsync(user, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.UserUpdated");
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile?> GetUserByIdAsync(
        string userId,
        string? select = null,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var request = _client.Users[userId].GetAsync(config =>
            {
                if (!string.IsNullOrEmpty(select))
                {
                    config.QueryParameters.Select = select.Split(',');
                }
            }, ct);

            var user = await request;

            return user != null ? MapToUserProfile(user) : null;
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile?> FindUserByExtensionAttributeAsync(
        string extensionAttributeName,
        string value,
        CancellationToken cancellationToken = default)
    {
        var filter = $"{extensionAttributeName} eq '{value}'";
        var result = await GetUsersAsync(pageSize: 1, filter: filter, cancellationToken: cancellationToken);

        return result.Items.FirstOrDefault();
    }

    public async Task SetUserPasswordAsync(
        string userId,
        string password,
        bool forceChangePasswordNextSignIn = false,
        CancellationToken cancellationToken = default)
    {
        await _retryPipeline.ExecuteAsync(async ct =>
        {
            var user = new GraphModels.User
            {
                PasswordProfile = new GraphModels.PasswordProfile
                {
                    ForceChangePasswordNextSignIn = forceChangePasswordNextSignIn,
                    Password = password
                }
            };

            await _client.Users[userId].PatchAsync(user, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.PasswordSet");
        }, cancellationToken);
    }

    /// <summary>
    /// The well-known ID for the "mobile" phone authentication method in Microsoft Graph.
    /// This is a globally fixed GUID across all Entra ID tenants.
    /// </summary>
    private const string MobilePhoneMethodId = "3179e48a-750b-4051-897c-87b9720928f7";

    public async Task<Dictionary<string, string?>> GetPhoneAuthenticationMethodsBatchAsync(
        IEnumerable<string> userIds,
        CancellationToken cancellationToken = default)
    {
        var result = new Dictionary<string, string?>();
        var userIdList = userIds.ToList();

        if (!userIdList.Any())
            return result;

        // Graph batch limit is 20 requests per batch, but the authentication
        // methods API has much stricter rate limits than /users. We use a smaller
        // sub-batch (10) with generous delays to stay within throttle thresholds.
        //   1. Wrap each batch POST in the retry pipeline (retries on transient/429 errors)
        //   2. Add inter-batch delay to avoid overwhelming the API
        //   3. Collect per-sub-request 429 failures and retry them in subsequent rounds
        const int graphBatchSize = 10;
        const int interBatchDelayMs = 1500;
        const int maxRetryRounds = 5;
        const int retryRoundBaseDelayMs = 3000;

        var pendingUserIds = userIdList;

        for (var round = 0; round <= maxRetryRounds && pendingUserIds.Count > 0; round++)
        {
            var throttledUserIds = new List<string>();

            if (round > 0)
            {
                // Exponential backoff between retry rounds for throttled sub-requests
                var roundDelay = TimeSpan.FromMilliseconds(retryRoundBaseDelayMs * Math.Pow(2, round - 1));
                _logger.LogInformation(
                    "Phone methods retry round {Round}/{MaxRounds}: retrying {Count} throttled users after {Delay}ms delay",
                    round, maxRetryRounds, pendingUserIds.Count, roundDelay.TotalMilliseconds);
                await Task.Delay(roundDelay, cancellationToken);
            }

            var batches = pendingUserIds.Chunk(graphBatchSize);
            var batchIndex = 0;

            foreach (var batch in batches)
            {
                // Add delay between batch calls to respect rate limits
                if (batchIndex > 0)
                {
                    await Task.Delay(interBatchDelayMs, cancellationToken);
                }
                batchIndex++;

                try
                {
                    // Wrap the batch POST in retry pipeline to handle transient failures
                    await _retryPipeline.ExecuteAsync(async ct =>
                    {
                        var batchRequest = new BatchRequestContentCollection(_client);
                        var requestIdToUserId = new Dictionary<string, string>();

                        foreach (var userId in batch)
                        {
                            // Build GET /users/{userId}/authentication/phoneMethods
                            var requestInfo = _client.Users[userId].Authentication.PhoneMethods
                                .ToGetRequestInformation();
                            var requestId = await batchRequest.AddBatchRequestStepAsync(requestInfo);
                            requestIdToUserId[requestId] = userId;
                        }

                        var batchResponse = await _client.Batch.PostAsync(batchRequest, cancellationToken: ct);

                        foreach (var (requestId, userId) in requestIdToUserId)
                        {
                            try
                            {
                                var response = await batchResponse!.GetResponseByIdAsync(requestId);

                                if (response != null && response.IsSuccessStatusCode)
                                {
                                    var content = await response.Content.ReadAsStringAsync(ct);
                                    var doc = System.Text.Json.JsonDocument.Parse(content);

                                    string? mobilePhone = null;

                                    if (doc.RootElement.TryGetProperty("value", out var valueArray))
                                    {
                                        foreach (var method in valueArray.EnumerateArray())
                                        {
                                            // Only capture "mobile" type (SMS-capable)
                                            if (method.TryGetProperty("phoneType", out var phoneType) &&
                                                string.Equals(phoneType.GetString(), "mobile", StringComparison.OrdinalIgnoreCase))
                                            {
                                                if (method.TryGetProperty("phoneNumber", out var phoneNum))
                                                {
                                                    mobilePhone = phoneNum.GetString();
                                                }
                                                break; // Only one mobile phone method per user
                                            }
                                        }
                                    }

                                    result[userId] = mobilePhone;
                                }
                                else
                                {
                                    var statusCode = response?.StatusCode ?? HttpStatusCode.InternalServerError;

                                    if (statusCode == HttpStatusCode.TooManyRequests ||
                                        statusCode == HttpStatusCode.ServiceUnavailable)
                                    {
                                        // Collect for retry in next round
                                        throttledUserIds.Add(userId);
                                        _logger.LogDebug(
                                            "Phone methods sub-request throttled for user {UserId} (Status: {Status}), will retry",
                                            userId, statusCode);
                                    }
                                    else
                                    {
                                        _logger.LogWarning(
                                            "Failed to get phone methods for user {UserId} (Status: {Status})",
                                            userId, statusCode);
                                        result[userId] = null;
                                    }
                                }
                            }
                            catch (Exception ex)
                            {
                                _logger.LogWarning(ex, "Error processing phone methods response for user {UserId}", userId);
                                result[userId] = null;
                            }
                        }
                    }, cancellationToken);

                    _telemetry.IncrementCounter("GraphClient.PhoneMethodsBatchRead", batch.Length);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Batch phone methods request failed for {Count} users after retries", batch.Length);

                    // Mark all users in failed batch as null
                    foreach (var userId in batch)
                    {
                        result.TryAdd(userId, null);
                    }
                }
            }

            // Prepare next round with only the throttled users
            pendingUserIds = throttledUserIds;
        }

        // Any users still not resolved after all retry rounds get null
        foreach (var userId in pendingUserIds)
        {
            if (!result.ContainsKey(userId))
            {
                _logger.LogWarning("Phone methods lookup exhausted retries for user {UserId}", userId);
                result[userId] = null;
            }
        }

        return result;
    }

    public async Task<bool> AddPhoneAuthenticationMethodAsync(
        string userId,
        string phoneNumber,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var phoneMethod = new GraphModels.PhoneAuthenticationMethod
            {
                PhoneNumber = phoneNumber,
                PhoneType = GraphModels.AuthenticationPhoneType.Mobile
            };

            await _client.Users[userId].Authentication.PhoneMethods
                .PostAsync(phoneMethod, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.PhoneMethodAdded");
            _logger.LogInformation("Registered mobile phone method for user {UserId}", userId);

            return true;
        }, cancellationToken);
    }

    public async Task<bool> HasPhoneAuthenticationMethodAsync(
        string userId,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            try
            {
                // GET /users/{id}/authentication/phoneMethods/{mobilePhoneMethodId}
                var method = await _client.Users[userId].Authentication.PhoneMethods[MobilePhoneMethodId]
                    .GetAsync(cancellationToken: ct);

                return method?.PhoneNumber != null;
            }
            catch (Microsoft.Graph.Models.ODataErrors.ODataError ex) when (ex.ResponseStatusCode == 404)
            {
                return false;
            }
        }, cancellationToken);
    }

    private CoreModels.UserProfile MapToUserProfile(GraphModels.User user)
    {
        var profile = new CoreModels.UserProfile
        {
            Id = user.Id,
            UserPrincipalName = user.UserPrincipalName,
            DisplayName = user.DisplayName,
            GivenName = user.GivenName,
            Surname = user.Surname,
            Mail = user.Mail,
            MobilePhone = user.MobilePhone,
            StreetAddress = user.StreetAddress,
            City = user.City,
            State = user.State,
            PostalCode = user.PostalCode,
            Country = user.Country,
            AccountEnabled = user.AccountEnabled ?? true,
            CreatedDateTime = user.CreatedDateTime
        };

        if (user.OtherMails != null)
        {
            profile.OtherMails = user.OtherMails.ToList();
        }

        if (user.Identities != null)
        {
            profile.Identities = user.Identities.Select(i => new CoreModels.ObjectIdentity
            {
                SignInType = i.SignInType,
                Issuer = i.Issuer,
                IssuerAssignedId = i.IssuerAssignedId
            }).ToList();
        }

        if (user.AdditionalData != null)
        {
            profile.ExtensionAttributes = new Dictionary<string, object>(user.AdditionalData);
        }

        return profile;
    }

    private GraphModels.User MapToGraphUser(CoreModels.UserProfile profile)
    {
        var user = new GraphModels.User
        {
            UserPrincipalName = profile.UserPrincipalName,
            DisplayName = profile.DisplayName,
            GivenName = profile.GivenName,
            Surname = profile.Surname,
            Mail = profile.Mail,
            MobilePhone = profile.MobilePhone,
            StreetAddress = profile.StreetAddress,
            City = profile.City,
            State = profile.State,
            PostalCode = profile.PostalCode,
            Country = profile.Country,
            AccountEnabled = profile.AccountEnabled,
            OtherMails = profile.OtherMails,
            UserType = "Member", // Required for External ID
            PasswordProfile = profile.PasswordProfile != null ? new GraphModels.PasswordProfile
            {
                ForceChangePasswordNextSignIn = profile.PasswordProfile.ForceChangePasswordNextSignIn,
                Password = profile.PasswordProfile.Password
            } : null
        };

        if (profile.Identities.Any())
        {
            user.Identities = profile.Identities.Select(i => new GraphModels.ObjectIdentity
            {
                SignInType = i.SignInType,
                Issuer = i.Issuer,
                IssuerAssignedId = i.IssuerAssignedId
            }).ToList();
        }

        if (profile.ExtensionAttributes.Any())
        {
            user.AdditionalData = new Dictionary<string, object>(profile.ExtensionAttributes);
        }

        return user;
    }
}
