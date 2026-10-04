import { useState } from "react";
import { api } from "../api";
import { useI18n } from "../i18n";
import { PageHead } from "../components/layout";
import { ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../components/ui";
import type { IconName } from "../components/icons";
import { useModules } from "./context";
import { useLabels } from "./labels";

interface Mod { key: string; phase: string; icon: string; portals: string[]; enabled: boolean; resources: number }

/** Platform administration: switch modules on and off. Tables stay intact; a switched-off module disappears everywhere. */
export function AdminModules() {
  const { t } = useI18n();
  const L = useLabels();
  const toast = useToast();
  const modules = useModules();
  const state = useLoad(() => api.get<{ modules: Mod[] }>("/api/admin/modules"));
  const [pending, setPending] = useState<Mod | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const confirm = async () => {
    if (!pending) return;
    setError(null);
    try {
      await api.put(`/api/admin/modules/${pending.key}`, { enabled: !pending.enabled, reason });
      toast(pending.enabled ? t("modules.switchedOff") : t("modules.switchedOn"));
      setPending(null); setReason(""); state.reload(); modules.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <PageHead title={t("modules.title")} sub={t("modules.sub")} />
      <Loaded state={state}>{(d) => (
        <div className="grid cols-3">
          {d.modules.map((m) => (
            <div key={m.key} className={`card module-card${m.enabled ? " on" : ""}`}>
              <div className="row between nowrap">
                <span className="badge-ic"><Icon name={m.icon as IconName} /></span>
                <button className={`switch${m.enabled ? " on" : ""}`} role="switch" aria-checked={m.enabled} aria-label={L.module(m.key)}
                        onClick={() => { setPending(m); setReason(""); setError(null); }}><span /></button>
              </div>
              <h3 style={{ margin: "12px 0 4px" }}>{L.module(m.key)}</h3>
              <p className="muted small" style={{ margin: 0, minHeight: 40 }}>{L.moduleDesc(m.key)}</p>
              <div className="row small muted" style={{ marginTop: 12 }}>
                <span className="chip outline">{m.phase === "core" ? t("modules.core") : t("modules.phase", { n: m.phase })}</span>
                <span>{t("modules.screens", { n: m.resources })}</span>
              </div>
            </div>
          ))}
        </div>
      )}</Loaded>
      {pending && (
        <Modal title={pending.enabled ? t("modules.confirmOff", { name: L.module(pending.key) }) : t("modules.confirmOn", { name: L.module(pending.key) })}
               onClose={() => setPending(null)}
               actions={<><button className="btn text" onClick={() => setPending(null)}>{t("common.cancel")}</button>
                 <button className={`btn${pending.enabled ? " danger" : ""}`} disabled={reason.trim().length < 3} onClick={confirm}>{t("common.confirm")}</button></>}>
          <p className="muted">{pending.enabled ? t("modules.offNote") : t("modules.onNote")}</p>
          <Field label={t("modules.reason")}><input value={reason} onChange={(e) => setReason(e.target.value)} autoFocus /></Field>
          <ErrorBox error={error} />
        </Modal>
      )}
    </div>
  );
}
