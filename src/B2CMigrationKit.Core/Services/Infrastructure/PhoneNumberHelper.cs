// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.Text.RegularExpressions;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Helper class for validating phone numbers for the Microsoft Graph phoneMethods API.
/// 
/// Phone numbers exported from B2C via GET /users/{id}/authentication/phoneMethods
/// are already in the correct format (+{country code} {subscriber number}) as defined by
/// the Graph API. No normalization is needed — only basic validation as a safety check.
/// 
/// See: https://learn.microsoft.com/en-us/graph/api/authentication-post-phonemethods
/// </summary>
public static partial class PhoneNumberHelper
{
    /// <summary>
    /// Validates that a phone number is in the format accepted by the Graph phoneMethods API.
    /// The number must start with '+' and contain at least 7 digits.
    /// 
    /// Phone numbers from B2C's phoneMethods API are already correctly formatted.
    /// This method only serves as a safety check — it does NOT transform the number.
    /// </summary>
    public static bool IsValidPhoneNumber(string? phoneNumber)
    {
        if (string.IsNullOrWhiteSpace(phoneNumber))
            return false;

        // Must start with '+', contain a space (country code separator), and have enough digits
        var trimmed = phoneNumber.Trim();
        return trimmed.StartsWith('+') &&
               trimmed.Length >= 8 &&
               DigitsOnly().Replace(trimmed.Substring(1), string.Empty).Length >= 7;
    }

    [GeneratedRegex(@"[^\d]")]
    private static partial Regex DigitsOnly();
}
