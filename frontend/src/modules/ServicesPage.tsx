import { Link } from "react-router-dom";
import { useI18n } from "../i18n";
import { PageHead } from "../components/layout";
import { Empty, Icon } from "../components/ui";
import type { IconName } from "../components/icons";
import { useModules } from "./context";
import { useLabels } from "./labels";

/** Passenger list of the services switched on for them; on phones it is reached from the bottom bar. */
export function ServicesPage() {
  const { t } = useI18n();
  const L = useLabels();
  const mine = useModules().modules.filter((m) => m.resources.length > 0);
  return (
    <div className="page stack">
      <PageHead title={t("modules.services")} />
      {mine.length === 0 ? <Empty title={t("modules.nothingHere")} /> : (
        <div className="grid cols-3">
          {mine.map((m) => (
            <Link key={m.key} to={`/m/${m.key}`} className="card module-card on" style={{ color: "inherit", textDecoration: "none" }}>
              <span className="badge-ic"><Icon name={m.icon as IconName} /></span>
              <h3 style={{ margin: "12px 0 4px" }}>{L.module(m.key)}</h3>
              <p className="muted small" style={{ margin: 0 }}>{L.moduleDesc(m.key)}</p>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
