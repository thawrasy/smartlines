import { useCallback } from "react";
import { useI18n } from "../i18n";

/** "pickup_window" -> "Pickup window"; reference columns lose their "_id". */
export function humanize(name: string) {
  const s = name.replace(/_id$/, "").replace(/_/g, " ").replace(/-/g, " ").trim();
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

/** Interface names for modules, resources, fields, actions and values, falling back to readable English. */
export function useLabels() {
  const { t, has } = useI18n();
  const pick = useCallback((key: string, fallback: string) => (has(key) ? t(key) : fallback), [t, has]);
  return {
    module: (k: string) => pick(`mod.${k}`, humanize(k)),
    moduleDesc: (k: string) => pick(`modDesc.${k}`, ""),
    res: (k: string) => pick(`res.${k}`, humanize(k)),
    group: (k: string) => pick(`grp.${k}`, humanize(k)),
    field: (k: string) => pick(`f.${k}`, humanize(k)),
    action: (k: string) => pick(`act.${k}`, humanize(k)),
    value: (v: string) => pick(`status.${v}`, pick(`val.${v}`, humanize(v))),
  };
}
