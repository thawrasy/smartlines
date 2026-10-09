import { Link } from "react-router-dom";
import { api, type BookingRow } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, Icon, Loaded, Status, useLoad } from "../../components/ui";

export default function MyTrips() {
  const { t, city, time, date, money } = useI18n();
  const state = useLoad(() => api.get<{ bookings: BookingRow[] }>("/api/bookings"));
  return (
    <div className="page stack">
      <PageHead title={t("myTrips.title")} sub={t("myTrips.subtitle")} />
      <Loaded state={state}>{({ bookings }) => bookings.length === 0 ? (
        <div className="card"><Empty icon="confirmation_number" title={t("myTrips.none")}><Link className="btn" to="/">{t("myTrips.book")}</Link></Empty></div>
      ) : (
        <div className="grid cols-2">
          {bookings.map((b) => (
            <Link key={b.booking_ref} to={`/booking/${b.booking_ref}`} className="card stack tight" style={{ color: "inherit", textDecoration: "none", borderStyle: b.status === "CANCELLED" ? "dashed" : undefined }}>
              <div className="row between">
                <span className="mono muted">{b.booking_ref}</span>
                <Status value={b.status} />
              </div>
              {b.journey && (
                <div className="row nowrap" style={{ marginTop: 8 }}>
                  <div><div style={{ fontSize: 20, fontWeight: 600 }}>{city(b.journey.from_city)}</div><div className="small muted">{time(b.journey.departs_at)}</div></div>
                  <span className="grow" style={{ height: 2, background: "var(--divider)" }} />
                  <Icon name="directions_bus" />
                  <span className="grow" style={{ height: 2, background: "var(--divider)" }} />
                  <div style={{ textAlign: "end" }}><div style={{ fontSize: 20, fontWeight: 600 }}>{city(b.journey.to_city)}</div><div className="small muted">{time(b.journey.arrives_at)}</div></div>
                </div>
              )}
              <div className="row between small muted" style={{ marginTop: 8 }}>
                <span>{b.journey ? date(b.journey.departs_at, { weekday: "long", day: "numeric", month: "long" }) : ""} · {b.carrier_name}</span>
                <strong style={{ color: "var(--on-surface)" }}>{money(b.total_amount)}</strong>
              </div>
            </Link>
          ))}
        </div>
      )}</Loaded>
    </div>
  );
}
