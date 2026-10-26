import { useState } from "react";
import { useI18n } from "../i18n";
import { Icon, Modal } from "./ui";

/** What a new member of staff types at the business sign-in door (N16, 1150), shown once to the administrator who made
 *  the account. The password itself is the temporary one the administrator chose; it is never shown back. */
export interface SignIn { company_no: string; username: string; temp_password_expires_at: string }

export function useSignInSlip() {
  const { t, dateTime } = useI18n();
  const [slip, setSlip] = useState<SignIn | null>(null);
  const element = slip && (
    <Modal title={t("slip.title")} onClose={() => setSlip(null)}
           actions={<button className="btn" onClick={() => setSlip(null)}>{t("common.close")}</button>}>
      <div className="stack">
        <p className="small muted">{t("slip.sub")}</p>
        <dl className="kv">
          <dt>{t("auth.companyNo")}</dt><dd className="ltr"><strong>{slip.company_no}</strong></dd>
          <dt>{t("auth.username")}</dt><dd className="ltr"><strong>{slip.username}</strong></dd>
          <dt>{t("slip.expires")}</dt><dd>{dateTime(slip.temp_password_expires_at)}</dd>
        </dl>
        <div className="alert info small"><Icon name="password" size={20} /><span>{t("slip.note")}</span></div>
      </div>
    </Modal>
  );
  return { show: (s: SignIn | undefined) => s && setSlip(s), element };
}
