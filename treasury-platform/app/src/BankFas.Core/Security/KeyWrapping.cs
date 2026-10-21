using System.Security.Cryptography;

namespace BankFas.Core.Security;

/// <summary>
/// The master keys outside the database (DOC-S02 section 6, DQ-S02-1): they wrap the tenant keys of sec.TenantKey
/// and encrypt the operators' TOTP secrets (platform key K-09, PlatformOperator.MfaKeyRef). A key store or HSM
/// implements this without ever exporting a master key; the product is still open (DQ-S02-1), so development and the
/// tests use <see cref="LocalKeyWrapper"/>.
/// </summary>
public interface IKeyWrapper
{
    /// <summary>The master key reference new values are wrapped under (sec.TenantKey.MasterKeyRef).</summary>
    string CurrentMasterKeyRef { get; }

    byte[] Wrap(string masterKeyRef, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> associatedData);

    /// <summary>The plaintext; a <see cref="CryptographicException"/> when the reference is unknown or the data does not open.</summary>
    byte[] Unwrap(string masterKeyRef, ReadOnlySpan<byte> wrapped, ReadOnlySpan<byte> associatedData);
}

/// <summary>Master keys held in the application's configuration: for development and tests only, never production.</summary>
public sealed class LocalKeyWrapper : IKeyWrapper
{
    public const string RefPrefix = "local:";
    private readonly Dictionary<string, byte[]> _keys;

    /// <param name="currentRef">The reference new values are wrapped under; it starts with "local:".</param>
    /// <param name="keys">Each reference with its 32-byte master key.</param>
    public LocalKeyWrapper(string currentRef, IReadOnlyDictionary<string, byte[]> keys)
    {
        ArgumentNullException.ThrowIfNull(keys);
        _keys = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var (name, key) in keys)
        {
            if (!name.StartsWith(RefPrefix, StringComparison.Ordinal) || key.Length != Envelope.KeyBytes)
                throw new ArgumentException($"A local master key is named local:... and is 32 bytes ({name}).", nameof(keys));
            _keys[name] = key.ToArray();
        }
        if (!_keys.ContainsKey(currentRef)) throw new ArgumentException("The current master key is not among the keys.", nameof(currentRef));
        CurrentMasterKeyRef = currentRef;
    }

    public string CurrentMasterKeyRef { get; }

    public byte[] Wrap(string masterKeyRef, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> associatedData) =>
        Envelope.Seal(KeyOf(masterKeyRef), plaintext, associatedData);

    public byte[] Unwrap(string masterKeyRef, ReadOnlySpan<byte> wrapped, ReadOnlySpan<byte> associatedData) =>
        Envelope.Open(KeyOf(masterKeyRef), wrapped, associatedData);

    private byte[] KeyOf(string masterKeyRef) =>
        _keys.TryGetValue(masterKeyRef, out var key) ? key : throw new CryptographicException($"Unknown master key {masterKeyRef}.");
}
