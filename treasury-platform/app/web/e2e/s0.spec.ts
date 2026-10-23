// The S0 exit path (AC-PLT-5) in a browser: the operator sets up from the deployment's link and signs in with TOTP,
// creates a tenant with a fresh code, the worker invites its first administrator, who sets a password, scans the QR
// code, keeps the recovery codes and reaches the portal; the portal then switches to Arabic, right to left. Then the
// S1 exit path (AC-INS-1): the administrator adds a company and onboards a bank with the set-up wizard, whose review
// warns of the products without a default contact before anything is created. Then S2-b (docs/47 §4): the administrator
// invites a financial analyst, who signs in, enters a statement in the grid and sees its totals live, and opens the formula
// library, the credit self-assessments and the group compliance. Then S3 (docs/48): the dashboards, the inbox and the
// bank form templates.
import { expect, test } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { Authenticator, base32Decode, linkSentTo } from './helpers';

const mailDir = process.env.E2E_MAIL_DIR ?? '';
const setupLink = process.env.E2E_SETUP_LINK ?? '';
const port = process.env.E2E_PORT ?? '8443';
const operatorEmail = process.env.E2E_OPERATOR_EMAIL ?? 'e2e-operator@test.invalid';
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
  await page.getByRole('link', { name: 'Companies', exact: true }).click();
  await page.getByLabel(/^Company code/).fill('C1');
  await page.getByLabel(/^Name \(Arabic\)/).fill('الشركة الأولى');
  await page.getByLabel(/^Name \(English\)/).fill('First Company');
  await page.getByLabel(/^Country/).fill('SA');
  await page.getByLabel(/^Fiscal year ends in month/).fill('12');
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('heading', { name: /First Company|الشركة الأولى/ })).toBeVisible();

  await page.getByRole('link', { name: 'Banks and lenders' }).click();
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
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('heading', { name: /BNK1/ })).toBeVisible();
  await expect(page.getByRole('link', { name: /First Company|الشركة الأولى/ })).toBeVisible();

  // S1-b: the ownership tab of the company and the governance conflicts report (R-ACC-04).
  await page.getByRole('link', { name: 'Companies', exact: true }).click();
  await page.getByRole('link', { name: 'C1' }).click();
  await page.getByRole('tab', { name: 'Ownership' }).click();
  await expect(page.getByText(/Direct holdings total/)).toBeVisible();
  await page.getByRole('link', { name: 'Governance conflicts' }).click();
  await expect(page.getByRole('heading', { name: 'Governance conflicts' })).toBeVisible();

  // S2: the comparison of a comparable term across facilities (SCR-CMP-01); the keys come from CMP.TERMS.
  await page.getByRole('link', { name: 'Compare terms' }).click();
  await expect(page.getByRole('heading', { name: 'Compare terms' })).toBeVisible();
  await page.getByLabel(/^Key/).selectOption({ value: 'PRC.ARRANGEMENT_FEE_PCT' });
  await expect(page.getByText('Lower is better')).toBeVisible();   // no facility yet: the direction, and nothing ranked
  await expect(page.getByText('Nothing here yet.')).toBeVisible();
  // S2-b: a financial analyst (FA enters statements and assessments; TM only approves them), given every company.
  const tmEmail = `fa@${code}.test.invalid`;
  await page.getByRole('link', { name: 'Users', exact: true }).click();
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
  await tmPage.getByRole('link', { name: 'Financial statements' }).click();
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

  // The formula library with its templates, the self-assessments with their disclaimer, and the group compliance.
  await tmPage.getByRole('link', { name: 'Formula library' }).click();
  await expect(tmPage.getByText('CURRENT_RATIO').first()).toBeVisible();
  await tmPage.getByRole('link', { name: 'Credit self-assessments' }).click();
  await expect(tmPage.getByText("not an agency rating")).toBeVisible();
  await tmPage.getByRole('link', { name: 'Group compliance' }).click();
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
  await page.getByRole('link', { name: 'Bank form templates', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Bank form templates' })).toBeVisible();
  await expect(page.getByText('No bank form template yet.')).toBeVisible();
});
