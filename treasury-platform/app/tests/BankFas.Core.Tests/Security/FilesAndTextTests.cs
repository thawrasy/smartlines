using System.Security.Cryptography;
using BankFas.Core.Files;
using BankFas.Core.Text;

namespace BankFas.Core.Tests.Security;

public class FilesAndTextTests
{
    [Fact]
    public void A_file_opens_only_with_its_tenant_key_version_and_every_chunk()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var content = RandomNumberGenerator.GetBytes(FileCrypto.ChunkBytes * 2 + 100);
        var sealedFile = FileCrypto.Encrypt(key, content, 7, "t/d/v1", 1);
        Assert.Equal(content, FileCrypto.Decrypt(key, sealedFile, 7, "t/d/v1", 1));
        Assert.ThrowsAny<CryptographicException>(() => FileCrypto.Decrypt(key, sealedFile, 8, "t/d/v1", 1));
        Assert.ThrowsAny<CryptographicException>(() => FileCrypto.Decrypt(key, sealedFile, 7, "t/d/v2", 1));
        Assert.ThrowsAny<CryptographicException>(() => FileCrypto.Decrypt(key, sealedFile, 7, "t/d/v1", 2));
        // Cut after the first chunk: the last-chunk flag no longer matches.
        Assert.ThrowsAny<CryptographicException>(() => FileCrypto.Decrypt(key, sealedFile.AsSpan(0, 8 + FileCrypto.ChunkBytes + 28).ToArray(), 7, "t/d/v1", 1));
        var changed = (byte[])sealedFile.Clone();
        changed[^20] ^= 1;
        Assert.ThrowsAny<CryptographicException>(() => FileCrypto.Decrypt(key, changed, 7, "t/d/v1", 1));
    }

    [Fact]
    public void The_content_type_comes_from_the_bytes_not_the_name()
    {
        Assert.Equal("application/pdf", ContentSniffer.Detect("%PDF-1.7\n"u8));
        Assert.Equal("image/png", ContentSniffer.Detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]));
        Assert.Equal("image/jpeg", ContentSniffer.Detect([0xFF, 0xD8, 0xFF, 0xE0]));
        Assert.Equal("application/x-executable", ContentSniffer.Detect("MZ\u0090\0"u8));
        Assert.Null(ContentSniffer.Detect("hello"u8));
    }

    [Fact]
    public void Identity_numbers_have_a_normal_form_a_mask_and_a_blind_index_per_kind_and_country()
    {
        Assert.Equal("1012345678", BankFas.Core.Security.IdentityNumbers.Normalize("١٠١٢ ٣٤٥-٦٧٨"));
        Assert.Equal("A1234567", BankFas.Core.Security.IdentityNumbers.Normalize(" a123-4567 "));
        Assert.Equal("******5678", BankFas.Core.Security.IdentityNumbers.Mask("1012345678"));
        Assert.Equal("***", BankFas.Core.Security.IdentityNumbers.Mask("123"));
        var key = RandomNumberGenerator.GetBytes(32);
        var a = BankFas.Core.Security.IdentityNumbers.BlindIndex(key, "NATIONAL_ID", "SA", "1012345678");
        Assert.Equal(a, BankFas.Core.Security.IdentityNumbers.BlindIndex(key, "NATIONAL_ID", "sa", "1012345678"));
        Assert.NotEqual(a, BankFas.Core.Security.IdentityNumbers.BlindIndex(key, "PASSPORT", "SA", "1012345678"));
        Assert.NotEqual(a, BankFas.Core.Security.IdentityNumbers.BlindIndex(RandomNumberGenerator.GetBytes(32), "NATIONAL_ID", "SA", "1012345678"));
    }

    [Fact]
    public void Names_phones_and_emails_have_one_normal_form()
    {
        Assert.Equal(Normalizer.Name("أحمد  عبدالله"), Normalizer.Name("احمد عبدالله"));
        Assert.Equal(Normalizer.Name("مؤسسةُ النورِ"), Normalizer.Name("مؤسسه النور"));
        Assert.Equal("acme trading co", Normalizer.Name("ACME  Trading, Co."));
        Assert.Equal("+966501234567", Normalizer.Phone("050 123 4567", "+966"));
        Assert.Equal("+966501234567", Normalizer.Phone("00966501234567", "+966"));
        Assert.Equal("+971501234567", Normalizer.Phone("+971 50 123 4567", "+966"));
        Assert.Equal("+966501234567", Normalizer.Phone("٠٥٠١٢٣٤٥٦٧", "+966"));
        Assert.Null(Normalizer.Phone("12", "+966"));
        Assert.Equal("a.b@example.com", Normalizer.Email(" A.B@Example.COM "));
        Assert.Null(Normalizer.Email("not-an-email"));
        Assert.Equal("AB12", Normalizer.Code("ab 12"));
    }
}
