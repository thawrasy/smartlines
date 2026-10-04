import { useMemo, useState, type ComponentType } from "react";
import { Navigate, useParams } from "react-router-dom";
import { useAuth } from "../auth";
import { useI18n } from "../i18n";
import { PageHead } from "../components/layout";
import { Empty, Icon, Spinner } from "../components/ui";
import type { IconName } from "../components/icons";
import { useModules } from "./context";
import { useLabels } from "./labels";
import { ResourceTable } from "./ResourceTable";
import { WORKFLOWS, WORKFLOW_FIRST } from "./workflows";
import { ModuleDashboard } from "./ModuleDashboard";

/** One module in one portal: its dashboard, its workflow screens, then its records grouped as the platform defines them. */
export function ModulePage() {
  const { module = "" } = useParams();
  const { me } = useAuth();
  const { t } = useI18n();
  const L = useLabels();
  const { modules, ready } = useModules();
  const info = modules.find((m) => m.key === module);
  const portal = me?.portal ?? "PASSENGER";
  const flows: { key: string; component: ComponentType }[] = useMemo(
    () => (WORKFLOWS[module]?.[portal] ?? []), [module, portal]);
  const groups = useMemo(() => {
    const g = new Map<string, string[]>();
    for (const r of info?.resources ?? []) g.set(r.group || "records", [...(g.get(r.group || "records") ?? []), r.key]);
    return [...g.entries()];
  }, [info]);
  const overview = groups.length > 0 ? [{ id: "overview", label: t("dash.overview") }] : [];
  const flowTabs = flows.map((f) => ({ id: `w:${f.key}`, label: t(`wf.${f.key}.title`) }));
  // passengers come to do something, staff to see how things stand
  const tabs = [...(portal === "PASSENGER" && WORKFLOW_FIRST.has(module) ? [...flowTabs, ...overview] : [...overview, ...flowTabs]),
                ...groups.map(([g]) => ({ id: `g:${g}`, label: L.group(g) }))];
  const [tab, setTab] = useState<string | null>(null);
  const open = (res: string) => {
    const g = groups.find(([, list]) => list.includes(res));
    if (!g) return;
    setTab(`g:${g[0]}`);
    setTimeout(() => document.getElementById(`res-${res}`)?.scrollIntoView({ behavior: "smooth", block: "start" }), 150);
  };
  if (!ready) return <Spinner />;
  if (!info) return <Navigate to="/" replace />;
  const current = tab && tabs.some((x) => x.id === tab) ? tab : tabs[0]?.id;
  const Flow = current?.startsWith("w:") ? flows.find((f) => `w:${f.key}` === current)?.component : null;
  const groupRes = current?.startsWith("g:") ? groups.find(([g]) => `g:${g}` === current)?.[1] ?? [] : [];
  return (
    <div className="stack">
      <PageHead title={L.module(module)} sub={L.moduleDesc(module) || undefined}>
        <span className="chip outline"><Icon name={info.icon as IconName} size={16} />{info.phase === "core" ? t("modules.core") : t("modules.phase", { n: info.phase })}</span>
      </PageHead>
      {tabs.length > 1 && (
        <div className="tabs" role="tablist">
          {tabs.map((x) => <button key={x.id} role="tab" aria-selected={x.id === current} className={x.id === current ? "on" : ""} onClick={() => setTab(x.id)}>{x.label}</button>)}
        </div>
      )}
      {groups.length === 0 && flows.length === 0 && <div className="card"><Empty icon="extension" title={t("modules.nothingHere")} /></div>}
      {current === "overview" && <ModuleDashboard module={module} onOpen={open} />}
      {Flow && <Flow />}
      {groupRes.map((r) => <ResourceTable key={r} res={r} />)}
    </div>
  );
}
