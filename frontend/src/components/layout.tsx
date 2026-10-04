import { useEffect, useState, type ReactNode } from "react";
import { Link, NavLink, Outlet, useLocation, useNavigate } from "react-router-dom";
import { useI18n, LOCALES, type Locale } from "../i18n";
import { useAuth, homeFor } from "../auth";
import { api } from "../api";
import { Icon, Logo } from "./ui";
import wordmarkAr from "../assets/brand/masslak-wordmark-ar.svg";
import wordmarkEn from "../assets/brand/masslak-wordmark-en.svg";
import type { IconName } from "./icons";
import { NotificationBell } from "./Notifications";
import { useModules } from "../modules/context";
import { useLabels } from "../modules/labels";

export function LangSwitch({ compact }: { compact?: boolean }) {
  const { locale, setLocale, t } = useI18n();
  const { me } = useAuth();
  const next = (Object.keys(LOCALES) as Locale[]).find((l) => l !== locale) ?? locale;
  const change = () => {
    setLocale(next);
    if (me) void api.patch("/api/auth/me/locale", { locale: next }).catch(() => {});
  };
  return (
    <button className={compact ? "icon-btn" : "btn text"} onClick={change} title={t("lang.switchTo")}>
      <Icon name="language" />{!compact && <span className="lang-label">{LOCALES[next].messages.lang[next]}</span>}
    </button>
  );
}

function Brand({ to = "/" }: { to?: string }) {
  const { t, locale } = useI18n();
  // The English interface shows the Latin wordmark; the Arabic one shows the Arabic wordmark with the Latin beside it
  return (
    <Link to={to} className="brand">
      <Logo />
      {locale === "ar" ? (
        <>
          <img className="brand-name" src={wordmarkAr} alt={t("app.name")} />
          <img className="brand-latin" src={wordmarkEn} alt="" aria-hidden="true" />
        </>
      ) : <img className="brand-name" src={wordmarkEn} alt={t("app.name")} />}
    </Link>
  );
}

export function PublicLayout() {
  const { t } = useI18n();
  const { me, logout } = useAuth();
  const nav = useNavigate();
  const passenger = me?.portal === "PASSENGER";
  const { modules, on } = useModules();
  const L = useLabels();
  const mine = passenger ? modules.filter((m) => m.resources.length > 0) : [];
  return (
    <>
      <header className="topbar">
        <Brand />
        <nav className="topnav grow">
          <NavLink to="/" end>{t("nav.search")}</NavLink>
          {passenger && <NavLink to="/trips">{t("nav.myTrips")}</NavLink>}
          {passenger && <NavLink to="/wallet">{t("nav.wallet")}</NavLink>}
          {mine.length > 0 && <ModulesMenu items={mine.map((m) => ({ to: `/m/${m.key}`, icon: m.icon as IconName, label: L.module(m.key) }))} />}
          {passenger && <NavLink to="/account">{t("nav.account")}</NavLink>}
          <NavLink to="/verify">{t("nav.verify")}</NavLink>
        </nav>
        <div className="row nowrap" style={{ gap: 4, marginInlineStart: "auto" }}>
          <LangSwitch />
          {me ? (
            <>
              <NotificationBell />
              {!passenger && <Link className="btn tonal small" to={homeFor(me)}>{t("nav.portals")}</Link>}
              <button className="icon-btn" title={t("nav.logout")} onClick={async () => { await logout(); nav("/"); }}>
                <Icon name="logout" flip />
              </button>
            </>
          ) : (
            <Link className="btn small" to="/login">{t("nav.login")}</Link>
          )}
        </div>
      </header>
      <Outlet />
      <footer className="footer">
        <div className="row between">
          <span>{t("app.footer")}</span>
          <span className="row" style={{ gap: 16 }}>
            <Link to="/verify">{t("nav.verify")}</Link>
            {on("cargo") && <Link to="/track">{t("wf.track.title")}</Link>}
            <Link to="/login?portal=OPERATOR">{t("nav.portals")}</Link>
          </span>
        </div>
      </footer>
      {passenger && <MobileNav services={mine.length ? "/services" : undefined} />}
    </>
  );
}

function ModulesMenu({ items }: { items: NavItem[] }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const loc = useLocation();
  useEffect(() => setOpen(false), [loc.pathname]);
  return (
    <div className="menu-anchor">
      <button className={`btn text${loc.pathname.startsWith("/m/") ? " active" : ""}`} onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <Icon name="apps" />{t("modules.services")}
      </button>
      {open && (
        <div className="menu-pop">
          {items.map((i) => <NavLink key={i.to} to={i.to} className="nav-item"><Icon name={i.icon} />{i.label}</NavLink>)}
        </div>
      )}
    </div>
  );
}

function MobileNav({ services }: { services?: string }) {
  const { t } = useI18n();
  const items: [string, IconName, string][] = [["/", "search", t("nav.search")], ["/trips", "confirmation_number", t("nav.myTrips")], ["/wallet", "account_balance_wallet", t("nav.wallet")]];
  if (services) items.push([services, "apps", t("modules.services")]);
  return (
    <nav className="navbar mobile-only">
      {items.map(([to, icon, label]) => (
        <NavLink key={to} to={to} end={to === "/"}><span className="pill"><Icon name={icon} /></span>{label}</NavLink>
      ))}
    </nav>
  );
}

export interface NavItem { to: string; icon: IconName; label: string; end?: boolean; show?: boolean }

export function PortalShell({ title, items, children }: { title: string; items: NavItem[]; children?: ReactNode }) {
  const { t } = useI18n();
  const { me, logout } = useAuth();
  const nav = useNavigate();
  const loc = useLocation();
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [loc.pathname]);
  const current = items.find((i) => (i.end ? loc.pathname === i.to : loc.pathname.startsWith(i.to)));
  return (
    <div className="shell">
      {open && <div className="scrim" onClick={() => setOpen(false)} />}
      <aside className={`drawer${open ? " open" : ""}`}>
        <Brand to={me ? homeFor(me) : "/"} />
        <div className="drawer-section">{title}</div>
        {items.filter((i) => i.show !== false).map((i) => (
          <NavLink key={i.to} to={i.to} end={i.end} className={({ isActive }) => `nav-item${isActive ? " active" : ""}`}>
            <Icon name={i.icon} />{i.label}
          </NavLink>
        ))}
        {children}
        <div className="org-card">
          <div style={{ fontWeight: 600 }}>{me?.company?.name ?? me?.name}</div>
          <div className="muted ltr">{me?.email}</div>
          <div className="row" style={{ marginTop: 8, gap: 4 }}>
            <LangSwitch compact />
            <Link className="icon-btn" to="/account" title={t("nav.account")} aria-label={t("nav.account")}><Icon name="person" /></Link>
            <button className="icon-btn" title={t("nav.logout")} onClick={async () => { await logout(); nav("/login"); }}><Icon name="logout" flip /></button>
          </div>
        </div>
      </aside>
      <div className="main">
        <div className="main-bar">
          <button className="icon-btn menu-btn" onClick={() => setOpen(true)} aria-label={t("nav.menu")}><Icon name="menu" /></button>
          <h3 className="grow">{current?.label ?? title}</h3>
          <NotificationBell />
        </div>
        <div className="main-content"><Outlet /></div>
      </div>
    </div>
  );
}

export function PageHead({ title, sub, children }: { title: string; sub?: string; children?: ReactNode }) {
  return (
    <div className="page-head">
      <div><h1 style={{ fontSize: 28 }}>{title}</h1>{sub && <p>{sub}</p>}</div>
      {children && <div className="row">{children}</div>}
    </div>
  );
}
