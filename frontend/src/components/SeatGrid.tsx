import type { ReactNode } from "react";
import { useI18n } from "../i18n";
import { Icon } from "./ui";

// One seat of a layout, as numbered by the server (backend/app/modules/fleet/layout.py)
export interface LayoutSeat { n: number; label: string; deck: number; row: number; col: number; cabin: string }
export interface SeatMapData { decks: string[][]; seats: LayoutSeat[]; name?: string }

const CELL = 44, AISLE = 22;

/** Draws a vehicle seat layout as it really is, row by row. The geometry never mirrors with the interface language:
 *  the driver sits front left in Syria, so the grid is always laid out left to right. renderSeat draws each seat
 *  (a button when booking, a numbered tile in the editor); onCell makes every position clickable (layout editor). */
export function SeatGrid({ data, renderSeat, onCell }: {
  data: SeatMapData;
  renderSeat: (seat: LayoutSeat) => ReactNode;
  onCell?: (deck: number, row: number, col: number) => void;
}) {
  const { t } = useI18n();
  const at = new Map(data.seats.map((s) => [`${s.deck}:${s.row}:${s.col}`, s]));
  return (
    <div className="stack">
      {data.decks.map((rows, d) => {
        const width = rows[0]?.length ?? 0;
        // A column that is aisle in every row is drawn narrow, like a real aisle
        const cols = Array.from({ length: width }, (_, c) => (rows.every((r) => r[c] === "_") ? `${AISLE}px` : `${CELL}px`)).join(" ");
        return (
          <div key={d} className="bus" dir="ltr">
            <div className="bus-front">
              {d === 0 ? <span className="row" style={{ gap: 4 }}><Icon name="directions_car" size={18} />{t("seats.driver")}</span> : <span />}
              {data.decks.length > 1 ? <strong>{t(d === 0 ? "layout.lowerDeck" : "layout.upperDeck")}</strong> : <span>{t("seats.front")}</span>}
            </div>
            <div className="seat-grid" style={{ gridTemplateColumns: cols }}>
              {rows.flatMap((line, r) => [...line].map((ch, c) => {
                const key = `${d + 1}:${r + 1}:${c + 1}`;
                const seat = at.get(key);
                const click = onCell ? () => onCell(d, r, c) : undefined;
                if (seat && !onCell) return <div key={key}>{renderSeat(seat)}</div>;
                if (seat) return <button key={key} type="button" className="cell-btn" onClick={click}>{renderSeat(seat)}</button>;
                const label = ch === "D" ? t("layout.cells.D") : ch === "C" ? t("layout.cells.C") : ch === "R" ? t("layout.cells.R") : "";
                const cls = ch === "_" ? "cell aisle" : ch === "X" ? "cell empty" : "cell feature";
                return onCell
                  ? <button key={key} type="button" className={`${cls} cell-btn`} onClick={click} aria-label={t(`layout.cells.${ch}`)}>{label}</button>
                  : <div key={key} className={cls} title={label || undefined}>{label}</div>;
              }))}
            </div>
          </div>
        );
      })}
    </div>
  );
}
