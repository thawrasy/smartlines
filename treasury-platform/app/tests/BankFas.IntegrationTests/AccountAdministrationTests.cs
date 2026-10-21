using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Users, roles, company scope, sessions and passwords of the tenant portal (SCR-PLT-03, 07 to 10, 15; AC-PLT-11 to
/// AC-PLT-13), against the database: what the procedures enforce, and what the application adds (the last account
/// administrator, step-up, locked permissions, ETags, Idempotency-Key, cursors).
/// </summary>
[Collection("database")]
public sealed class AccountAdministrationTests(PlatformFixture f)
{
    private static async Task<string> RoleIdAsync(HttpClient portal, string code)
    {
        var roles = await portal.GetJsonAsync("/api/v1/roles");
        return roles.GetProperty("items").EnumerateArray().First(r => r.GetProperty("code").GetString() == code).GetProperty("id").GetString()!;
    }

    [Fact]
    public async Task An_administrator_invites_and_manages_a_user()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;
        var ct = TestContext.Current.CancellationToken;
        var te = await RoleIdAsync(admin, "TE");
        var tm = await RoleIdAsync(admin, "TM");

        // The list shows the administrator and refuses unknown parameters.
        var users = await admin.GetJsonAsync("/api/v1/users");
        Assert.Single(users.GetProperty("items").EnumerateArray());
        Assert.Equal((400, "UNKNOWN_PARAMETER"), await admin.ProblemAsync(HttpMethod.Get, "/api/v1/users?bogus=1"));

        // Invite: a TE user goes straight; TM needs a fresh code; the same e-mail twice is refused.
        var bEmail = $"b@{t.Code}.test.invalid";
        var invited = await admin.PostOkAsync("/api/v1/users", new { email = bEmail, displayNameEn = "User B", roleIds = new[] { te } });
        var bId = PlatformFixture.Id(invited);
        Assert.True(invited.GetProperty("invitationSent").GetBoolean());
        Assert.Equal((422, "V-PLT-07"), await admin.PostProblemAsync("/api/v1/users", new { email = bEmail, displayNameEn = "Again" }));
        var cEmail = $"c@{t.Code}.test.invalid";
        Assert.Equal((401, "REAUTH_REQUIRED"), await admin.PostProblemAsync("/api/v1/users", new { email = cEmail, displayNameEn = "User C", roleIds = new[] { tm } }));
        await admin.PostOkAsync("/api/v1/users", new { email = cEmail, displayNameEn = "User C", roleIds = new[] { tm }, stepUpCode = f.NextCode(t.AdminSecret) });

        // The same Idempotency-Key replays the first answer; with another body it is refused.
        var key = Guid.NewGuid().ToString();
        var dBody = new { email = $"d@{t.Code}.test.invalid", displayNameEn = "User D" };
        var first = await admin.SendAsync(HttpMethod.Post, "/api/v1/users", dBody, idempotencyKey: key);
        var again = await admin.SendAsync(HttpMethod.Post, "/api/v1/users", dBody, idempotencyKey: key);
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        Assert.Equal(HttpStatusCode.Created, again.StatusCode);
        Assert.True(again.Headers.Contains("Idempotent-Replayed"));
        Assert.Equal(await first.Content.ReadAsStringAsync(ct), await again.Content.ReadAsStringAsync(ct));
        Assert.Equal(HttpStatusCode.UnprocessableEntity,
            (await admin.SendAsync(HttpMethod.Post, "/api/v1/users", dBody with { displayNameEn = "Other" }, idempotencyKey: key)).StatusCode);

        // Pages by cursor; a cursor the server did not issue is refused.
        var page1 = await admin.GetJsonAsync("/api/v1/users?limit=2");
        Assert.Equal(2, page1.GetProperty("items").GetArrayLength());
        var cursor = page1.GetProperty("nextCursor").GetString()!;
        var page2 = await admin.GetJsonAsync("/api/v1/users?limit=2&cursor=" + cursor);
        Assert.Equal(2, page2.GetProperty("items").GetArrayLength());
        Assert.Equal((400, "INVALID_CURSOR"), await admin.ProblemAsync(HttpMethod.Get, "/api/v1/users?cursor=AAAA" + cursor[4..]));

        // B accepts and signs in; B holds no sec.user.manage.
        var b = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        const string bPassword = "user b long passphrase";
        await b.PostOkAsync("/api/v1/auth/invitation", new { token = f.Env.LinkTokenSentTo(bEmail), password = bPassword });
        var (bSecret, _) = await f.SignInFirstTimeAsync(b, bEmail, bPassword);
        Assert.Equal((403, "FORBIDDEN"), await b.ProblemAsync(HttpMethod.Get, "/api/v1/users"));

        // Details carry an ETag; a change needs it in If-Match.
        var (detail, etag) = await admin.GetWithETagAsync($"/api/v1/users/{bId}");
        Assert.Equal("ACTIVE", detail.GetProperty("user").GetProperty("status").GetString());
        Assert.Equal((428, "PRECONDITION_REQUIRED"), await admin.ProblemAsync(HttpMethod.Patch, $"/api/v1/users/{bId}", new { displayNameEn = "B" }));
        Assert.Equal(HttpStatusCode.NoContent, (await admin.SendAsync(HttpMethod.Patch, $"/api/v1/users/{bId}", new { displayNameEn = "User Bee" }, etag)).StatusCode);
        Assert.Equal((409, "VERSION_CONFLICT"), await admin.ProblemAsync(HttpMethod.Patch, $"/api/v1/users/{bId}", new { displayNameEn = "Stale" }, etag));

        // The only account administrator cannot drop TA, disable or archive themself.
        var me = await admin.GetJsonAsync("/api/v1/me");
        var adminId = (await admin.GetJsonAsync("/api/v1/users")).GetProperty("items").EnumerateArray()
            .First(u => u.GetProperty("email").GetString() == t.AdminEmail).GetProperty("id").GetString()!;
        var (_, adminTag) = await admin.GetWithETagAsync($"/api/v1/users/{adminId}");
        Assert.Equal((409, "LAST_ACCOUNT_ADMIN"), await admin.ProblemAsync(HttpMethod.Put, $"/api/v1/users/{adminId}/roles", new { roleIds = new[] { te } }, adminTag));
        Assert.Equal((409, "STATUS_CHANGE_NOT_ALLOWED"), await admin.ProblemAsync(HttpMethod.Post, $"/api/v1/users/{adminId}/actions/disable", new { reason = "test" }));
        Assert.NotEqual(JsonValueKind.Undefined, me.ValueKind);

        // Sessions: the administrator sees B's session and ends it; B is signed out.
        var sessions = await admin.GetJsonAsync($"/api/v1/users/{bId}/sessions");
        var sessionRef = sessions.GetProperty("items")[0].GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await admin.SendAsync(HttpMethod.Delete, $"/api/v1/users/{bId}/sessions/{sessionRef}")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await b.GetAsync("/api/v1/me", ct)).StatusCode);

        // Disable ends access; enable restores it.
        Assert.Equal((422, "VALIDATION_FAILED"), await admin.PostProblemAsync($"/api/v1/users/{bId}/actions/disable", new { }));
        var disabled = await admin.PostOkAsync($"/api/v1/users/{bId}/actions/disable", new { reason = "Left the company" });
        Assert.Equal("DISABLED", disabled.GetProperty("status").GetString());
        Assert.Equal(401, (await b.PostProblemAsync("/api/v1/auth/login", new { email = bEmail, password = bPassword })).Status);
        Assert.Equal("ACTIVE", (await admin.PostOkAsync($"/api/v1/users/{bId}/actions/enable", new { })).GetProperty("status").GetString());
        await f.SignInAsync(b, bEmail, bPassword, bSecret);

        // An MFA reset takes a reason and a fresh code; B then re-enrols only through the e-mailed link.
        Assert.Equal((401, "REAUTH_REQUIRED"), await admin.PostProblemAsync($"/api/v1/users/{bId}/actions/reset-mfa", new { reason = "Lost phone" }));
        await admin.PostOkAsync($"/api/v1/users/{bId}/actions/reset-mfa", new { reason = "Lost phone", stepUpCode = f.NextCode(t.AdminSecret) });
        var relogin = await b.PostOkAsync("/api/v1/auth/login", new { email = bEmail, password = bPassword });
        Assert.Equal("MFA_REENROLMENT_REQUIRED", relogin.GetProperty("nextStep").GetString());
        Assert.Equal((422, "LINK_REQUIRED"), await b.PostProblemAsync("/api/v1/auth/mfa/enrolment", new { }));
        var reenrol = f.Env.LinkTokenSentTo(bEmail);
        var (bSecret2, _) = await f.SignInFirstTimeAsync(b, bEmail, bPassword, reenrol);
        Assert.NotEqual(bSecret, bSecret2);
        Assert.Equal(HttpStatusCode.OK, (await b.GetAsync("/api/v1/me", ct)).StatusCode);
    }

    [Fact]
    public async Task Roles_keep_locked_permissions_to_the_platform_roles()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;
        var permissions = await admin.GetJsonAsync("/api/v1/permissions");
        var locked = permissions.GetProperty("items").EnumerateArray()
            .First(p => p.GetProperty("lockedToRoleCodes").ValueKind == JsonValueKind.String).GetProperty("code").GetString()!;
        Assert.Equal((403, "PERMISSION_LOCKED"),
            await admin.PostProblemAsync("/api/v1/roles", new { code = "CUSTOM", nameEn = "Custom", nameAr = "مخصص", permissions = new[] { locked } }));
        var created = await admin.PostOkAsync("/api/v1/roles", new { code = "custom", nameEn = "Custom", nameAr = "مخصص", permissions = new[] { "audit.view" } });
        var id = PlatformFixture.Id(created);
        Assert.Equal("CUSTOM", created.GetProperty("code").GetString());
        Assert.Equal((409, "DUPLICATE"), await admin.PostProblemAsync("/api/v1/roles", new { code = "CUSTOM", nameEn = "Again", nameAr = "مرة" }));

        var (role, etag) = await admin.GetWithETagAsync($"/api/v1/roles/{id}");
        Assert.Equal(["audit.view"], role.GetProperty("permissions").EnumerateArray().Select(p => p.GetString()));
        Assert.Equal(HttpStatusCode.NoContent,
            (await admin.SendAsync(HttpMethod.Put, $"/api/v1/roles/{id}/permissions", new { permissions = new[] { "audit.view", "cfg.jobs.view" } }, etag)).StatusCode);
        Assert.Equal((409, "VERSION_CONFLICT"),
            await admin.ProblemAsync(HttpMethod.Put, $"/api/v1/roles/{id}/permissions", new { permissions = Array.Empty<string>() }, etag));
        Assert.Equal(2, (await admin.GetJsonAsync($"/api/v1/roles/{id}")).GetProperty("permissions").GetArrayLength());

        // A system role stays active; a copy of TA is a tenant role.
        var ta = await RoleIdAsync(admin, "TA");
        var (_, taTag) = await admin.GetWithETagAsync($"/api/v1/roles/{ta}");
        Assert.Equal((409, "IN_USE"), await admin.ProblemAsync(HttpMethod.Patch, $"/api/v1/roles/{ta}", new { isActive = false }, taTag));
        var copy = await admin.PostOkAsync($"/api/v1/roles/{ta}/actions/copy", new { code = "TA_COPY", nameEn = "Admin copy", nameAr = "نسخة" });
        var copied = await admin.GetJsonAsync($"/api/v1/roles/{PlatformFixture.Id(copy)}");
        Assert.False(copied.GetProperty("isSystem").GetBoolean());
        Assert.Contains(copied.GetProperty("permissions").EnumerateArray(), p => p.GetString() == "sec.user.manage");
    }

    [Fact]
    public async Task Passwords_are_reset_by_link_and_changed_with_the_current_one_and_a_fresh_code()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;
        var ct = TestContext.Current.CancellationToken;
        var anon = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");

        // The same answer for an unknown address and a real one; only the real one gets a link.
        var unknown = await anon.SendAsync(HttpMethod.Post, "/api/v1/auth/password-reset-requests", new { email = "nobody@test.invalid" });
        var known = await anon.SendAsync(HttpMethod.Post, "/api/v1/auth/password-reset-requests", new { email = t.AdminEmail });
        Assert.Equal(HttpStatusCode.Accepted, unknown.StatusCode);
        Assert.Equal(HttpStatusCode.Accepted, known.StatusCode);
        Assert.Equal(await unknown.Content.ReadAsStringAsync(ct), await known.Content.ReadAsStringAsync(ct));
        var link = f.Env.LinkTokenSentTo(t.AdminEmail);

        // A leaked password is refused (DQ-S04-1), and the link still works after it.
        Assert.Equal((422, "PASSWORD_BREACHED"), await anon.PostProblemAsync("/api/v1/auth/password-resets", new { token = link, newPassword = TestEnvironment.LeakedPassword }));

        // The current password cannot be reused; a new one works once and ends every session.
        Assert.Equal((422, "PASSWORD_REUSED"), await anon.PostProblemAsync("/api/v1/auth/password-resets", new { token = link, newPassword = t.AdminPassword }));
        const string reset = "a brand new reset passphrase";
        await anon.PostOkAsync("/api/v1/auth/password-resets", new { token = link, newPassword = reset });
        Assert.Equal((422, "LINK_INVALID"), await anon.PostProblemAsync("/api/v1/auth/password-resets", new { token = link, newPassword = "yet another passphrase" }));
        Assert.Equal(HttpStatusCode.Unauthorized, (await admin.GetAsync("/api/v1/me", ct)).StatusCode);
        await f.SignInAsync(admin, t.AdminEmail, reset, t.AdminSecret);

        // A change needs the current password and a fresh code.
        const string changed = "the changed passphrase now";
        Assert.Equal((401, "REAUTH_REQUIRED"), await admin.PostProblemAsync("/api/v1/me/password", new { currentPassword = reset, newPassword = changed }));
        Assert.Equal((422, "CURRENT_PASSWORD_INVALID"),
            await admin.PostProblemAsync("/api/v1/me/password", new { currentPassword = "not the password", newPassword = changed, stepUpCode = f.NextCode(t.AdminSecret) }));
        await f.SignInAsync(admin, t.AdminEmail, reset, t.AdminSecret);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.SendAsync(HttpMethod.Post, "/api/v1/me/password",
            new { currentPassword = reset, newPassword = changed, stepUpCode = f.NextCode(t.AdminSecret) })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync("/api/v1/me", ct)).StatusCode);   // the session that changed it stays
        var mine = await admin.GetJsonAsync("/api/v1/me/sessions");
        Assert.Single(mine.GetProperty("items").EnumerateArray());
        await admin.SendAsync(HttpMethod.Post, "/api/v1/auth/logout", new { });
        Assert.Equal(401, (await admin.PostProblemAsync("/api/v1/auth/login", new { email = t.AdminEmail, password = reset })).Status);
        await f.SignInAsync(admin, t.AdminEmail, changed, t.AdminSecret);
    }
}
