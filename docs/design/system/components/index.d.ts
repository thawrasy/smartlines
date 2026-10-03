// Masslak components (window.Masslak). Plain React 18 components; styles in bundle.css, values from tokens.css.
import type { ReactNode, ButtonHTMLAttributes, CSSProperties } from "react";

export type IconName = "search" | "swap_horiz" | "directions_bus" | "confirmation_number" | "account_balance_wallet" | "person" | "event" | "group" | "schedule"
  | "location_on" | "check_circle" | "error" | "qr_code_2" | "qr_code_scanner" | "dashboard" | "route" | "local_shipping" | "add" | "verified" | "shield"
  | "notifications" | "menu" | "arrow_back" | "chevron_right" | "close" | "info" | "warning" | "airline_seat_recline_normal" | "settings" | "logout"
  | "language" | "home" | "sos" | "my_location" | "bluetooth";

export interface LogoProps { size?: number; withName?: boolean; lang?: "ar" | "en"; tagline?: string; gold?: boolean }
export interface IconProps { name: IconName; size?: number; flip?: boolean; className?: string }
export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "filled" | "tonal" | "outlined" | "text" | "wheat" | "danger"; size?: "sm" | "md" | "lg";
  icon?: IconName; trailingIcon?: IconName; block?: boolean; children?: ReactNode }
export interface IconButtonProps { icon: IconName; label: string; variant?: "standard" | "tonal" | "filled"; badge?: boolean; onClick?: () => void }
export interface TextFieldProps { id?: string; label?: string; value?: string; placeholder?: string; hint?: string; error?: string; icon?: IconName;
  filled?: boolean; required?: boolean; type?: string; dir?: "ltr" | "rtl"; multiline?: boolean; readOnly?: boolean }
export interface ChipProps { selected?: boolean; icon?: IconName; count?: number; onClick?: () => void; children: ReactNode }
export interface StatusBadgeProps { status: string; tone?: "green" | "wheat" | "blue" | "red" | "neutral"; children?: ReactNode }
export interface SegmentedButtonProps { options: { value: string; label: string; icon?: IconName }[]; value?: string; onChange?: (v: string) => void; label?: string }
export interface CardProps { variant?: "elevated" | "flat" | "tint" | "hero"; title?: ReactNode; action?: ReactNode; children?: ReactNode; className?: string; style?: CSSProperties }
export interface StatProps { icon: IconName; label: string; value: ReactNode; note?: string; tone?: "green" | "wheat" | "blue" | "red" }
export interface BannerProps { tone?: "info" | "success" | "warning" | "error"; title?: string; children?: ReactNode; action?: ReactNode }
export interface SnackbarProps { message: string; action?: string }
export interface TopAppBarProps { title: string; subtitle?: string; leading?: ReactNode; actions?: ReactNode; translucent?: boolean }
export interface NavItem { icon: IconName; label: string; active?: boolean; badge?: number | boolean }
export interface NavigationDrawerProps { brand?: ReactNode; sections: { title?: string; items: NavItem[] }[]; footer?: ReactNode; label?: string }
export interface NavigationBarProps { items: NavItem[]; label?: string }
export interface TripCardProps { carrier: string; fareBrand?: string; depart: string; arrive: string; from: string; to: string; duration?: string;
  price: string; currency?: string; seatsLeft?: number; seatsLabel?: string; tags?: string[]; action?: ReactNode }
export interface StopTimelineProps { stops: { name: string; time?: string; state?: "done" | "current" | "next"; note?: string }[] }
export interface SeatMapProps { rows?: number; taken?: number[]; selected?: number[]; legend?: [string, string, string]; frontLabel?: string; seatWord?: string }
export interface TicketProps { carrier: string; status?: string; statusLabel?: string; from: string; fromStation?: string; to: string; toStation?: string;
  date: string; time: string; seat: string; passenger: string; reference: string; offline?: string;
  labels?: { date: string; time: string; seat: string; passenger: string; ref: string } }
export interface DataTableProps { columns: { key: string; label: string; align?: "end"; mono?: boolean; status?: boolean }[]; rows: Record<string, any>[] }
export interface DialogProps { title: string; icon?: IconName; children?: ReactNode; actions?: ReactNode; inline?: boolean }
