using System.Security.Cryptography;
using System.Text;

namespace RE4R.AP.Launcher.Core.Utilities;

/// <summary>
/// Single source of truth for session record keying.
///
/// Session identity is <c>seed_name + slot_name</c> (redesign step 2): the seed
/// name comes from the scout, is globally unique per generated multiworld, and
/// is stable across server address/port changes - archipelago.gg rooms sleep
/// and can restart on a different port, so the server address is mutable
/// metadata on the record, never part of the key (fixes the review's
/// volatile-address-keys critical).
/// </summary>
public static class SessionKeyBuilder
{
    public static string ComputeSessionKey(string seedName, string slotName)
    {
        return ComputeHashKey($"session\n{seedName}\n{slotName}");
    }

    private static string ComputeHashKey(string value)
    {
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }
}
