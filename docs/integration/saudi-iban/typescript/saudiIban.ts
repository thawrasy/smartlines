/**
 * Saudi IBAN validation: ISO 13616 structure, ISO 7064 MOD 97-10 check digits, and the SAMA bank-code lookup.
 * Reference implementation for integrators, the same rules and error codes as ../python/saudi_iban.py.
 * The bank table is ../saudi_banks.json and the messages ../messages.json (bundlers: enable resolveJsonModule).
 *
 *   validateSaudiIban("SA03 8000 0000 6080 1016 7519")
 *   // { valid: true, error: null, iban: "SA0380000000608010167519", bankCode: "80", bank: { name_en: "Al Rajhi Bank", ... } }
 */
import table from "../saudi_banks.json" with { type: "json" };
import messages from "../messages.json" with { type: "json" };

export type BankStatus = "active" | "digital" | "foreign_branch" | "legacy_merged";

export interface Bank {
  code: string;
  name_ar: string;
  name_en: string;
  status: BankStatus;
  swift: string;
  swift_confidence: "confirmed" | "single_source" | "unconfirmed";
}

export type IbanError =
  | "EMPTY"
  | "INVALID_CHARACTERS"
  | "COUNTRY_NOT_SA"
  | "WRONG_LENGTH"
  | "INVALID_FORMAT"
  | "INVALID_CHECK_DIGITS"
  | "CHECKSUM_FAILED"
  | "UNKNOWN_BANK";

export type IbanWarning = "LEGACY_BANK" | "UNKNOWN_BANK";

export interface IbanResult {
  valid: boolean;
  error: IbanError | null;
  iban: string;
  formatted: string;
  bankCode: string | null;
  bank: Bank | null;
  warnings: IbanWarning[];
}

export const BANKS: ReadonlyMap<string, Bank> = new Map((table.banks as Bank[]).map((b) => [b.code, b]));

/** The user-facing text for an error or warning code, in Arabic or English (../messages.json). */
export function message(code: IbanError | IbanWarning, lang: "ar" | "en" = "ar"): string {
  const errors = messages.errors as Record<string, { ar: string; en: string }>;
  const warnings = messages.warnings as Record<string, { ar: string; en: string }>;
  return (errors[code] ?? warnings[code])[lang];
}

const LENGTH = 24;
const FORMAT = /^SA[0-9]{2}[0-9]{2}[0-9A-Z]{18}$/; // SWIFT IBAN Registry: SA2!n2!n18!c

/** Electronic form: no separators, upper case, Arabic-Indic digits as ASCII, an optional leading "IBAN" dropped. */
export function normaliseIban(value: string): string {
  const iban = (value ?? "")
    .replace(/[\s\u00a0\u200f\u200e-]/g, "")
    .replace(/[\u0660-\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660)) // Arabic-Indic digits
    .replace(/[\u06f0-\u06f9]/g, (d) => String(d.charCodeAt(0) - 0x06f0)) // Persian digits
    .toUpperCase();
  return iban.startsWith("IBAN") ? iban.slice(4) : iban;
}

/** Remainder of the rearranged IBAN modulo 97, one character at a time so no BigInt is needed. */
export function mod97(iban: string): number {
  let remainder = 0;
  for (const ch of iban.slice(4) + iban.slice(0, 4)) {
    const value = parseInt(ch, 36); // "0".."9" -> 0..9, "A".."Z" -> 10..35
    remainder = (remainder * (value > 9 ? 100 : 10) + value) % 97;
  }
  return remainder;
}

/** The two check digits for a bank code and an 18-character account part. */
export function checkDigits(bankCode: string, account: string): string {
  return String(98 - mod97("SA00" + bankCode + account)).padStart(2, "0");
}

/**
 * Checks, in order: characters, country, length, format, check-digit range, MOD-97, bank code.
 * With strictBank false an unregistered bank code is a warning instead of an error.
 */
export function validateSaudiIban(value: string, { strictBank = true } = {}): IbanResult {
  const iban = normaliseIban(value);
  const fail = (error: IbanError, extra: Partial<IbanResult> = {}): IbanResult => ({
    valid: false, error, iban, formatted: "", bankCode: null, bank: null, warnings: [], ...extra,
  });
  if (!iban) return fail("EMPTY");
  if (!/^[0-9A-Z]+$/.test(iban)) return fail("INVALID_CHARACTERS");
  if (!iban.startsWith("SA")) return fail("COUNTRY_NOT_SA");
  if (iban.length !== LENGTH) return fail("WRONG_LENGTH");
  if (!FORMAT.test(iban)) return fail("INVALID_FORMAT");
  const formatted = iban.match(/.{4}/g)!.join(" ");
  const bankCode = iban.slice(4, 6);
  const bank = BANKS.get(bankCode) ?? null;
  if (["00", "01", "99"].includes(iban.slice(2, 4))) return fail("INVALID_CHECK_DIGITS", { formatted, bankCode, bank });
  if (mod97(iban) !== 1) return fail("CHECKSUM_FAILED", { formatted, bankCode, bank });
  if (!bank) {
    if (strictBank) return fail("UNKNOWN_BANK", { formatted, bankCode });
    return { valid: true, error: null, iban, formatted, bankCode, bank: null, warnings: ["UNKNOWN_BANK"] };
  }
  const warnings: IbanWarning[] = bank.status === "legacy_merged" ? ["LEGACY_BANK"] : [];
  return { valid: true, error: null, iban, formatted, bankCode, bank, warnings };
}
