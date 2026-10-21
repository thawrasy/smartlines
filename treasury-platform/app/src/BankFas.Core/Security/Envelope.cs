using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Security;

/// <summary>
/// The envelope of every encrypted column (DOC-S02 section 6, docs/20 section 6.2): version 0x01 (1 byte), a random
/// 12-byte nonce, the AES-256-GCM ciphertext and its 16-byte tag; at least 29 bytes, as the column checks require.
/// The associated data ties a value to its tenant, table, column and row, so a value copied to another row or tenant
/// does not decrypt.
/// </summary>
public static class Envelope
{
    public const byte Version = 0x01;
    public const int KeyBytes = 32;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;
    public const int Overhead = 1 + NonceBytes + TagBytes;

    public static byte[] Seal(ReadOnlySpan<byte> key, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> associatedData)
    {
        if (key.Length != KeyBytes) throw new ArgumentException("An AES-256 key is 32 bytes.", nameof(key));
        var output = new byte[Overhead + plaintext.Length];
        output[0] = Version;
        var nonce = output.AsSpan(1, NonceBytes);
        RandomNumberGenerator.Fill(nonce);
        using var aes = new AesGcm(key, TagBytes);
        aes.Encrypt(nonce, plaintext, output.AsSpan(1 + NonceBytes, plaintext.Length), output.AsSpan(1 + NonceBytes + plaintext.Length), associatedData);
        return output;
    }

    /// <summary>The plaintext, or a <see cref="CryptographicException"/> for a wrong key, data or version.</summary>
    public static byte[] Open(ReadOnlySpan<byte> key, ReadOnlySpan<byte> envelope, ReadOnlySpan<byte> associatedData)
    {
        if (key.Length != KeyBytes) throw new ArgumentException("An AES-256 key is 32 bytes.", nameof(key));
        if (envelope.Length < Overhead || envelope[0] != Version) throw new CryptographicException("Not an envelope of version 1.");
        var length = envelope.Length - Overhead;
        var plaintext = new byte[length];
        using var aes = new AesGcm(key, TagBytes);
        aes.Decrypt(envelope.Slice(1, NonceBytes), envelope.Slice(1 + NonceBytes, length), envelope[^TagBytes..], plaintext, associatedData);
        return plaintext;
    }
}

/// <summary>
/// The associated data of an envelope (ADR 0040): the tenant id as 4 bytes big-endian (0 for platform values), then
/// each text part as a 2-byte big-endian length and its UTF-8 bytes, then the row's PublicId as 16 bytes in RFC 4122
/// order. The lengths keep "sec.AppUser" + "MfaSecretEnc" from reading the same as any other split of those bytes.
/// </summary>
public static class EnvelopeAad
{
    public static byte[] ForColumn(int tenantId, string table, string column, Guid rowPublicId)
    {
        using var ms = new MemoryStream();
        WriteInt(ms, tenantId);
        WriteText(ms, table);
        WriteText(ms, column);
        ms.Write(rowPublicId.ToByteArray(bigEndian: true));
        return ms.ToArray();
    }

    /// <summary>The associated data of a tenant key wrapped by a master key: tenant, purpose and version.</summary>
    public static byte[] ForTenantKey(int tenantId, string purpose, int keyVersion)
    {
        using var ms = new MemoryStream();
        WriteInt(ms, tenantId);
        WriteText(ms, "sec.TenantKey");
        WriteText(ms, purpose);
        WriteInt(ms, keyVersion);
        return ms.ToArray();
    }

    private static void WriteInt(MemoryStream ms, int value)
    {
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b, value);
        ms.Write(b);
    }

    private static void WriteText(MemoryStream ms, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        Span<byte> len = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(len, checked((ushort)bytes.Length));
        ms.Write(len);
        ms.Write(bytes);
    }
}
