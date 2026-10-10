import { lazy, Suspense, type ComponentType, type ReactNode } from "react";
import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from "react-router-dom";
import type { Portal } from "./api";
import { useAuth } from "./auth";
import { useI18n } from "./i18n";
import { PortalShell, PublicLayout } from "./components/layout";
import { Empty, Spinner } from "./components/ui";
import Home from "./pages/passenger/Home";
import Results from "./pages/passenger/Results";
import Book from "./pages/passenger/Book";
import Booking from "./pages/passenger/Booking";
import MyTrips from "./pages/passenger/MyTrips";
import Wallet from "./pages/passenger/Wallet";
import Family from "./pages/passenger/Family";
import Support from "./pages/passenger/Support";
import Login from "./pages/auth/Login";
import Register from "./pages/auth/Register";
import Mfa from "./pages/auth/Mfa";
import Verify from "./pages/Verify";
import Track from "./pages/Track";
import { AccountPage, AdminPrivacy } from "./pages/account/Account";
import { ModulePage } from "./modules/ModulePage";
import { ServicesPage } from "./modules/ServicesPage";
import { useModules } from "./modules/context";
import { useLabels } from "./modules/labels";
import type { NavItem } from "./components/layout";
import { TestGateway } from "./pages/passenger/Wallet";
import type { IconName } from "./components/icons";

// The staff portals load when first opened, so a passenger's first visit downloads only the passenger screens
// (review of 1.47.0, R-56). Each module file becomes one chunk.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lazyNamed<M extends Record<string, unknown>>(load: () => Promise<M>, name: keyof M & string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return lazy(() => load().then((m) => ({ default: m[name] as ComponentType<any> })));
}
const CarrierCrew = lazyNamed(() => import("./pages/carrier/Carrier"), "CarrierCrew");
const CarrierDashboard = lazyNamed(() => import("./pages/carrier/Carrier"), "CarrierDashboard");
const CarrierRoutes = lazyNamed(() => import("./pages/carrier/Carrier"), "CarrierRoutes");
const CarrierTrips = lazyNamed(() => import("./pages/carrier/Carrier"), "CarrierTrips");
const CarrierVehicles = lazyNamed(() => import("./pages/carrier/Carrier"), "CarrierVehicles");
const CarrierLayouts = lazyNamed(() => import("./pages/carrier/Layouts"), "CarrierLayouts");
const CounterDashboard = lazyNamed(() => import("./pages/carrier/Counter"), "CounterDashboard");
const CounterReport = lazyNamed(() => import("./pages/carrier/Counter"), "CounterReport");
const CounterSell = lazyNamed(() => import("./pages/carrier/Counter"), "CounterSell");
const AdminFinance = lazyNamed(() => import("./pages/finance/Finance"), "AdminFinance");
const CompanyFinance = lazyNamed(() => import("./pages/finance/Finance"), "CompanyFinance");
const AdminDocuments = lazyNamed(() => import("./pages/documents/Documents"), "AdminDocuments");
const CompanyDocuments = lazyNamed(() => import("./pages/documents/Documents"), "CompanyDocuments");
const DriverLayout = lazyNamed(() => import("./pages/driver/Driver"), "DriverLayout");
const DriverTrip = lazyNamed(() => import("./pages/driver/Driver"), "DriverTrip");
const DriverTrips = lazyNamed(() => import("./pages/driver/Driver"), "DriverTrips");
const AdminAgencies = lazyNamed(() => import("./pages/admin/Admin"), "AdminAgencies");
const AdminCompanies = lazyNamed(() => import("./pages/admin/Admin"), "AdminCompanies");
const AdminOverview = lazyNamed(() => import("./pages/admin/Admin"), "AdminOverview");
const AdminStations = lazyNamed(() => import("./pages/admin/Admin"), "AdminStations");
const AgencyBookings = lazyNamed(() => import("./pages/agency/Agency"), "AgencyBookings");
const AgencyDashboard = lazyNamed(() => import("./pages/agency/Agency"), "AgencyDashboard");
const AgencySell = lazyNamed(() => import("./pages/agency/Agency"), "AgencySell");
const AgencyStaff = lazyNamed(() => import("./pages/agency/Agency"), "AgencyStaff");
const AgencyStatement = lazyNamed(() => import("./pages/agency/Agency"), "AgencyStatement");
const SecurityActivity = lazyNamed(() => import("./pages/security/Security"), "SecurityActivity");
const SecurityAuthLog = lazyNamed(() => import("./pages/security/Security"), "SecurityAuthLog");
const SecurityOverview = lazyNamed(() => import("./pages/security/Security"), "SecurityOverview");
const SecurityRules = lazyNamed(() => import("./pages/security/Security"), "SecurityRules");
const AdminModules = lazyNamed(() => import("./modules/AdminModules"), "AdminModules");
const ReportsPage = lazyNamed(() => import("./pages/reports/Reports"), "ReportsPage");
const AgencyTopup = lazyNamed(() => import("./pages/finance/Payments"), "AgencyTopup");
const PaymentsDesk = lazyNamed(() => import("./pages/finance/Payments"), "PaymentsDesk");
const IntegrationsPage = lazyNamed(() => import("./pages/integrations/Integrations"), "IntegrationsPage");
const MfaPolicy = lazy(() => import("./pages/security/MfaPolicy"));
const Statements = lazy(() => import("./pages/security/Statements"));
const Parcels = lazy(() => import("./pages/passenger/Parcels"));
const CarrierParcels = lazy(() => import("./pages/carrier/Parcels"));
const Regulator = lazy(() => import("./pages/regulator/Regulator"));

/** Menu entries for the switched-on modules the signed-in user can open. */
function useModuleNav(base: string): NavItem[] {
  const { modules } = useModules();
  const L = useLabels();
  return modules.filter((m) => m.resources.length > 0)
    .map((m) => ({ to: `${base}/m/${m.key}`, icon: m.icon as IconName, label: L.module(m.key) }));
}

// Guards only shape the interface; every permission is enforced again by the API and the database.
function RequirePortal({ portal, children }: { portal: Portal; children: ReactNode }) {
  const { me, ready } = useAuth();
  const loc = useLocation();
  if (!ready) return <Spinner />;
  if (!me || me.portal !== portal) return <Navigate to={`/login?portal=${portal}&next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />;
  return <>{children}</>;
}

function RequireUser({ children }: { children: ReactNode }) {
  const { me, ready } = useAuth();
  const loc = useLocation();
  if (!ready) return <Spinner />;
  if (!me) return <Navigate to={`/login?next=${encodeURIComponent(loc.pathname)}`} replace />;
  return <>{children}</>;
}

function PlatformShell() {
  const { t } = useI18n();
  const { can } = useAuth();
  const mods = useModuleNav("/admin");
  return (
    <PortalShell title={t("nav.portals")} items={[
      { to: "/admin", end: true, icon: "dashboard", label: t("admin.overview"), show: can("company.approve", "station.approve") },
      { to: "/admin/companies", icon: "apartment", label: t("admin.companies"), show: can("company.approve") },
      { to: "/admin/documents", icon: "fact_check", label: t("documents.review"), show: can("company.approve") },
      { to: "/admin/agencies", icon: "store", label: t("admin.agencies"), show: can("company.approve", "cash.remittance") },
      { to: "/admin/finance", icon: "payments", label: t("finance.desk"), show: can("withdrawal.approve", "payout.run") },
      { to: "/admin/stations", icon: "location_on", label: t("admin.stations"), show: can("station.approve") },
      { to: "/security", end: true, icon: "shield", label: t("security.title"), show: can("audit.view", "security.ip_rules") },
      { to: "/security/rules", icon: "block", label: t("security.rules"), show: can("security.ip_rules") },
      { to: "/security/auth", icon: "lock", label: t("security.authEvents"), show: can("audit.view", "security.ip_rules") },
      { to: "/security/activity", icon: "history", label: t("security.activity"), show: can("audit.view", "security.ip_rules") },
      { to: "/security/mfa", icon: "password", label: t("security.mfaNav"), show: can("security.console") },
      { to: "/security/statements", icon: "monitoring", label: t("security.stmt.nav"), show: can("security.console") },
      { to: "/admin/privacy", icon: "privacy_tip", label: t("account.privacyRequests"), show: can("privacy.manage") },
      { to: "/regulator", icon: "gavel", label: t("nav.regulator"), show: can("regulator.dashboard", "report.platform") },
      { to: "/admin/reports", icon: "summarize", label: t("rpt.nav"), show: can("report.platform") },
      { to: "/admin/payments", icon: "account_balance", label: t("pay.nav"), show: can("ledger.reconcile", "payment.fee_policy", "compensation.pay", "payment.methods", "cash.remittance", "cash.credit_limit") },
      { to: "/admin/integrations", icon: "api", label: t("api.nav"), show: can("security.api_clients") },
      { to: "/admin/modules", icon: "apps", label: t("modules.title"), show: can("modules.manage") },
      ...mods,
    ]} />
  );
}

function CarrierShell() {
  const { t } = useI18n();
  const { can } = useAuth();
  const mods = useModuleNav("/carrier");
  return (
    <PortalShell title={t("nav.carrier")} items={[
      { to: "/carrier", end: true, icon: "dashboard", label: t("carrier.dashboard") },
      { to: "/carrier/counter", icon: "point_of_sale", label: t("counter.nav"), show: can("sale.cash") },
      { to: "/carrier/trips", icon: "directions_bus", label: t("carrier.trips") },
      { to: "/carrier/routes", icon: "route", label: t("carrier.routes") },
      { to: "/carrier/vehicles", icon: "directions_car", label: t("carrier.vehicles") },
      { to: "/carrier/layouts", icon: "event_seat", label: t("layout.title") },
      { to: "/carrier/crew", icon: "badge", label: t("carrier.crew") },
      { to: "/carrier/parcels", icon: "local_shipping", label: t("parcel.carrierNav"), show: can("parcels.tariffs", "shipping.operate") },
      { to: "/carrier/documents", icon: "fact_check", label: t("documents.title"), show: can("company.staff", "vehicle.manage", "company.billing") },
      { to: "/carrier/finance", icon: "payments", label: t("finance.title") },
      { to: "/carrier/reports", icon: "summarize", label: t("rpt.nav"), show: can("report.company") },
      { to: "/carrier/integrations", icon: "api", label: t("api.nav"), show: can("company.api_keys") },
      ...mods,
    ]} />
  );
}

function AgencyShell() {
  const { t } = useI18n();
  const { can } = useAuth();
  const mods = useModuleNav("/agency");
  return (
    <PortalShell title={t("nav.agency")} items={[
      { to: "/agency", end: true, icon: "dashboard", label: t("agency.dashboard") },
      { to: "/agency/search", icon: "search", label: t("agency.sell"), show: can("booking.on_behalf") },
      { to: "/agency/bookings", icon: "confirmation_number", label: t("agency.bookings") },
      { to: "/agency/statement", icon: "receipt_long", label: t("agency.statement"), show: can("report.company", "company.billing", "booking.on_behalf") },
      { to: "/agency/staff", icon: "badge", label: t("agency.staff"), show: can("company.staff") },
      { to: "/agency/documents", icon: "fact_check", label: t("documents.title"), show: can("company.staff", "vehicle.manage", "company.billing") },
      { to: "/agency/finance", icon: "payments", label: t("finance.title"), show: can("company.payout_schedule", "company.billing") },
      { to: "/agency/topup", icon: "account_balance_wallet", label: t("pay.agencyNav"), show: can("booking.on_behalf", "sale.cash") },
      { to: "/agency/reports", icon: "summarize", label: t("rpt.nav"), show: can("report.company") },
      { to: "/agency/integrations", icon: "api", label: t("api.nav"), show: can("company.api_keys") },
      ...mods,
    ]} />
  );
}

function TestGatewayRoute() {
  const { uid } = useParams();
  return <TestGateway uid={uid ?? ""} />;
}

function NotFound() {
  const { t } = useI18n();
  return <div className="page"><div className="card"><Empty icon="travel_explore" title={t("errors.NOT_FOUND")} /></div></div>;
}

export default function App() {
  return (
    <BrowserRouter>
      <Suspense fallback={<Spinner />}>
      <Routes>
        <Route element={<PublicLayout />}>
          <Route index element={<Home />} />
          <Route path="search" element={<Results />} />
          <Route path="trip/:uid" element={<Book />} />
          <Route path="booking/:ref" element={<RequirePortal portal="PASSENGER"><Booking /></RequirePortal>} />
          <Route path="trips" element={<RequirePortal portal="PASSENGER"><MyTrips /></RequirePortal>} />
          <Route path="wallet" element={<RequirePortal portal="PASSENGER"><Wallet /></RequirePortal>} />
          <Route path="family" element={<RequirePortal portal="PASSENGER"><Family /></RequirePortal>} />
          <Route path="support" element={<RequirePortal portal="PASSENGER"><Support /></RequirePortal>} />
          <Route path="parcels" element={<RequirePortal portal="PASSENGER"><Parcels /></RequirePortal>} />
          <Route path="verify" element={<Verify />} />
          <Route path="track" element={<Track />} />
          <Route path="pay/test/:uid" element={<RequirePortal portal="PASSENGER"><TestGatewayRoute /></RequirePortal>} />
          <Route path="track/:no" element={<Track />} />
          <Route path="account" element={<RequireUser><AccountPage /></RequireUser>} />
          <Route path="m/:module" element={<RequirePortal portal="PASSENGER"><div className="page"><ModulePage /></div></RequirePortal>} />
          <Route path="services" element={<RequirePortal portal="PASSENGER"><ServicesPage /></RequirePortal>} />
          <Route path="login" element={<Login />} />
          <Route path="register" element={<Register />} />
          <Route path="mfa" element={<Mfa />} />
          <Route path="*" element={<NotFound />} />
        </Route>
        <Route element={<RequirePortal portal="OPERATOR"><CarrierShell /></RequirePortal>}>
          <Route path="carrier" element={<CarrierDashboard />} />
          <Route path="carrier/trips" element={<CarrierTrips />} />
          <Route path="carrier/routes" element={<CarrierRoutes />} />
          <Route path="carrier/vehicles" element={<CarrierVehicles />} />
          <Route path="carrier/layouts" element={<CarrierLayouts />} />
          <Route path="carrier/finance" element={<CompanyFinance />} />
          <Route path="carrier/documents" element={<CompanyDocuments />} />
          <Route path="carrier/crew" element={<CarrierCrew />} />
          <Route path="carrier/parcels" element={<CarrierParcels />} />
          <Route path="carrier/m/:module" element={<ModulePage />} />
          <Route path="carrier/reports" element={<ReportsPage />} />
          <Route path="carrier/integrations" element={<IntegrationsPage />} />
          <Route path="carrier/counter" element={<CounterDashboard />} />
          <Route path="carrier/counter/search" element={<CounterSell />} />
          <Route path="carrier/counter/trip/:uid" element={<Book />} />
          <Route path="carrier/counter/booking/:ref" element={<Booking />} />
          <Route path="carrier/counter/report" element={<CounterReport />} />
        </Route>
        <Route element={<RequirePortal portal="AGENCY"><AgencyShell /></RequirePortal>}>
          <Route path="agency" element={<AgencyDashboard />} />
          <Route path="agency/search" element={<AgencySell />} />
          <Route path="agency/trip/:uid" element={<Book />} />
          <Route path="agency/booking/:ref" element={<Booking />} />
          <Route path="agency/bookings" element={<AgencyBookings />} />
          <Route path="agency/statement" element={<AgencyStatement />} />
          <Route path="agency/staff" element={<AgencyStaff />} />
          <Route path="agency/finance" element={<CompanyFinance />} />
          <Route path="agency/m/:module" element={<ModulePage />} />
          <Route path="agency/documents" element={<CompanyDocuments />} />
          <Route path="agency/reports" element={<ReportsPage />} />
          <Route path="agency/topup" element={<AgencyTopup />} />
          <Route path="agency/integrations" element={<IntegrationsPage />} />
        </Route>
        <Route element={<RequirePortal portal="DRIVER"><DriverLayout /></RequirePortal>}>
          <Route path="driver" element={<DriverTrips />} />
          <Route path="driver/trip/:uid" element={<DriverTrip />} />
        </Route>
        <Route element={<RequirePortal portal="PLATFORM"><PlatformShell /></RequirePortal>}>
          <Route path="admin" element={<AdminOverview />} />
          <Route path="admin/companies" element={<AdminCompanies />} />
          <Route path="admin/agencies" element={<AdminAgencies />} />
          <Route path="admin/finance" element={<AdminFinance />} />
          <Route path="admin/documents" element={<AdminDocuments />} />
          <Route path="admin/privacy" element={<AdminPrivacy />} />
          <Route path="admin/stations" element={<AdminStations />} />
          <Route path="admin/modules" element={<AdminModules />} />
          <Route path="admin/m/:module" element={<ModulePage />} />
          <Route path="admin/reports" element={<ReportsPage />} />
          <Route path="admin/payments" element={<PaymentsDesk />} />
          <Route path="admin/integrations" element={<IntegrationsPage />} />
          <Route path="security" element={<SecurityOverview />} />
          <Route path="security/rules" element={<SecurityRules />} />
          <Route path="security/auth" element={<SecurityAuthLog />} />
          <Route path="security/activity" element={<SecurityActivity />} />
          <Route path="security/mfa" element={<MfaPolicy />} />
          <Route path="security/statements" element={<Statements />} />
          <Route path="regulator" element={<Regulator />} />
        </Route>
      </Routes>
      </Suspense>
    </BrowserRouter>
  );
}
