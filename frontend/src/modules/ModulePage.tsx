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
import { WORKFLOWS } from "./workflows";

/** One module in one portal: its workflow screens first, then its records grouped as the platform defines them. */
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
  const tabs = [...flows.map((f) => ({ id: `w:${f.key}`, label: t(`wf.${f.key}.title`) })), ...groups.map(([g]) => ({ id: `g:${g}`, label: L.group(g) }))];
  const [tab, setTab] = useState<string | null>(null);
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
      {tabs.length === 0 && <div className="card"><Empty icon="extension" title={t("modules.nothingHere")} /></div>}
      {Flow && <Flow />}
      {groupRes.map((r) => <ResourceTable key={r} res={r} />)}
    </div>
  );
}
