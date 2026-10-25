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

    /// <summary>Master keys from files on the host (<see cref="FileMasterKeys"/>): the same envelope, references file:....</summary>
    public static LocalKeyWrapper FromFiles(string currentRef, IReadOnlyDictionary<string, byte[]> keys) => new(currentRef, keys, FileMasterKeys.RefPrefix);

    public LocalKeyWrapper(string currentRef, IReadOnlyDictionary<string, byte[]> keys) : this(currentRef, keys, RefPrefix) { }

    /// <param name="currentRef">The reference new values are wrapped under; it starts with "local:".</param>
    /// <param name="keys">Each reference with its 32-byte master key.</param>
    private LocalKeyWrapper(string currentRef, IReadOnlyDictionary<string, byte[]> keys, string prefix)
    {
        ArgumentNullException.ThrowIfNull(keys);
        _keys = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var (name, key) in keys)
        {
            if (!name.StartsWith(prefix, StringComparison.Ordinal) || key.Length != Envelope.KeyBytes)
                throw new ArgumentException($"A master key is named {prefix}... and is 32 bytes ({name}).", nameof(keys));
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

/// <summary>
/// Master keys held in files on the host, outside the database, the image and the configuration (DQ-S02-1, interim
/// until a key store or HSM is chosen): each <c>&lt;name&gt;.key</c> in the directory holds the base64 of 32 bytes and is
/// the key <c>file:&lt;name&gt;</c>. Every file must be readable by its owner only; a looser one is refused, so a key
/// never starts in use after a careless copy. An old key stays in the directory as long as values wrapped under it
/// remain (rotation keeps the old file, adds a new one and makes it current).
/// </summary>
public static class FileMasterKeys
{
    public const string RefPrefix = "file:";

    public static IReadOnlyDictionary<string, byte[]> Load(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
            throw new InvalidOperationException("The master key directory does not exist (Keys:File:Directory).");
        var keys = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var path in Directory.EnumerateFiles(directory, "*.key").Order(StringComparer.Ordinal))
        {
            if (!OperatingSystem.IsWindows()
                && (File.GetUnixFileMode(path) & (UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.OtherRead | UnixFileMode.OtherWrite)) != 0)
                throw new InvalidOperationException($"The master key file {Path.GetFileName(path)} is readable by others than its owner (chmod 400).");
            byte[] key;
            try { key = Convert.FromBase64String(File.ReadAllText(path).Trim()); }
            catch (FormatException) { throw new InvalidOperationException($"The master key file {Path.GetFileName(path)} is not base64."); }
            if (key.Length != Envelope.KeyBytes) throw new InvalidOperationException($"The master key file {Path.GetFileName(path)} does not hold 32 bytes.");
            keys[RefPrefix + Path.GetFileNameWithoutExtension(path)] = key;
        }
        if (keys.Count == 0) throw new InvalidOperationException("The master key directory holds no .key file.");
        return keys;
    }
}
