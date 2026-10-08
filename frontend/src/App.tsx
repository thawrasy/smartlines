import type { ReactNode } from "react";
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
import { CarrierCrew, CarrierDashboard, CarrierRoutes, CarrierTrips, CarrierVehicles } from "./pages/carrier/Carrier";
import { CarrierLayouts } from "./pages/carrier/Layouts";
import { CounterDashboard, CounterReport, CounterSell } from "./pages/carrier/Counter";
import { AdminFinance, CompanyFinance } from "./pages/finance/Finance";
import { AdminDocuments, CompanyDocuments } from "./pages/documents/Documents";
import { AccountPage, AdminPrivacy } from "./pages/account/Account";
import { DriverLayout, DriverTrip, DriverTrips } from "./pages/driver/Driver";
import { AdminAgencies, AdminCompanies, AdminOverview, AdminStations } from "./pages/admin/Admin";
import { AgencyBookings, AgencyDashboard, AgencySell, AgencyStaff, AgencyStatement } from "./pages/agency/Agency";
import { SecurityActivity, SecurityAuthLog, SecurityOverview, SecurityRules } from "./pages/security/Security";
import Regulator from "./pages/regulator/Regulator";
import { ModulePage } from "./modules/ModulePage";
import { ServicesPage } from "./modules/ServicesPage";
import { AdminModules } from "./modules/AdminModules";
import { useModules } from "./modules/context";
import { useLabels } from "./modules/labels";
import type { NavItem } from "./components/layout";
import { ReportsPage } from "./pages/reports/Reports";
import { AgencyTopup, PaymentsDesk } from "./pages/finance/Payments";
import { IntegrationsPage } from "./pages/integrations/Integrations";
import { TestGateway } from "./pages/passenger/Wallet";
import type { IconName } from "./components/icons";

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
      { to: "/carrier/documents", icon: "fact_check", label: t("documents.title") },
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
      { to: "/agency/documents", icon: "fact_check", label: t("documents.title"), show: can("company.staff", "company.billing") },
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
          <Route path="regulator" element={<Regulator />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}
