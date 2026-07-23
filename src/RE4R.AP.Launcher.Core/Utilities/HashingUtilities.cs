using System.Security.Cryptography;

namespace RE4R.AP.Launcher.Core.Utilities;

public static class HashingUtilities
{
    public static async Task<string> ComputeSha256HexAsync(string filePath, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);

        var stream = File.OpenRead(filePath);
        await using (stream.ConfigureAwait(false))
        {
            using var sha256 = SHA256.Create();
            var hash = await sha256.ComputeHashAsync(stream, cancellationToken).ConfigureAwait(false);
            return Convert.ToHexStringLower(hash);
        }
    }
}
