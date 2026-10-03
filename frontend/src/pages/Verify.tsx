import { useEffect, useState, type FormEvent } from "react";
import { useSearchParams } from "react-router-dom";
import { api } from "../api";
import { useI18n } from "../i18n";
import { ErrorBox, Field, Icon, Status } from "../components/ui";

type Result =
  | { valid: false; reason: string }
  | { valid: true; kind: "booking"; booking_ref: string; status: string; trip_no: string; departure_at: string; tickets: number; total_amount: number }
  | { valid: true; kind: "ticket"; ticket_no: string; status: string; seat_no: number; trip_no: string; departure_at: string };

export default function Verify() {
  const { t, money, dateTime } = useI18n();
  const [params, setParams] = useSearchParams();
  const [token, setToken] = useState(params.get("token") ?? "");
  const [result, setResult] = useState<Result | null>(null);
  const [error, setError] = useState<unknown>(null);

  const check = async (value: string) => {
    setError(null); setResult(null);
    try { setResult(await api.get<Result>("/api/verify", { token: value.trim() })); } catch (e) { setError(e); }
  };
  useEffect(() => { const v = params.get("token"); if (v) void check(v); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const submit = (e: FormEvent) => { e.preventDefault(); setParams({ token: token.trim() }); void check(token); };

  return (
    <div className="page narrow stack">
      <div className="stack tight"><h1 style={{ fontSize: 30 }}>{t("verify.title")}</h1><p className="muted">{t("verify.subtitle")}</p></div>
      <form className="card stack" onSubmit={submit}>
        <Field label={t("verify.token")}><input className="input ltr mono" value={token} onChange={(e) => setToken(e.target.value)} required minLength={10} /></Field>
        <button className="btn" style={{ alignSelf: "flex-start" }}><Icon name="fact_check" />{t("verify.check")}</button>
      </form>
      <ErrorBox error={error} />
      {result && (result.valid ? (
        <div className="card stack" style={{ borderInlineStart: "6px solid var(--primary)" }}>
          <div className="row"><Icon name="verified" size={32} className="" /><h2 style={{ color: "var(--primary)" }}>{t("verify.valid")}</h2>
            <span className="chip green">{result.kind === "booking" ? t("verify.kindBooking") : t("verify.kindTicket")}</span></div>
          <dl className="kv">
            {result.kind === "booking" ? (<>
              <dt>{t("booking.ref")}</dt><dd className="mono">{result.booking_ref}</dd>
              <dt>{t("booking.tickets")}</dt><dd>{result.tickets}</dd>
              <dt>{t("common.total")}</dt><dd>{money(result.total_amount)}</dd>
            </>) : (<>
              <dt>{t("booking.ticketTitle")}</dt><dd className="mono">{result.ticket_no}</dd>
              <dt>{t("common.seat")}</dt><dd>{result.seat_no}</dd>
            </>)}
            <dt>{t("booking.tripNo")}</dt><dd className="mono">{result.trip_no}</dd>
            <dt>{t("booking.departs")}</dt><dd>{dateTime(result.departure_at)}</dd>
            <dt>{t("common.status")}</dt><dd><Status value={result.status} /></dd>
          </dl>
          <p className="small muted">{t("verify.noPersonal")}</p>
        </div>
      ) : (
        <div className="card stack" style={{ borderInlineStart: "6px solid var(--error)" }}>
          <div className="row"><span style={{ color: "var(--error)" }}><Icon name="cancel" size={32} /></span><h2 style={{ color: "var(--error)" }}>{t("verify.invalid")}</h2></div>
          <p>{t(`verify.reasons.${result.reason}`)}</p>
        </div>
      ))}
    </div>
  );
}
