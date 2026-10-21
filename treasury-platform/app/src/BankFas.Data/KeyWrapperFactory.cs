using BankFas.Core.Security;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace BankFas.Data;

/// <summary>
/// The master key provider (DQ-S02-1 still open): "Keys:Provider" = "local" reads the keys from configuration
/// ("Keys:Local:Current", and a list "Keys:Local:Keys" of {Ref, Key}: the reference and the base64 of 32 bytes), for development and tests only.
/// </summary>
public static class KeyWrapperFactory
{
    public static IKeyWrapper Create(IConfiguration configuration, IHostEnvironment environment)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(environment);
        var provider = configuration["Keys:Provider"] ?? "";
        if (provider != "local") throw new InvalidOperationException("No master key provider is configured (Keys:Provider; DQ-S02-1).");
        if (!environment.IsDevelopment() && !environment.IsEnvironment("Testing"))
            throw new InvalidOperationException("Local master keys are for development and tests only (DOC-S02 section 6).");
        var keys = configuration.GetSection("Keys:Local:Keys").GetChildren()
            .ToDictionary(k => k["Ref"] ?? "", k => Convert.FromBase64String(k["Key"] ?? ""), StringComparer.Ordinal);
        return new LocalKeyWrapper(configuration["Keys:Local:Current"] ?? "", keys);
    }
}
