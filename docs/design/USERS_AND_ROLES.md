# Users and roles in every portal (N1, migration 1154)

The platform, carriers, agencies and station operating companies have the same "Users and roles" section
(`/admin/people`, `/carrier/people`, `/agency/people`, `/station/people`; API `/api/people`).

## Who manages people

| Portal | Right | Manages |
|--------|-------|---------|
| Platform | `users.manage` (platform administrators and the ready role "Users administrator") | the platform's staff |
| Carrier, agency, station | the company's owner, or `company.staff` (ready role "… administrator") | the company's own staff |

**Nobody gives what they do not hold.** A role given or defined, and a permission granted as an exception, must be
among the giver's own permissions (a company's owner holds the whole catalogue of the company's kind). Editing a role
may keep permissions already in it; only additions must be held. Refusals answer `NOT_HELD` with the permissions.

## Roles

- Ready roles come from the platform and are never edited (`READY_ROLE`); an administrator copies one as a role of
  their own. Ready roles added in 1154: platform operations, compliance, read only and users administrator; carrier
  administrator, support and read only; agency administrator and read only; station administrator and read only.
- Company roles carry the kind of company they serve (`iam.role.company_kind`); a company sees the ready roles of its
  kind and its own roles only. The external auditor and regulator roles are given through their own flows.
- A member of a company's staff holds one role (`ONE_ROLE`); a platform staff member may hold several.
- A retired role is no longer given; holders keep it until moved.

## Users

- A new member of staff gets a temporary password the administrator chose (N16, 1150) and a second factor is required.
- Nobody changes their own roles or status (`NOT_YOURSELF`); a company's owner is changed by the platform only (`OWNER`).
- Disabling a member ends their open sessions at once.

## Per-user exceptions

`iam.permission_exception`: grant or deny one permission to one person beyond the role.

- Always with a reason and an end date, at most a year ahead (`INVALID_WINDOW`).
- Pending until a second administrator approves it: never the one who asked, never the person it is for (database
  check and `FOUR_EYES`). Approving a grant needs the approver to hold the permission too.
- One open exception per person, company and permission (`EXCEPTION_OPEN`).
- Applied at sign-in and on every request while active and within its dates: a grant adds the permission, a deny
  removes it, after the role and owner permissions.
- What was decided stays decided: a rejected or revoked exception is never changed; an active one is only revoked.
- Rows are row-secured: the platform sees all, a company its own.

All writes need a recent second factor (step-up, 1136) and are in the activity log.
