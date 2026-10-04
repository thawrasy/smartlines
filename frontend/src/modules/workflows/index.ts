import type { ComponentType } from "react";

/** Workflow screens per module and portal, shown before the module's records. */
export const WORKFLOWS: Record<string, Record<string, { key: string; component: ComponentType }[]>> = {};
