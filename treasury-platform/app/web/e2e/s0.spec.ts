// The S0 exit path (AC-PLT-5) in a browser: the operator sets up from the deployment's link and signs in with TOTP,
// creates a tenant with a fresh code, the worker invites its first administrator, who sets a password, scans the QR
// code, keeps the recovery codes and reaches the portal; the portal then switches to Arabic, right to left. Then the
// S1 exit path (AC-INS-1): the administrator adds a company and onboards a bank with the set-up wizard, whose review
// warns of the products without a default contact before anything is created. Then S2-b (docs/47 §4): the administrator
// invites a financial analyst, who signs in, enters a statement in the grid and sees its totals live, and opens the formula
// library, the credit self-assessments and the group compliance. Then S3 (docs/48): the dashboards, the inbox and the
// bank form templates. Then S4 (docs/49): the register of proformas and the received letters of credit.
import { expect, test, type Page } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { Authenticator, base32Decode, linkSentTo } from './helpers';

const mailDir = process.env.E2E_MAIL_DIR ?? '';
const setupLink = process.env.E2E_SETUP_LINK ?? '';
const port = process.env.E2E_PORT ?? '8443';
const operatorEmail = process.env.E2E_OPERATOR_EMAIL ?? 'e2e-operator@test.invalid';
// The portal's menu is grouped by module (docs/31 row 59): a screen's link shows once its group is open.
const groupOf: Record<string, string> = {'Companies': 'Companies and parties', 'Banks and lenders': 'Banks and accounts', 'Governance conflicts': 'Companies and parties', 'Compare terms': 'Credit facilities', 'Users': 'Employees and access', 'Financial statements': 'Credit and risk', 'Formula library': 'Credit and risk', 'Credit self-assessments': 'Credit and risk', 'Group compliance': 'Credit facilities', 'Bank form templates': 'Treasury requests'};
async function openGroup(page: Page, group: string) {
  const head = page.getByRole('button', { name: new RegExp(`^${group}`) });
  if (await head.count() === 0) return;   // no screen of the group for this user
  if (await head.getAttribute('aria-expanded') !== 'true') await head.click();
}
async function openMenu(page: Page, name: string) {
  const link = page.getByRole('link', { name, exact: true });
  if (!(await link.isVisible())) await openGroup(page, groupOf[name] ?? '');
  await link.click();
}

// Screenshots of the screens along the way (docs/59), only when E2E_SHOTS names a folder; the test is the same without.
const shots = process.env.E2E_SHOTS ?? '';
async function shot(page: Page, name: string) {
  if (!shots) return;
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.waitForLoadState('networkidle').catch(() => undefined);
  await page.screenshot({ path: `${shots}/${name}.png` });
}

const leaked = 'correct horse battery staple';   // on the throwaway leaked-password list of tools/ci/e2e.sh

test('an operator onboards a tenant and its first administrator signs in', async ({ page, browser }) => {
  expect(setupLink, 'E2E_SETUP_LINK (tools/ci/e2e.sh)').not.toBe('');

  // The operator's set-up page: password, authenticator key and first code.
  await page.goto(setupLink);
  await expect(page.getByRole('heading', { name: 'Set up your operator account' })).toBeVisible();
  const opSecretText = await page.locator('.secret code').innerText();
  await expect(page.getByAltText('QR code for the authenticator app')).toBeVisible();
  const op = new Authenticator(base32Decode(opSecretText));
  const opPassword = 'an e2e operator passphrase';
  await page.getByLabel(/^Password \(at least 14/).fill(opPassword);
  await page.getByLabel('6-digit code').fill(await op.next());
  await page.getByRole('button', { name: 'Finish set-up' }).click();
  await expect(page).toHaveURL(/\/login$/);

  // Sign-in, then the second step.
  await page.getByLabel(/^E-mail/).fill(operatorEmail);
  await page.getByLabel(/^Password/).fill(opPassword);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByLabel(/^Code from your authenticator/).fill(await op.next());
  await page.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByRole('heading', { name: 'Tenants' })).toBeVisible();

  // A new tenant, confirmed with a fresh code in the dialog.
  const code = 'ci-e2e-' + Math.random().toString(36).slice(2, 8);
  const adminEmail = `admin@${code}.test.invalid`;
  await page.getByLabel(/^Sub-domain/).fill(code);
  await page.getByLabel(/^Name \(English\)/).fill('E2E Trading');
  await page.getByLabel(/^Name \(Arabic\)/).fill('شركة الاختبار');
  await page.getByLabel(/^First administrator's e-mail/).fill(adminEmail);
  await page.getByLabel(/^First administrator's name/).fill('First Admin');
  await page.getByRole('button', { name: 'Create tenant' }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText('Creating a tenant needs a fresh code.')).toBeVisible();
  await dialog.getByLabel('6-digit code').fill(await op.next());
  await dialog.getByRole('button', { name: 'Confirm' }).click();
  await expect(page.getByRole('link', { name: code })).toBeVisible();
  await shot(page, '01-operator-tenants');

  // Two-step verification is a platform choice, off for the trial (ADR 0048); this tenant's users are required to use it.
  await page.getByRole('link', { name: code }).click();
  await page.getByLabel(/^Two-step verification for this tenant/).selectOption('REQUIRED');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await dialog.getByLabel('6-digit code').fill(await op.next());
  await dialog.getByRole('button', { name: 'Confirm' }).click();
  await expect(page.getByText('Two-step verification: Required')).toBeVisible();
  await shot(page, '02-operator-tenant');
  await page.getByRole('link', { name: 'Tenants' }).click();

  // Hands an operator administrator to the integration tests, which run next on the same database.
  const handoff = process.env.E2E_HANDOFF_FILE;
  if (handoff) {
    const itEmail = process.env.E2E_HANDOFF_EMAIL ?? 'it-operator@test.invalid';
    await page.getByRole('link', { name: 'Operators' }).click();
    await page.getByLabel(/^E-mail/).fill(itEmail);
    await page.getByLabel(/^Name/).fill('Integration operator');
    await page.getByLabel(/^Role/).selectOption('OPERATOR_ADMIN');
    await page.getByRole('button', { name: 'Send the invitation' }).click();
    await dialog.getByLabel('6-digit code').fill(await op.next());
    await dialog.getByRole('button', { name: 'Confirm' }).click();
    await expect(page.getByText(itEmail)).toBeVisible();
    const link = await linkSentTo(mailDir, itEmail, '/setup');
    writeFileSync(handoff, new URL(link).hash.replace(/^#token=/, ''));
  }

  // The worker prepares the tenant and invites its first administrator.
  const invitation = await linkSentTo(mailDir, adminEmail, '/invitation', 90_000);
  expect(new URL(invitation).host).toBe(`${code}.bankfas.test:${port}`);
  await page.goto(invitation);
  await expect(page).toHaveURL(/\/invitation$/);   // the token leaves the address bar
  const adminPassword = 'an e2e administrator passphrase';

  // A leaked password is refused (DQ-S04-1); the link still works after it.
  await page.getByLabel(/^New password/).fill(leaked);
  await page.getByLabel(/^Repeat the password/).fill(leaked);
  await page.getByRole('button', { name: 'Save password' }).click();
  await expect(page.getByText('This password is on a list of leaked passwords. Choose another.')).toBeVisible();
  await page.getByLabel(/^New password/).fill(adminPassword);
  await page.getByLabel(/^Repeat the password/).fill(adminPassword);
  await page.getByRole('button', { name: 'Save password' }).click();
  await expect(page).toHaveURL(/\/login$/);

  // First sign-in: the authenticator is set up from the QR code page, and the recovery codes are shown once.
  await page.getByLabel(/^E-mail/).fill(adminEmail);
  await page.getByLabel(/^Password/).fill(adminPassword);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('heading', { name: 'Set up your authenticator' })).toBeVisible();
  await expect(page.getByAltText('QR code for the authenticator app')).toBeVisible();
  const admin = new Authenticator(base32Decode(await page.locator('.secret code').innerText()));
  await page.getByLabel('6-digit code').fill(await admin.next());
  await page.getByRole('button', { name: 'Confirm' }).click();
  await expect(page.getByRole('heading', { name: 'Keep your recovery codes' })).toBeVisible();
  await expect(page.locator('ol.codes li')).toHaveCount(10);
  await page.getByRole('button', { name: 'I have saved them' }).click();
  await expect(page.getByRole('heading', { name: /^Welcome, / })).toBeVisible();

  // Arabic, right to left (FR-PLT-032).
  await page.getByRole('button', { name: 'العربية' }).click();
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl');
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar');
  await expect(page.getByRole('heading', { name: /^أهلًا / })).toBeVisible();
  await expect(page.getByRole('button', { name: 'English' })).toBeVisible();
  await page.getByRole('button', { name: 'English' }).click();

  // S1: a company, then a bank with the wizard (AC-INS-1).
  await openMenu(page, 'Companies');
  await page.getByLabel(/^Company code/).fill('C1');
  await page.getByLabel(/^Name \(Arabic\)/).fill('الشركة الأولى');
  await page.getByLabel(/^Name \(English\)/).fill('First Company');
  await page.getByLabel(/^Country/).fill('SA');
  await page.getByLabel(/^Fiscal year ends in month/).fill('12');
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('heading', { name: /First Company|الشركة الأولى/ })).toBeVisible();

  await openMenu(page, 'Banks and lenders');
  await page.getByRole('link', { name: 'Bank set-up wizard' }).click();
  // The list page has a form with the same labels: type only once the wizard has replaced it.
  await expect(page.getByRole('heading', { name: 'Bank set-up wizard' })).toBeVisible();
  await page.getByLabel(/^Code/).fill('BNK1');
  await page.getByLabel(/^Name \(Arabic\)/).fill('البنك الأول');
  await page.getByLabel(/^Country/).fill('AE');
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByRole('checkbox', { name: /First Company/ }).check();
  await page.getByPlaceholder('Customer number').fill('10001');
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByPlaceholder('Name (Arabic)').fill('مدير العلاقة');
  await page.getByPlaceholder('Mobile').fill('0501234567');
  await page.getByRole('button', { name: 'Add' }).click();
  await page.getByLabel(/^Relationship manager/).selectOption({ label: 'مدير العلاقة' });
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByRole('checkbox', { name: /^Purchase letter of credit \(conventional\) · First Company$/ }).check();
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(page.getByText('Products without a default contact (1)')).toBeVisible();
  await shot(page, '06-bank-wizard-review');
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('heading', { name: /BNK1/ })).toBeVisible();
  await expect(page.getByRole('link', { name: /First Company|الشركة الأولى/ })).toBeVisible();

  // S1-b: the ownership tab of the company and the governance conflicts report (R-ACC-04).
  await openMenu(page, 'Companies');
  await page.getByRole('link', { name: 'C1' }).click();
  await page.getByRole('tab', { name: 'Ownership' }).click();
  await expect(page.getByText(/Direct holdings total/)).toBeVisible();
  await openMenu(page, 'Governance conflicts');
  await expect(page.getByRole('heading', { name: 'Governance conflicts' })).toBeVisible();

  // S2: the comparison of a comparable term across facilities (SCR-CMP-01); the keys come from CMP.TERMS.
  await openMenu(page, 'Compare terms');
  await expect(page.getByRole('heading', { name: 'Compare terms' })).toBeVisible();
  await page.getByLabel(/^Key/).selectOption({ value: 'PRC.ARRANGEMENT_FEE_PCT' });
  await expect(page.getByText('Lower is better')).toBeVisible();   // no facility yet: the direction, and nothing ranked
  await expect(page.getByText('Nothing here yet.')).toBeVisible();
  // S2-b: a financial analyst (FA enters statements and assessments; TM only approves them), given every company.
  const tmEmail = `fa@${code}.test.invalid`;
  await openMenu(page, 'Users');
  await page.getByLabel(/^E-mail/).fill(tmEmail);
  await page.getByLabel(/^Name \(English\)/).fill('Financial Analyst');
  await page.getByRole('checkbox', { name: /^FA · / }).check();
  await page.getByRole('button', { name: 'Send the invitation' }).click();
  await expect(page.getByText('The invitation is on its way.')).toBeVisible();
  await page.getByRole('link', { name: 'Financial Analyst' }).click();
  await page.getByRole('button', { name: 'Save scope' }).click();
  await expect(page.getByText('Sees every company.')).toBeVisible();

  const tmContext = await browser.newContext();
  const tmPage = await tmContext.newPage();
  await tmPage.goto(await linkSentTo(mailDir, tmEmail, '/invitation', 90_000));
  const tmPassword = 'an e2e financial analyst passphrase';
  await tmPage.getByLabel(/^New password/).fill(tmPassword);
  await tmPage.getByLabel(/^Repeat the password/).fill(tmPassword);
  await tmPage.getByRole('button', { name: 'Save password' }).click();
  await tmPage.getByLabel(/^E-mail/).fill(tmEmail);
  await tmPage.getByLabel(/^Password/).fill(tmPassword);
  await tmPage.getByRole('button', { name: 'Sign in' }).click();
  const tmAuth = new Authenticator(base32Decode(await tmPage.locator('.secret code').innerText()));
  await tmPage.getByLabel('6-digit code').fill(await tmAuth.next());
  await tmPage.getByRole('button', { name: 'Confirm' }).click();
  await tmPage.getByRole('button', { name: 'I have saved them' }).click();
  await expect(tmPage.getByRole('heading', { name: /^Welcome, / })).toBeVisible();

  // A statement in its grid: the current assets add up as the cells are typed.
  await openMenu(tmPage, 'Financial statements');
  await expect(tmPage.getByRole('heading', { name: 'Financial statements' })).toBeVisible();
  const create = tmPage.locator('form', { hasText: 'New statement' });
  await create.getByLabel(/^Company/).selectOption({ label: 'First Company' });
  await create.getByLabel(/^Period end/).fill('2025-12-31');
  await create.getByLabel(/^Assurance/).selectOption('MANAGEMENT');
  await create.getByRole('button', { name: 'Create' }).click();
  await expect(tmPage.getByRole('heading', { name: 'Statement lines' })).toBeVisible();
  await tmPage.getByLabel('CASH', { exact: true }).fill('120');
  await tmPage.getByLabel('AR', { exact: true }).fill('80');
  await expect(tmPage.getByRole('row', { name: /TOTAL_CA/ })).toContainText('200');
  await tmPage.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(tmPage.getByText('Saved.')).toBeVisible();
  await shot(tmPage, '10-statement-grid');

  // The formula library with its templates, the self-assessments with their disclaimer, and the group compliance.
  await openMenu(tmPage, 'Formula library');
  await expect(tmPage.getByText('CURRENT_RATIO').first()).toBeVisible();
  await openMenu(tmPage, 'Credit self-assessments');
  await expect(tmPage.getByText("not an agency rating")).toBeVisible();
  await shot(tmPage, '11-credit-assessments');
  await openMenu(tmPage, 'Group compliance');
  await expect(tmPage.getByRole('heading', { name: 'Group compliance' })).toBeVisible();
  await tmContext.close();

  // S3 (docs/48): the administrator's dashboards with the manager's view, the inbox and the bank form templates.
  await page.getByRole('link', { name: 'Dashboards', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Dashboards' })).toBeVisible();
  await page.getByLabel(/^View/).selectOption('manager');
  await expect(page.getByRole('heading', { name: 'SLA breaches' })).toBeVisible();
  await expect(page.getByText('No approval waits for you.')).toBeVisible();
  await page.getByRole('link', { name: 'Inbox', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Inbox' })).toBeVisible();
  await openMenu(page, 'Bank form templates');
  await expect(page.getByRole('heading', { name: 'Bank form templates' })).toBeVisible();
  await expect(page.getByText('No bank form template yet.')).toBeVisible();

  // S4 (docs/49): the screens of the proformas and the received letters of credit open. The administrator holds no
  // sales permission, so the menu has no link to them and the server refuses their lists; the full sales path is in the
  // integration tests (ProformaTests, SalesLcTests, SalesFollowUpTests).
  const origin = new URL(page.url()).origin;
  await openGroup(page, 'Treasury requests');
  await expect(page.getByRole('link', { name: 'Proformas', exact: true })).toHaveCount(0);
  await page.goto(`${origin}/sales/proformas`);
  await expect(page.getByRole('heading', { name: 'Proformas' })).toBeVisible();
  await page.goto(`${origin}/sales/lcs`);
  await expect(page.getByRole('heading', { name: /Received letters of credit/ })).toBeVisible();

  // The screens in English (the default) and in Arabic, for docs/59: each page as the administrator sees it.
  if (shots) {
    const pages = [['20-home', '/'], ['21-companies', '/companies'], ['22-banks', '/institutions'], ['23-users', '/users'],
      ['24-roles', '/roles'], ['25-settings', '/settings'], ['26-catalogues', '/catalogs'], ['27-requests', '/requests'],
      ['28-letters-of-credit', '/lcs'], ['29-facilities', '/facilities'], ['30-dashboards', '/dashboards'], ['31-audit', '/audit'],
      ['32-compare-terms', '/terms/compare']] as const;
    for (const [name, path] of pages) {
      await page.goto(`${origin}${path}`);
      await page.getByRole('heading').first().waitFor();
      await shot(page, `en-${name}`);
    }
    for (const [name, path] of pages) {
      await page.goto(`${origin}${path}`);
      await page.getByRole('heading').first().waitFor();
      if (await page.locator('html').getAttribute('lang') !== 'ar') await page.getByRole('button', { name: 'العربية' }).click();
      await shot(page, name);
    }
    await page.getByRole('button', { name: 'English' }).click();

    // The facilities, for docs/59: a facilities officer creates a facility with one bank, two limits and a product line,
    // a treasury manager approves it and the officer records a utilisation. The full paths are in FacilityTests and
    // LimitTests; this runs only for the screenshots.
    // The administrator's sign-in is old by now: a sensitive change asks for a fresh code first.
    const fresh = async (done: ReturnType<Page['getByText']>) => {
      const dialog = page.getByRole('dialog');
      await expect(done.or(dialog)).toBeVisible();
      if (await dialog.isVisible()) {
        await dialog.getByLabel('6-digit code').fill(await admin.next());
        await dialog.getByRole('button', { name: 'Confirm' }).click();
      }
      await expect(done).toBeVisible();
    };
    const invite = async (email: string, nameEn: string, role: string) => {
      await openMenu(page, 'Users');
      await page.getByLabel(/^E-mail/).fill(email);
      await page.getByLabel(/^Name \(English\)/).fill(nameEn);
      await page.getByRole('checkbox', { name: new RegExp(`^${role} · `) }).check();
      await page.getByRole('button', { name: 'Send the invitation' }).click();
      await fresh(page.getByText('The invitation is on its way.'));
      await page.getByRole('link', { name: nameEn }).click();
      await page.getByRole('button', { name: 'Save scope' }).click();
      await fresh(page.getByText('Sees every company.'));
    };
    const signIn = async (email: string) => {
      const context = await browser.newContext();
      const p = await context.newPage();
      await p.goto(await linkSentTo(mailDir, email, '/invitation', 90_000));
      const password = `an e2e passphrase of ${email.slice(0, 2)} staff`;   // a password may not hold the e-mail
      await p.getByLabel(/^New password/).fill(password);
      await p.getByLabel(/^Repeat the password/).fill(password);
      await p.getByRole('button', { name: 'Save password' }).click();
      await p.getByLabel(/^E-mail/).fill(email);
      await p.getByLabel(/^Password/).fill(password);
      await p.getByRole('button', { name: 'Sign in' }).click();
      const auth = new Authenticator(base32Decode(await p.locator('.secret code').innerText()));
      await p.getByLabel('6-digit code').fill(await auth.next());
      await p.getByRole('button', { name: 'Confirm' }).click();
      await p.getByRole('button', { name: 'I have saved them' }).click();
      await expect(p.getByRole('heading', { name: /^Welcome, / })).toBeVisible();
      return { context, p };
    };
    const foEmail = `fo@${code}.test.invalid`, tmEmailFac = `tm@${code}.test.invalid`;
    // The platform reference of a facility takes its lead bank's three-letter code (BR-FAC-030).
    await openMenu(page, 'Banks and lenders');
    await page.getByRole('link', { name: 'BNK1' }).click();
    const ref = page.locator('form', { has: page.locator('input[name="refCode"]') });
    await ref.locator('input[name="refCode"]').fill('BKA');
    await ref.getByRole('button', { name: 'Save' }).click();
    await fresh(page.getByText('Saved.'));
    await invite(foEmail, 'Facilities Officer', 'FO');
    await invite(tmEmailFac, 'Treasury Manager', 'TM');
    const fo = await signIn(foEmail);
    await fo.p.goto(`${origin}/facilities`);
    const form = fo.p.locator('form', { hasText: 'New facility' });
    await form.getByLabel(/^Total/).fill('10000000');
    await form.getByLabel(/^Start date/).fill('2026-01-01');
    await form.getByLabel(/^Expiry date/).fill('2027-12-31');
    await form.getByLabel(/^Bank reference/).fill('CF-2026-001');
    await form.getByRole('button', { name: 'Create' }).click();
    await expect(fo.p).toHaveURL(/\/facilities\/[0-9a-f-]{36}$/);
    const facilityUrl = fo.p.url();
    const lender = fo.p.locator('form', { hasText: 'Add a lender' });
    await lender.getByLabel(/^Bank/).selectOption({ index: 1 });
    await lender.getByLabel(/^Share/).fill('100');
    await lender.getByRole('button', { name: 'Add' }).click();
    await expect(fo.p.getByRole('cell', { name: 'SOLE' }).first()).toBeVisible();
    const limits = fo.p.locator('section.card', { has: fo.p.getByRole('heading', { name: 'Limits' }) });
    await limits.getByRole('button', { name: 'Draft', exact: true }).click();
    const addLimit = async (code: string, type: string, amount: string, parent?: string) => {
      const f = limits.locator('form', { hasText: 'Add a limit' });
      await f.getByLabel(/^Code/).fill(code);
      await f.getByLabel(/^Type/).selectOption(type);
      if (parent) await f.getByLabel(/^Parent/).selectOption({ label: parent });
      await f.getByLabel(/^Amount/).fill(amount);
      await f.getByLabel(/^Source/).fill('Facility offer letter, clause 2');
      await f.getByRole('button', { name: 'Add' }).click();
      await expect(limits.getByText(code, { exact: true }).first()).toBeVisible();
    };
    await addLimit('TOTAL', 'TOTAL_FACILITY', '10000000');
    await addLimit('LC', 'DOCUMENTARY_CREDITS', '6000000', 'TOTAL');
    const line = limits.locator('form', { hasText: 'Add a product line' });
    await line.getByLabel(/^Limit/).selectOption({ label: 'LC' });
    await line.getByLabel(/^Line cap/).fill('6000000');
    await line.getByLabel(/^Source/).fill('Facility offer letter, clause 3');
    await line.getByRole('button', { name: 'Add' }).click();
    await fo.p.getByRole('button', { name: 'Submit for approval' }).click();
    await expect(fo.p.getByRole('button', { name: 'Withdraw' })).toBeVisible();
    const tm = await signIn(tmEmailFac);
    await tm.p.goto(facilityUrl);
    // The facility has no agreement file yet, so the approval acknowledges that warning: wait for the checks to load.
    await tm.p.getByRole('button', { name: /^Approve \(/ }).click();
    await expect(tm.p.getByText('Not approved yet.')).toHaveCount(0, { timeout: 20_000 });
    await tm.context.close();
    await fo.p.goto(facilityUrl);
    const use = fo.p.locator('form', { hasText: 'Record a utilisation' });
    await use.getByLabel(/^Limit/).selectOption({ label: 'LC' });
    await use.getByLabel(/^Reference/).fill('LC-2026-0001');
    await use.getByLabel(/^Amount/).fill('1500000');
    await use.getByRole('button', { name: 'Record' }).click();
    await expect(fo.p.getByText('LC-2026-0001')).toBeVisible();
    const facilityPages = [['40-facilities-list', `${origin}/facilities`], ['41-facility-card', facilityUrl],
      ['43-tariff-schedules', `${origin}/tariff-schedules`], ['44-collateral', `${origin}/collaterals`], ['45-breaches', `${origin}/breaches`]] as const;
    for (const [name, url] of facilityPages) {
      await fo.p.goto(url);
      await fo.p.getByRole('heading').first().waitFor();
      await shot(fo.p, `en-${name}`);
    }
    await fo.p.goto(facilityUrl);
    await fo.p.getByRole('heading').first().waitFor();
    await fo.p.waitForLoadState('networkidle').catch(() => undefined);
    await fo.p.screenshot({ path: `${shots}/en-42-facility-card-full.png`, fullPage: true });
    await fo.p.getByRole('button', { name: 'العربية' }).click();
    for (const [name, url] of facilityPages) {
      await fo.p.goto(url);
      await fo.p.getByRole('heading').first().waitFor();
      await shot(fo.p, name);
    }
    // The whole card of the facility, top to bottom.
    await fo.p.goto(facilityUrl);
    await fo.p.getByRole('heading').first().waitFor();
    await fo.p.waitForLoadState('networkidle').catch(() => undefined);
    await fo.p.screenshot({ path: `${shots}/42-facility-card-full.png`, fullPage: true });
    await fo.context.close();

    // A purchase letter of credit request, for docs/59: a purchasing officer creates it on the screen and enters its terms
    // and documents (through the API the terms screen uses, to keep the journey short). Transhipment is not allowed by
    // sea, so the checks show the UCP 600 warning of articles 19 to 24 (docs/60).
    const rqEmail = `rq@${code}.test.invalid`;
    await invite(rqEmail, 'Purchasing Officer', 'RQ');
    const rq = await signIn(rqEmail);
    await rq.p.goto(`${origin}/requests/new`);
    const newRequest = rq.p.locator('form', { hasText: 'New request' });
    await newRequest.getByLabel(/^Request type/).selectOption('PURCHASE_LC');
    await newRequest.getByLabel(/^Title/).fill('Seamless steel pipes, order 4471');
    await shot(rq.p, 'en-50-request-new');
    await rq.p.getByRole('button', { name: 'العربية' }).click();
    await shot(rq.p, '50-request-new');
    await rq.p.getByRole('button', { name: 'English' }).click();
    await newRequest.getByRole('button', { name: 'Create the draft' }).click();
    await expect(rq.p).toHaveURL(/\/requests\/[0-9a-f-]{36}$/);
    const requestUrl = rq.p.url();
    const requestId = requestUrl.split('/').pop()!;
    const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
    const failed = await rq.p.evaluate(async ({ id, terms }) => {
      const { token } = await (await fetch('/api/v1/csrf')).json() as { token: string };
      const call = async (method: string, path: string, body: unknown) => {
        const r = await fetch(`/api/v1${path}`, { method, body: JSON.stringify(body), headers: {
          'Content-Type': 'application/json', 'X-CSRF-Token': token, 'Idempotency-Key': crypto.randomUUID() } });
        if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${await r.text()}`);
        return r.status === 204 ? null : await r.json();
      };
      try {
        const supplier = await call('POST', '/counterparties', { kind: 'SUPPLIER', nameEn: 'Steel Pipes Ltd', country: 'CN', erpCode: 'V-1001' }) as { id: string };
        await call('PUT', `/requests/${id}/terms`, { fields: { ...terms, beneficiary: supplier.id } });
        await call('PUT', `/requests/${id}/terms/documents`, [
          { clause: 'COMMERCIAL_INVOICE', originals: 3, copies: 2 }, { clause: 'BL_SEA', originals: 3, copies: 3 }, { clause: 'PACKING_LIST', originals: 1, copies: 2 }]);
        return '';
      } catch (e) { return String(e); }
    }, { id: requestId, terms: {
      lcType: 'SIGHT', availableWith: 'ADVISING_BANK', confirmation: 'WITHOUT', advisingBankName: 'Advising Bank', advisingBankAddress: 'Shanghai',
      advisingBankBic: 'ADVBCNSH', currencyId: 'SAR', amount: 1_500_000, toleranceMode: 'PLUS_MINUS', tolerancePlusPct: 5, toleranceMinusPct: 5,
      expiryRule: 'ABSOLUTE', expiryDate: day(150), expiryPlace: 'Riyadh', latestShipmentRule: 'ABSOLUTE', latestShipmentDate: day(120),
      presentationDays: 21, presentationBasis: 'SHIPMENT_DATE', partialShipments: 'ALLOWED', transhipment: 'NOT_ALLOWED', transportMode: 'SEA',
      portOfLoading: 'Shanghai', portOfDischarge: 'Dammam', incotermId: 'CFR', incotermPlace: 'Dammam', goodsCategory: 'STEEL_PIPES',
      goodsDescription: 'Seamless steel pipes as per proforma', insuranceResponsibility: 'APPLICANT', lcTextLanguage: 'EN' } });
    expect(failed).toBe('');
    // English is the default (docs/31 row 69): the terms and their print in English first, then in Arabic.
    await rq.p.goto(`${requestUrl}/terms`);
    await rq.p.getByRole('heading').first().waitFor();
    await rq.p.screenshot({ path: `${shots}/56-terms-en-full.png`, fullPage: true });
    await shot(rq.p, 'en-52-terms');
    await rq.p.goto(`${origin}/api/v1/requests/${requestId}/terms/print?lang=en`);
    await shot(rq.p, '57-terms-print-en');
    await rq.p.goto(requestUrl);
    await rq.p.getByRole('heading').first().waitFor();
    await shot(rq.p, 'en-51-request-card');
    await rq.p.getByRole('button', { name: 'العربية' }).click();
    await rq.p.goto(requestUrl);
    await rq.p.getByRole('heading').first().waitFor();
    await shot(rq.p, '51-request-card');
    await rq.p.goto(`${requestUrl}/terms`);
    await rq.p.getByRole('heading').first().waitFor();
    await shot(rq.p, '52-terms');
    await rq.p.screenshot({ path: `${shots}/53-terms-full.png`, fullPage: true });
    await rq.p.goto(`${origin}/api/v1/requests/${requestId}/terms/print?lang=ar`);
    await shot(rq.p, '54-terms-print');
    await rq.p.screenshot({ path: `${shots}/55-terms-print-full.png`, fullPage: true });
    await rq.context.close();
  }
});
