import { zone } from "./i18n";

// Calendar date (YYYY-MM-DD) in the market on screen (1061), offset by whole days
export function localDate(offsetDays = 0, from?: string): string {
  const base = from ? new Date(`${from}T12:00:00Z`) : new Date();
  const d = new Date(base.getTime() + offsetDays * 86400000);
  return from ? d.toISOString().slice(0, 10) : new Intl.DateTimeFormat("en-CA", { timeZone: zone() }).format(d);
}

export function minutesBetween(a: string, b: string) {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60000);
}
