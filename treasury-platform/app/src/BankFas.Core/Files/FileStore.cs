using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Files;

/// <summary>
/// The encrypted file format of the document store (DOC-S02 section 8): the magic "BFF1", the chunk size (4 bytes
/// big-endian), then each chunk as a random 12-byte nonce, its AES-256-GCM ciphertext and its 16-byte tag. Chunks are
/// 1 MiB but the last. The associated data of a chunk is the tenant id (4 bytes), the storage key (2-byte length and
/// UTF-8 bytes), the version number (4 bytes), the chunk index (4 bytes) and 1 for the last chunk, else 0: a chunk
/// cannot move to another file or place, and a file cut short does not open.
/// </summary>
public static class FileCrypto
{
    public const int ChunkBytes = 1 << 20;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;
    private static readonly byte[] Magic = "BFF1"u8.ToArray();

    private static byte[] Aad(int tenantId, string storageKey, int versionNo, int chunk, bool last)
    {
        var key = Encoding.UTF8.GetBytes(storageKey);
        var aad = new byte[4 + 2 + key.Length + 4 + 4 + 1];
        BinaryPrimitives.WriteInt32BigEndian(aad, tenantId);
        BinaryPrimitives.WriteUInt16BigEndian(aad.AsSpan(4), checked((ushort)key.Length));
        key.CopyTo(aad, 6);
        BinaryPrimitives.WriteInt32BigEndian(aad.AsSpan(6 + key.Length), versionNo);
        BinaryPrimitives.WriteInt32BigEndian(aad.AsSpan(10 + key.Length), chunk);
        aad[^1] = last ? (byte)1 : (byte)0;
        return aad;
    }

    public static byte[] Encrypt(ReadOnlySpan<byte> key, ReadOnlySpan<byte> plaintext, int tenantId, string storageKey, int versionNo)
    {
        var chunks = Math.Max(1, (plaintext.Length + ChunkBytes - 1) / ChunkBytes);
        var output = new byte[8 + plaintext.Length + chunks * (NonceBytes + TagBytes)];
        Magic.CopyTo(output, 0);
        BinaryPrimitives.WriteInt32BigEndian(output.AsSpan(4), ChunkBytes);
        using var aes = new AesGcm(key, TagBytes);
        var at = 8;
        for (var i = 0; i < chunks; i++)
        {
            var part = plaintext.Slice(i * ChunkBytes, Math.Min(ChunkBytes, plaintext.Length - i * ChunkBytes));
            var nonce = output.AsSpan(at, NonceBytes);
            RandomNumberGenerator.Fill(nonce);
            aes.Encrypt(nonce, part, output.AsSpan(at + NonceBytes, part.Length), output.AsSpan(at + NonceBytes + part.Length, TagBytes),
                Aad(tenantId, storageKey, versionNo, i, i == chunks - 1));
            at += NonceBytes + part.Length + TagBytes;
        }
        return output;
    }

    /// <summary>The plaintext, or a <see cref="CryptographicException"/> when a chunk was changed, moved or cut.</summary>
    public static byte[] Decrypt(ReadOnlySpan<byte> key, ReadOnlySpan<byte> file, int tenantId, string storageKey, int versionNo)
    {
        if (file.Length < 8 + NonceBytes + TagBytes || !file[..4].SequenceEqual(Magic)) throw new CryptographicException("Not a BFF1 file.");
        var chunk = BinaryPrimitives.ReadInt32BigEndian(file[4..]);
        if (chunk != ChunkBytes) throw new CryptographicException("Unknown chunk size.");
        using var aes = new AesGcm(key, TagBytes);
        using var output = new MemoryStream();
        var at = 8;
        for (var i = 0; at < file.Length; i++)
        {
            var length = Math.Min(chunk, file.Length - at - NonceBytes - TagBytes);
            if (length < 0) throw new CryptographicException("A chunk is cut short.");
            var last = at + NonceBytes + length + TagBytes == file.Length;
            var plain = new byte[length];
            aes.Decrypt(file.Slice(at, NonceBytes), file.Slice(at + NonceBytes, length), file.Slice(at + NonceBytes + length, TagBytes), plain,
                Aad(tenantId, storageKey, versionNo, i, last));
            output.Write(plain);
            at += NonceBytes + length + TagBytes;
        }
        return output.ToArray();
    }
}

/// <summary>Where the encrypted files live: a directory on its own volume (DQ-S02-10); the storage key is the relative path.</summary>
public sealed class FileStore(string root)
{
    public string Root { get; } = string.IsNullOrWhiteSpace(root) ? throw new InvalidOperationException("Files:Root is not set (DOC-S02 section 8).") : root;

    private string PathOf(string storageKey)
    {
        if (storageKey.Contains("..", StringComparison.Ordinal) || Path.IsPathRooted(storageKey)) throw new ArgumentException("Not a storage key.", nameof(storageKey));
        return Path.Combine(Root, storageKey.Replace('/', Path.DirectorySeparatorChar));
    }

    /// <summary>Writes a new file; a storage key is written once and never replaced (versions are immutable).</summary>
    public async Task WriteAsync(string storageKey, byte[] encrypted, CancellationToken ct)
    {
        var path = PathOf(storageKey);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        await fs.WriteAsync(encrypted, ct).ConfigureAwait(false);
        await fs.FlushAsync(ct).ConfigureAwait(false);
    }

    public Task<byte[]> ReadAsync(string storageKey, CancellationToken ct) => File.ReadAllBytesAsync(PathOf(storageKey), ct);

    /// <summary>Removes a file whose database row was never committed.</summary>
    public void DeleteUncommitted(string storageKey)
    {
        var path = PathOf(storageKey);
        if (File.Exists(path)) File.Delete(path);
    }
}

/// <summary>What the content of a file is, from its first bytes, never from its name (FR-PLT-029).</summary>
public static class ContentSniffer
{
    public static string? Detect(ReadOnlySpan<byte> b)
    {
        if (b.StartsWith("%PDF-"u8)) return "application/pdf";
        if (b.StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })) return "image/png";
        if (b.StartsWith(new byte[] { 0xFF, 0xD8, 0xFF })) return "image/jpeg";
        if (b.StartsWith("GIF87a"u8) || b.StartsWith("GIF89a"u8)) return "image/gif";
        if (b.Length > 12 && b.StartsWith("RIFF"u8) && b[8..12].SequenceEqual("WEBP"u8)) return "image/webp";
        if (b.StartsWith("II*\0"u8) || b.StartsWith("MM\0*"u8)) return "image/tiff";
        if (b.StartsWith("PK\u0003\u0004"u8)) return OfficeOrZip(b);
        if (b.StartsWith(new byte[] { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 })) return "application/x-ole-storage";
        if (b.StartsWith("MZ"u8) || b.StartsWith("\u007fELF"u8)) return "application/x-executable";
        return null;
    }

    /// <summary>A zip is an Office document when its first entry names the Office content types or a known part.</summary>
    private static string OfficeOrZip(ReadOnlySpan<byte> b)
    {
        var head = Encoding.ASCII.GetString(b[..Math.Min(b.Length, 2048)]);
        if (head.Contains("word/", StringComparison.Ordinal)) return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
        if (head.Contains("xl/", StringComparison.Ordinal)) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        if (head.Contains("ppt/", StringComparison.Ordinal)) return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
        return "application/zip";
    }
}
