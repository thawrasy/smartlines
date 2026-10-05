// Interface names for modules, resources, fields, actions and values: the same wording as the website (the "fw"
// section of the locale files is generated from it), falling back to readable English.
import { useCallback } from "react";
import { useI18n } from "../i18n";

export function humanize(name: string): string {
  const s = name.replace(/_id$/, "").replace(/[_-]/g, " ").trim();
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

export function useLabels() {
  const { t, has } = useI18n();
  const pick = useCallback((key: string, fallback: string) => (has(key) ? t(key) : fallback), [t, has]);
  return {
    module: (k: string) => pick(`fw.mod.${k}`, humanize(k)),
    moduleDesc: (k: string) => pick(`fw.modDesc.${k}`, ""),
    res: (k: string) => pick(`fw.res.${k}`, humanize(k)),
    group: (k: string) => pick(`fw.grp.${k}`, humanize(k)),
    field: (k: string) => pick(`fw.f.${k}`, humanize(k)),
    action: (k: string) => pick(`fw.act.${k}`, humanize(k)),
    value: (v: string) => pick(`fw.val.${v}`, pick(`status.${v}`, humanize(v))),
    tile: (id: string) => pick(`fw.dash.${id}`, humanize(id)),
  };
}

/** How a status reads: green for done, amber for waiting, red for stopped. */
export function tone(v: string): "green" | "amber" | "red" | "blue" | "neutral" {
  if (/^(ACTIVE|APPROVED|CONFIRMED|COMPLETED|DELIVERED|PUBLISHED|PAID|SUCCESS|VERIFIED|BOARDED|ISSUED|OPEN)$/.test(v)) return "green";
  if (/^(PENDING|DRAFT|REQUESTED|SUBMITTED|BOARDING|DEPARTED|IN_TRANSIT|HELD|QUOTED|AWAITING.*)$/.test(v)) return "amber";
  if (/^(CANCELLED|REJECTED|SUSPENDED|FAILED|EXPIRED|BLOCKED|DENIED|CLOSED|RETIRED|NO_SHOW)$/.test(v)) return "red";
  return "neutral";
}
