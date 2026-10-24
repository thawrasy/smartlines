using System.Net;

namespace BankFas.IntegrationTests;

/// <summary>
/// The sign-in of docs/31 row 46 (ADR 0048): the user signs in with the e-mail, the employee code or the mobile number
/// the company allows; an administrator creates a user with a temporary password changed at the first sign-in, or by
/// invitation, as the company allows; two-step verification is set by the platform administration (off for the trial,
/// and a user who enrolled is still asked); and a user may be limited to some products.
/// </summary>
[Collection("database")]
public sealed class SignInTests(PlatformFixture f)
{
    private static Dictionary<string, object> Setting(string key, object value) => new() { [key] = value };

    private async Task<(Guid Id, string Temporary)> CreateWithTemporaryPasswordAsync(TestTenant t, string employeeCode, string mobile, string role = "TM")
    {
        var roles = await t.Portal.GetJsonAsync("/api/v1/roles");
        var roleId = roles.GetProperty("items").EnumerateArray().First(r => r.GetProperty("code").GetString() == role).GetProperty("id").GetString()!;
        var created = await t.Portal.PostOkAsync("/api/v1/users", new
        {
            email = $"{employeeCode.ToLowerInvariant()}@{t.Code}.test.invalid", displayNameEn = "Employee " + employeeCode, roleIds = new[] { roleId },
            employeeCode, mobile, method = "TEMP_PASSWORD", stepUpCode = f.NextCode(t.AdminSecret),
        });
        Assert.Equal("ACTIVE", created.GetProperty("status").GetString());
        Assert.False(created.GetProperty("invitationSent").GetBoolean());
        return (Guid.Parse(created.GetProperty("id").GetString()!), created.GetProperty("temporaryPassword").GetString()!);
    }

    [Fact]
    public async Task A_temporary_password_signs_in_by_employee_code_and_must_be_changed_before_anything_else()
    {
        var t = await f.CreateTenantAsync();
        await f.SetMfaPolicyAsync(t.Code, "OFF");
        var code = "EMP-" + Guid.NewGuid().ToString("N")[..6].ToUpperInvariant();
        var mobile = "+9665" + Random.Shared.Next(10000000, 99999999);
        var (id, temporary) = await CreateWithTemporaryPasswordAsync(t, code, mobile[..4] + " " + mobile[4..]);
        Assert.True(temporary.Length >= 19);
        var user = await t.Portal.GetJsonAsync($"/api/v1/users/{id}");
        Assert.Equal(code, user.GetProperty("user").GetProperty("employeeCode").GetString());
        Assert.Equal(mobile, user.GetProperty("user").GetProperty("mobile").GetString());
        Assert.True(user.GetProperty("user").GetProperty("mustChangePassword").GetBoolean());

        var b = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        var login = await b.PostOkAsync("/api/v1/auth/login", new { login = code, password = temporary });
        Assert.Equal("PASSWORD_CHANGE_REQUIRED", login.GetProperty("nextStep").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await b.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(422, (await b.PostProblemAsync("/api/v1/auth/password-change", new { currentPassword = temporary, newPassword = "short" })).Status);
        Assert.Equal((422, "CURRENT_PASSWORD_INVALID"),
            await b.PostProblemAsync("/api/v1/auth/password-change", new { currentPassword = "not the temporary one", newPassword = "an employee's own passphrase" }));
        var changed = await b.PostOkAsync("/api/v1/auth/password-change", new { currentPassword = temporary, newPassword = "an employee's own passphrase" });
        Assert.Equal("DONE", changed.GetProperty("nextStep").GetString());
        var me = await b.GetJsonAsync("/api/v1/me");
        Assert.False(me.GetProperty("user").GetProperty("mfaRequired").GetBoolean());
        Assert.Equal((409, "STATE_CONFLICT"), await b.PostProblemAsync("/api/v1/auth/password-change", new { currentPassword = "x", newPassword = "another long passphrase" }));

        // The mobile number, typed with 00 and spaces, signs in too; the temporary password no longer does.
        var c = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        Assert.Equal(401, (await c.PostProblemAsync("/api/v1/auth/login", new { login = code, password = temporary })).Status);
        var byMobile = await c.PostOkAsync("/api/v1/auth/login", new { login = "00" + mobile[1..4] + " " + mobile[4..], password = "an employee's own passphrase" });
        Assert.Equal("DONE", byMobile.GetProperty("nextStep").GetString());

        // The company limits the sign-in names to the e-mail: the employee code no longer signs in.
        Assert.Equal((422, "VALIDATION_FAILED"), await t.Portal.ProblemAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = Setting("security.login.identifiers", "EMAIL,BADGE") }));
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = Setting("security.login.identifiers", "EMAIL") })).StatusCode);
        var d = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        Assert.Equal(401, (await d.PostProblemAsync("/api/v1/auth/login", new { login = code, password = "an employee's own passphrase" })).Status);
        await d.PostOkAsync("/api/v1/auth/login", new { login = $"{code.ToLowerInvariant()}@{t.Code}.test.invalid", password = "an employee's own passphrase" });

        // Two users may not share an employee code or a mobile number.
        Assert.Equal((422, "V-PLT-07"), await t.Portal.PostProblemAsync("/api/v1/users", new
        {
            email = $"other-{Guid.NewGuid():N}@{t.Code}.test.invalid", displayNameEn = "Other", employeeCode = code,
        }));
        Assert.Equal((422, "V-USR-MOBILE"), await t.Portal.PostProblemAsync("/api/v1/users", new
        {
            email = $"other-{Guid.NewGuid():N}@{t.Code}.test.invalid", displayNameEn = "Other", mobile = "0501234567",
        }));
    }

    [Fact]
    public async Task Without_required_mfa_the_password_steps_up_and_an_enrolled_user_is_still_asked()
    {
        var t = await f.CreateTenantAsync();
        await f.SetMfaPolicyAsync(t.Code, "OFF");
        var email = $"plain-{Guid.NewGuid().ToString("N")[..8]}@{t.Code}.test.invalid";
        var invited = await t.Portal.PostOkAsync("/api/v1/users", new { email, displayNameEn = "Plain user" });
        var b = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        const string password = "a plain user passphrase";
        await b.PostOkAsync("/api/v1/auth/invitation", new { token = f.Env.LinkTokenSentTo(email), password });
        var login = await b.PostOkAsync("/api/v1/auth/login", new { email, password });
        Assert.Equal("DONE", login.GetProperty("nextStep").GetString());
        Assert.False((await b.GetJsonAsync("/api/v1/me")).GetProperty("user").GetProperty("mfaEnabled").GetBoolean());

        // A step-up takes the password: a wrong one is refused, the right one changes the password.
        Assert.Equal((401, "REAUTH_REQUIRED"), await b.PostProblemAsync("/api/v1/me/password",
            new { currentPassword = password, newPassword = "a second plain passphrase", stepUpCode = "wrong password" }));
        Assert.Equal(HttpStatusCode.NoContent, (await b.SendAsync(HttpMethod.Post, "/api/v1/me/password",
            new { currentPassword = password, newPassword = "a second plain passphrase", stepUpCode = password })).StatusCode);

        // The user enrols an authenticator of their own accord; from then on every sign-in asks for it.
        var c = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        Assert.Equal("DONE", (await c.PostOkAsync("/api/v1/auth/login", new { email, password = "a second plain passphrase" })).GetProperty("nextStep").GetString());
        var enrol = await c.PostOkAsync("/api/v1/auth/mfa/enrolment", new { });
        var secret = PlatformFixture.Base32Decode(enrol.GetProperty("secret").GetString()!);
        await c.PostOkAsync("/api/v1/auth/mfa/enrolment/complete", new { code = f.NextCode(secret) });
        var d = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        Assert.Equal("MFA_REQUIRED", (await d.PostOkAsync("/api/v1/auth/login", new { email, password = "a second plain passphrase" })).GetProperty("nextStep").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await d.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);
        await d.PostOkAsync("/api/v1/auth/mfa", new { code = f.NextCode(secret) });
        Assert.Equal(HttpStatusCode.OK, (await d.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);

        // The platform requires MFA of the tenant again: a user without it must enrol, and a live session without it stops binding.
        await f.SetMfaPolicyAsync(t.Code, "REQUIRED");
        var other = $"late-{Guid.NewGuid().ToString("N")[..8]}@{t.Code}.test.invalid";
        await t.Portal.PostOkAsync("/api/v1/users", new { email = other, displayNameEn = "Late user" });
        var e = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        await e.PostOkAsync("/api/v1/auth/invitation", new { token = f.Env.LinkTokenSentTo(other), password });
        Assert.Equal("MFA_ENROLMENT_REQUIRED", (await e.PostOkAsync("/api/v1/auth/login", new { email = other, password })).GetProperty("nextStep").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await b.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);
        _ = invited;
    }

    [Fact]
    public async Task The_company_chooses_how_users_are_created_and_a_user_may_be_limited_to_some_products()
    {
        var t = await f.CreateTenantAsync();
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = Setting("security.user.creation", "INVITATION") })).StatusCode);
        Assert.Equal((409, "V-USR-CREATION"), await t.Portal.PostProblemAsync("/api/v1/users", new
        {
            email = $"temp-{Guid.NewGuid():N}@{t.Code}.test.invalid", displayNameEn = "Temp", method = "TEMP_PASSWORD", stepUpCode = f.NextCode(t.AdminSecret),
        }));
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = Setting("security.user.creation", "INVITATION,TEMP_PASSWORD") })).StatusCode);

        var (tm, _, tmEmail) = await f.UserWithRoleAsync(t, "TM");
        Assert.Equal(HttpStatusCode.OK, (await tm.GetAsync("/api/v1/facilities", TestContext.Current.CancellationToken)).StatusCode);
        var users = await t.Portal.GetJsonAsync($"/api/v1/users?q={Uri.EscapeDataString(tmEmail)}");
        var id = users.GetProperty("items")[0].GetProperty("id").GetString()!;
        var (_, etag) = await t.Portal.GetWithETagAsync($"/api/v1/users/{id}");
        Assert.Equal((422, "VALIDATION_FAILED"), await t.Portal.ProblemAsync(HttpMethod.Put, $"/api/v1/users/{id}/product-scope", new { mode = "SELECTED", modules = new[] { "NOPE" } }, etag));
        await t.Portal.OkAsync(HttpMethod.Put, $"/api/v1/users/{id}/product-scope", new { mode = "SELECTED", modules = new[] { "REQUESTS" } }, etag);
        var detail = await t.Portal.GetJsonAsync($"/api/v1/users/{id}");
        Assert.Equal(["CORE", "REQUESTS"], detail.GetProperty("products").EnumerateArray().Select(m => m.GetString()));

        var me = await tm.GetJsonAsync("/api/v1/me");
        var modules = me.GetProperty("modules").EnumerateArray().Select(m => m.GetString()).ToList();
        Assert.DoesNotContain("FACILITIES", modules);
        Assert.Contains("CORE", modules);
        Assert.Equal((403, "MODULE_DISABLED"), await tm.ProblemAsync(HttpMethod.Get, "/api/v1/facilities"));

        // An administrator hands an existing user a new temporary password: a reason and a fresh code, and the old one stops working.
        Assert.Equal((422, "VALIDATION_FAILED"), await t.Portal.PostProblemAsync($"/api/v1/users/{id}/actions/temporary-password", new { stepUpCode = f.NextCode(t.AdminSecret) }));
        var reset = await t.Portal.PostOkAsync($"/api/v1/users/{id}/actions/temporary-password", new { reason = "Locked out at the branch", stepUpCode = f.NextCode(t.AdminSecret) });
        var temporary = reset.GetProperty("temporaryPassword").GetString()!;
        Assert.Equal(HttpStatusCode.Unauthorized, (await tm.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);
        var again = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        Assert.Equal("MFA_REQUIRED", (await again.PostOkAsync("/api/v1/auth/login", new { email = tmEmail, password = temporary })).GetProperty("nextStep").GetString());
    }

    [Fact]
    public async Task The_platform_sets_mfa_for_all_tenants_and_the_overview_shows_it()
    {
        f.RequireDatabase();
        var overview = await f.Panel.GetJsonAsync("/api/v1/operator/security/overview");
        Assert.False(overview.GetProperty("mfa").GetProperty("platformRequired").GetBoolean());
        Assert.Equal((403, "STEP_UP_REQUIRED"), await f.Panel.ProblemAsync(HttpMethod.Put, "/api/v1/operator/security/mfa", new { required = true }));
        Assert.Equal(HttpStatusCode.NoContent, (await f.Panel.SendAsync(HttpMethod.Put, "/api/v1/operator/security/mfa",
            new { required = true, mfaCode = f.NextCode(f.OperatorSecret) })).StatusCode);
        try
        {
            Assert.True((await f.Panel.GetJsonAsync("/api/v1/operator/security/overview")).GetProperty("mfa").GetProperty("platformRequired").GetBoolean());
            var t = await f.CreateTenantAsync();
            await f.SetMfaPolicyAsync(t.Code, "PLATFORM");
            var email = $"p-{Guid.NewGuid().ToString("N")[..8]}@{t.Code}.test.invalid";
            await t.Portal.PostOkAsync("/api/v1/users", new { email, displayNameEn = "Platform user" });
            var b = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
            await b.PostOkAsync("/api/v1/auth/invitation", new { token = f.Env.LinkTokenSentTo(email), password = "a platform user passphrase" });
            Assert.Equal("MFA_ENROLMENT_REQUIRED", (await b.PostOkAsync("/api/v1/auth/login", new { email, password = "a platform user passphrase" })).GetProperty("nextStep").GetString());
        }
        finally
        {
            Assert.Equal(HttpStatusCode.NoContent, (await f.Panel.SendAsync(HttpMethod.Put, "/api/v1/operator/security/mfa",
                new { required = false, mfaCode = f.NextCode(f.OperatorSecret) })).StatusCode);
        }
    }
}
