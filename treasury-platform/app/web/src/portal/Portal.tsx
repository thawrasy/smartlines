import { createContext, lazy, Suspense, useContext, useEffect, useState, type ComponentType } from 'react';
import { Navigate, NavLink, Route, Routes, useNavigate } from 'react-router-dom';
import { api } from '../api';
import { LangSwitch, useI18n } from '../i18n';
import { IdleGuard, StepUpProvider } from '../ui';

const keepAlive = () => api('GET', '/me');
import { Enrol, ForgotPassword, Invitation, Login, Mfa, ResetPassword, type Tenant, CompanyEntry, FirstPassword, entryHost } from './Auth';
import { Bell, Notifications, NotificationSettings } from './Notifications';


// Each screen module is its own chunk, fetched when its route opens; sign-in and the top bar stay in the first one.
function lazyNamed<M, K extends keyof M>(load: () => Promise<M>, name: K) {
  return lazy(async () => ({ default: (await load())[name] as unknown as ComponentType<object> }));
}
const loadAdmin = () => import('./Admin');
const Audit = lazyNamed(loadAdmin, 'Audit');
const Calendar = lazyNamed(loadAdmin, 'Calendar');
const DataExports = lazyNamed(loadAdmin, 'DataExports');
const Jobs = lazyNamed(loadAdmin, 'Jobs');
const Numbering = lazyNamed(loadAdmin, 'Numbering');
const Settings = lazyNamed(loadAdmin, 'Settings');
const Support = lazyNamed(loadAdmin, 'Support');
const loadBanks = () => import('./Banks');
const Accounts = lazyNamed(loadBanks, 'Accounts');
const BankSetup = lazyNamed(loadBanks, 'BankSetup');
const BaseRates = lazyNamed(loadBanks, 'BaseRates');
const InstitutionDetail = lazyNamed(loadBanks, 'InstitutionDetail');
const Institutions = lazyNamed(loadBanks, 'Institutions');
const RelationshipDetail = lazyNamed(loadBanks, 'RelationshipDetail');
const loadCatalogs = () => import('./Catalogs');
const Catalogs = lazyNamed(loadCatalogs, 'Catalogs');
const loadFacilities = () => import('./Facilities');
const Facilities = lazyNamed(loadFacilities, 'Facilities');
const FacilityDetail = lazyNamed(loadFacilities, 'FacilityDetail');
const loadCollateral = () => import('./Collateral');
const CollateralDetail = lazyNamed(loadCollateral, 'CollateralDetail');
const Collaterals = lazyNamed(loadCollateral, 'Collaterals');
const loadObligations = () => import('./Obligations');
const Breaches = lazyNamed(loadObligations, 'Breaches');
const loadPricing = () => import('./Pricing');
const TariffSchedules = lazyNamed(loadPricing, 'TariffSchedules');
const loadTerms = () => import('./Terms');
const TermCompare = lazyNamed(loadTerms, 'TermCompare');
const loadStatements = () => import('./Statements');
const StatementDetail = lazyNamed(loadStatements, 'StatementDetail');
const Statements = lazyNamed(loadStatements, 'Statements');
const loadMonthlyFigures = () => import('./MonthlyFigures');
const MonthlyFigures = lazyNamed(loadMonthlyFigures, 'MonthlyFigures');
const loadFormulas = () => import('./Formulas');
const Formulas = lazyNamed(loadFormulas, 'Formulas');
const loadCompliance = () => import('./Compliance');
const GroupCompliance = lazyNamed(loadCompliance, 'GroupCompliance');
const loadCovenantTests = () => import('./CovenantTests');
const StatementBreaches = lazyNamed(loadCovenantTests, 'StatementBreaches');
const loadCredit = () => import('./Credit');
const AssessmentDetail = lazyNamed(loadCredit, 'AssessmentDetail');
const Assessments = lazyNamed(loadCredit, 'Assessments');
const PresentationVersions = lazyNamed(loadCredit, 'PresentationVersions');
const loadCreditInputs = () => import('./CreditInputs');
const ProductLines = lazyNamed(loadCreditInputs, 'ProductLines');
const loadReadiness = () => import('./Readiness');
const LenderRatings = lazyNamed(loadReadiness, 'LenderRatings');
const Provision = lazyNamed(loadReadiness, 'Provision');
const ReadinessFile = lazyNamed(loadReadiness, 'ReadinessFile');
const loadRequests = () => import('./Requests');
const NewRequest = lazyNamed(loadRequests, 'NewRequest');
const RequestDetail = lazyNamed(loadRequests, 'RequestDetail');
const RequestList = lazyNamed(loadRequests, 'RequestList');
const loadInbox = () => import('./Inbox');
const Delegations = lazyNamed(loadInbox, 'Delegations');
const Inbox = lazyNamed(loadInbox, 'Inbox');
const loadLcs = () => import('./Lcs');
const LcCard = lazyNamed(loadLcs, 'LcCard');
const LcRegister = lazyNamed(loadLcs, 'LcRegister');
const loadDashboards = () => import('./Dashboards');
const Dashboards = lazyNamed(loadDashboards, 'Dashboards');
const loadFormTemplates = () => import('./FormTemplates');
const FormTemplateDetail = lazyNamed(loadFormTemplates, 'FormTemplateDetail');
const FormTemplates = lazyNamed(loadFormTemplates, 'FormTemplates');
const loadReports = () => import('./Reports');
const Reports = lazyNamed(loadReports, 'Reports');
const loadSales = () => import('./Sales');
const ProformaCard = lazyNamed(loadSales, 'ProformaCard');
const ProformaEditor = lazyNamed(loadSales, 'ProformaEditor');
const ProformaRegister = lazyNamed(loadSales, 'ProformaRegister');
const SalesLcCard = lazyNamed(loadSales, 'SalesLcCard');
const SalesLcNew = lazyNamed(loadSales, 'SalesLcNew');
const SalesLcRegister = lazyNamed(loadSales, 'SalesLcRegister');
const loadTermsEditor = () => import('./TermsEditor');
const TermsEditor = lazyNamed(loadTermsEditor, 'TermsEditor');
const loadCompanies = () => import('./Companies');
const Companies = lazyNamed(loadCompanies, 'Companies');
const CompanyDetail = lazyNamed(loadCompanies, 'CompanyDetail');
const Departments = lazyNamed(loadCompanies, 'Departments');
const DocumentRegister = lazyNamed(loadCompanies, 'DocumentRegister');
const loadStructure = () => import('./Structure');
const OwnershipMismatch = lazyNamed(loadStructure, 'OwnershipMismatch');
const StructureIntegrity = lazyNamed(loadStructure, 'StructureIntegrity');
const loadSignatories = () => import('./Signatories');
const AuthorityConflicts = lazyNamed(loadSignatories, 'AuthorityConflicts');
const loadParties = () => import('./Parties');
const CustomFieldDefinitions = lazyNamed(loadParties, 'CustomFieldDefinitions');
const Parties = lazyNamed(loadParties, 'Parties');
const PartyDetail = lazyNamed(loadParties, 'PartyDetail');
const PartyDuplicates = lazyNamed(loadParties, 'PartyDuplicates');
const loadProfile = () => import('./Profile');
const Profile = lazyNamed(loadProfile, 'Profile');
const loadRoles = () => import('./Roles');
const RoleDetail = lazyNamed(loadRoles, 'RoleDetail');
const Roles = lazyNamed(loadRoles, 'Roles');
const loadUsers = () => import('./Users');
const UserDetail = lazyNamed(loadUsers, 'UserDetail');
const Users = lazyNamed(loadUsers, 'Users');

export interface Me {
  user: {
    id: string; email: string; displayNameEn?: string; displayNameAr?: string; preferredLanguage?: string; tenantNameEn: string; tenantNameAr: string;
    tenantStatus: string; tenantCode: string; mfaEnabled?: boolean; mfaRequired?: boolean; employeeCode?: string; mobile?: string; productScopeMode?: string;
  };
  permissions: string[]; modules: string[]; sessionIdleMinutes?: number;
}

const MeCtx = createContext<Me | null>(null);
export const useMe = () => useContext(MeCtx)!;
export const can = (me: Me, p: string) => me.permissions.includes(p);

// The menu shows an item when the user holds its permission (DOC-B07 section 2); hiding it never replaces the API's 403.
const menu: { to: string; label: string; permission?: string; anyOf?: string[] }[] = [
  { to: '/', label: 'Home' },
  { to: '/users', label: 'Users', permission: 'sec.user.manage' },
  { to: '/roles', label: 'Roles', permission: 'sec.role.manage' },
  { to: '/settings', label: 'Settings', permission: 'cfg.settings.manage' },
  { to: '/support', label: 'Support access', permission: 'sec.support.grant' },
  { to: '/numbering', label: 'Numbering', permission: 'cfg.numbering.manage' },
  { to: '/calendar', label: 'Non-working days', permission: 'cfg.settings.manage' },
  { to: '/audit', label: 'Audit log', anyOf: ['audit.view', 'audit.view.treasury'] },
  { to: '/jobs', label: 'Background jobs', permission: 'cfg.jobs.view' },
  { to: '/data-exports', label: 'Data export', permission: 'cfg.export.request' },
  { to: '/companies', label: 'Companies', permission: 'org.company.view' },
  { to: '/documents', label: 'Company documents', permission: 'org.document.view' },
  { to: '/reports/ownership-mismatch', label: 'Ownership check', permission: 'org.ownership.manage' },
  { to: '/reports/structure-integrity', label: 'Structure integrity', permission: 'org.body.manage' },
  { to: '/authority-conflicts', label: 'Governance conflicts', permission: 'sig.view' },
  { to: '/departments', label: 'Departments', permission: 'org.company.manage' },
  { to: '/parties', label: 'Persons and entities', permission: 'party.view' },
  { to: '/parties/duplicates', label: 'Possible duplicates', permission: 'party.merge' },
  { to: '/custom-fields', label: 'Custom fields', permission: 'party.field.manage' },
  { to: '/institutions', label: 'Banks and lenders', permission: 'ins.view' },
  { to: '/accounts', label: 'Bank accounts', permission: 'acc.view' },
  { to: '/base-rates', label: 'Base rates', permission: 'cat.view' },
  { to: '/dashboards', label: 'Dashboards', anyOf: ['req.view.own', 'req.claim', 'req.execute', 'req.dashboard.manager'] },
  { to: '/inbox', label: 'Inbox', anyOf: ['req.view.own', 'req.view.all', 'req.approve', 'req.claim'] },
  { to: '/requests', label: 'Requests', anyOf: ['req.view.own', 'req.view.all'] },
  { to: '/lcs', label: 'Letters of credit', anyOf: ['lc.view.all', 'lc.view.own'] },
  { to: '/sales/proformas', label: 'Proformas', anyOf: ['lc.view.all', 'lc.view.own'] },
  { to: '/sales/lcs', label: 'Received letters of credit', permission: 'lc.export.view' },
  { to: '/reports', label: 'Reports', permission: 'lc.report.view' },
  { to: '/lc-form-templates', label: 'Bank form templates', anyOf: ['lc.print', 'lc.template.manage'] },
  { to: '/delegations', label: 'Delegations', anyOf: ['req.delegate.own', 'req.delegate.manage'] },
  { to: '/facilities', label: 'Facilities', permission: 'fac.view' },
  { to: '/tariff-schedules', label: 'Tariff schedules', permission: 'prc.view' },
  { to: '/collaterals', label: 'Collateral', permission: 'col.view' },
  { to: '/breaches', label: 'Breaches', permission: 'obl.view' },
  { to: '/terms/compare', label: 'Compare terms', permission: 'cmp.view' },
  { to: '/financial-statements', label: 'Financial statements', anyOf: ['fin.stmt.enter', 'fin.stmt.approve', 'fin.verify.run', 'fin.credit.assess'] },
  { to: '/monthly-figures', label: 'Monthly balances', permission: 'fin.view' },
  { to: '/formulas', label: 'Formula library', permission: 'fin.view' },
  { to: '/assessments', label: 'Credit self-assessments', anyOf: ['fin.credit.assess', 'fin.credit.approve', 'fin.credit.endorse'] },
  { to: '/product-lines', label: 'Product lines', anyOf: ['fin.credit.assess', 'fin.credit.approve', 'fin.credit.endorse'] },
  { to: '/lender-ratings', label: 'Lender ratings', anyOf: ['fin.credit.assess', 'fin.credit.approve', 'fin.credit.endorse'] },
  { to: '/provision', label: 'Provision matrix', anyOf: ['fin.formula.manage', 'fin.formula.approve', 'fin.credit.assess'] },
  { to: '/presentation-versions', label: 'Presentation versions', anyOf: ['fin.stmt.enter', 'fin.stmt.approve'] },
  { to: '/reports/compliance', label: 'Group compliance', permission: 'obl.view' },
  { to: '/reports/statement-breaches', label: 'Breaches found on the statements', anyOf: ['fin.stmt.enter', 'fin.stmt.approve', 'fin.verify.run', 'fin.credit.assess'] },
  { to: '/catalogs', label: 'Catalogues', anyOf: ['cat.manage.general', 'cat.manage.financial'] },
  { to: '/notifications', label: 'Notifications', permission: 'ntf.prefs' },
  { to: '/notification-settings', label: 'Notification settings', permission: 'ntf.manage' },
  { to: '/profile', label: 'My profile' },
];

function Shell() {
  const nav = useNavigate();
  const { t, lang, setLang } = useI18n();
  const [me, setMe] = useState<Me | null>(null);
  useEffect(() => {
    api<Me>('GET', '/me').then(m => {
      setMe(m);
      if (m.user.preferredLanguage === 'ar' || m.user.preferredLanguage === 'en') setLang(m.user.preferredLanguage);
    }).catch(() => nav('/login'));
  }, [nav, setLang]);
  if (!me) return null;
  const signOutIdle = () => { void api('POST', '/auth/logout', {}).catch(() => undefined).finally(() => nav('/login?ended=idle')); };
  const items = menu.filter(m => (!m.permission || can(me, m.permission)) && (!m.anyOf || m.anyOf.some(p => can(me, p))));
  return (
    <MeCtx.Provider value={me}>
      <StepUpProvider password={!me.user.mfaEnabled}>
        <div className="shell">
          <IdleGuard minutes={me.sessionIdleMinutes ?? 30} keepAlive={keepAlive} onExpire={signOutIdle} />
          <header className="top">
            <strong>{lang === 'ar' ? me.user.tenantNameAr : me.user.tenantNameEn}</strong>
            <span className="grow" />
            {can(me, 'ntf.prefs') && <Bell />}
            <span className="muted">{me.user.email}</span>
            <LangSwitch />
            <button className="link" onClick={async () => { await api('POST', '/auth/logout', {}); nav('/login'); }}>{t('Sign out')}</button>
          </header>
          {me.user.tenantStatus !== 'ACTIVE' && me.user.tenantStatus !== 'TRIAL' && (
            <p className="banner">{t('The account is {s}: you can read and export, not change.', { s: t(me.user.tenantStatus) })}</p>
          )}
          <nav className="side">{items.map(m => <NavLink key={m.to} to={m.to} end>{t(m.label)}</NavLink>)}</nav>
          <main className="content">
            <Suspense fallback={<p className="muted">{t('Loading…')}</p>}>
            <Routes>
              <Route path="/" element={<Home />} />
              <Route path="/users" element={<Users />} />
              <Route path="/users/:id" element={<UserDetail />} />
              <Route path="/roles" element={<Roles />} />
              <Route path="/roles/:id" element={<RoleDetail />} />
              <Route path="/settings" element={<Settings />} />
              <Route path="/support" element={<Support />} />
              <Route path="/numbering" element={<Numbering />} />
              <Route path="/calendar" element={<Calendar />} />
              <Route path="/audit" element={<Audit />} />
              <Route path="/jobs" element={<Jobs />} />
              <Route path="/data-exports" element={<DataExports />} />
              <Route path="/catalogs" element={<Catalogs />} />
              <Route path="/companies" element={<Companies />} />
              <Route path="/companies/:id" element={<CompanyDetail />} />
              <Route path="/documents" element={<DocumentRegister />} />
              <Route path="/reports/ownership-mismatch" element={<OwnershipMismatch />} />
              <Route path="/reports/structure-integrity" element={<StructureIntegrity />} />
              <Route path="/authority-conflicts" element={<AuthorityConflicts />} />
              <Route path="/departments" element={<Departments />} />
              <Route path="/parties" element={<Parties />} />
              <Route path="/parties/duplicates" element={<PartyDuplicates />} />
              <Route path="/parties/:id" element={<PartyDetail />} />
              <Route path="/custom-fields" element={<CustomFieldDefinitions />} />
              <Route path="/institutions" element={<Institutions />} />
              <Route path="/institutions/:id" element={<InstitutionDetail />} />
              <Route path="/relationships/:id" element={<RelationshipDetail />} />
              <Route path="/bank-setup" element={<BankSetup />} />
              <Route path="/accounts" element={<Accounts />} />
              <Route path="/base-rates" element={<BaseRates />} />
              <Route path="/facilities" element={<Facilities />} />
              <Route path="/facilities/:id" element={<FacilityDetail />} />
              <Route path="/tariff-schedules" element={<TariffSchedules />} />
              <Route path="/collaterals" element={<Collaterals />} />
              <Route path="/collaterals/:id" element={<CollateralDetail />} />
              <Route path="/breaches" element={<Breaches />} />
              <Route path="/terms/compare" element={<TermCompare />} />
              <Route path="/financial-statements" element={<Statements />} />
              <Route path="/financial-statements/:id" element={<StatementDetail />} />
              <Route path="/monthly-figures" element={<MonthlyFigures />} />
              <Route path="/formulas" element={<Formulas />} />
              <Route path="/reports/statement-breaches" element={<StatementBreaches />} />
              <Route path="/reports/compliance" element={<GroupCompliance />} />
              <Route path="/assessments" element={<Assessments />} />
              <Route path="/assessments/:id" element={<AssessmentDetail />} />
              <Route path="/presentation-versions" element={<PresentationVersions />} />
              <Route path="/assessments/:id/readiness" element={<ReadinessFile />} />
              <Route path="/lender-ratings" element={<LenderRatings />} />
              <Route path="/inbox" element={<Inbox />} />
              <Route path="/dashboards" element={<Dashboards />} />
              <Route path="/delegations" element={<Delegations />} />
              <Route path="/lcs" element={<LcRegister />} />
              <Route path="/lcs/:id" element={<LcCard />} />
              <Route path="/lc-form-templates" element={<FormTemplates />} />
              <Route path="/lc-form-templates/:id" element={<FormTemplateDetail />} />
              <Route path="/requests" element={<RequestList />} />
              <Route path="/requests/new" element={<NewRequest />} />
              <Route path="/requests/:id" element={<RequestDetail />} />
              <Route path="/requests/:id/terms" element={<TermsEditor />} />
              <Route path="/requests/:id/proforma" element={<ProformaEditor />} />
              <Route path="/sales/proformas" element={<ProformaRegister />} />
              <Route path="/sales/proformas/:id" element={<ProformaCard />} />
              <Route path="/sales/lcs" element={<SalesLcRegister />} />
              <Route path="/sales/lcs/new" element={<SalesLcNew />} />
              <Route path="/sales/lcs/:id" element={<SalesLcCard />} />
              <Route path="/reports" element={<Reports />} />
              <Route path="/product-lines" element={<ProductLines />} />
              <Route path="/provision" element={<Provision />} />
              <Route path="/notifications" element={<Notifications />} />
              <Route path="/notification-settings" element={<NotificationSettings />} />
              <Route path="/profile" element={<Profile />} />
              <Route path="*" element={<Navigate to="/" />} />
            </Routes>
            </Suspense>
          </main>
        </div>
      </StepUpProvider>
    </MeCtx.Provider>
  );
}

// SCR-PLT-06: the first steps, from what the account holds
function Home() {
  const me = useMe();
  const { t, lang } = useI18n();
  const [users, setUsers] = useState<number | null>(null);
  useEffect(() => {
    if (can(me, 'sec.user.manage')) api<{ items: unknown[] }>('GET', '/users?limit=200').then(r => setUsers(r.items.length)).catch(() => setUsers(null));
  }, [me]);
  return (
    <section className="card">
      <h1>{t('Welcome, {name}', { name: (lang === 'ar' ? me.user.displayNameAr : me.user.displayNameEn) ?? me.user.email })}</h1>
      <p>{t('Account status')}: <strong>{t(me.user.tenantStatus)}</strong></p>
      {can(me, 'sec.user.manage') && (
        <ul className="checklist">
          <li className={users !== null && users > 1 ? 'done' : ''}>{t('Invite your team')}</li>
          <li>{t('Review the roles and their permissions')}</li>
          <li>{t('Check the security settings')}</li>
        </ul>
      )}
      <p className="muted">{t('Modules')}: {me.modules.join(' · ')}</p>
    </section>
  );
}

export function Portal() {
  const { t } = useI18n();
  const [tenant, setTenant] = useState<Tenant | null | undefined>(undefined);
  useEffect(() => { api<Tenant>('GET', '/tenant').then(setTenant).catch(() => setTenant(null)); }, []);
  if (tenant === undefined) return null;
  if (tenant === null) return entryHost() ? <CompanyEntry /> : <section className="card neutral"><h1>BankFas</h1><p>{t('This address is not available.')}</p></section>;
  return (
    <Routes>
      <Route path="/login" element={<Login tenant={tenant} />} />
      <Route path="/mfa" element={<Mfa tenant={tenant} />} />
      <Route path="/mfa/enrol" element={<Enrol tenant={tenant} />} />
      <Route path="/first-password" element={<FirstPassword tenant={tenant} />} />
      <Route path="/invitation" element={<Invitation tenant={tenant} />} />
      <Route path="/forgot-password" element={<ForgotPassword tenant={tenant} />} />
      <Route path="/reset-password" element={<ResetPassword tenant={tenant} />} />
      <Route path="/*" element={<Shell />} />
    </Routes>
  );
}
