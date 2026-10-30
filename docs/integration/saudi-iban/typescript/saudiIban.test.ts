// Runs the shared test vectors (../test_vectors.csv) against saudiIban.ts:
//   node --experimental-strip-types --test saudiIban.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { checkDigits, mod97, validateSaudiIban, BANKS } from "./saudiIban.ts";

function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], cell = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") { row.push(cell); cell = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell); rows.push(row); row = []; cell = "";
    } else cell += ch;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows;
}

const [head, ...rows] = parseCsv(readFileSync(new URL("../test_vectors.csv", import.meta.url), "utf-8"));
const col = (name: string) => head.indexOf(name);

test("shared test vectors", () => {
  assert.ok(rows.length > 40);
  for (const row of rows) {
    const r = validateSaudiIban(row[col("input")]);
    const label = `${row[col("note")]}: ${JSON.stringify(row[col("input")])}`;
    assert.equal(r.valid, row[col("valid")] === "true", label);
    assert.equal(r.error ?? "", row[col("error")], label);
    assert.equal(r.bankCode ?? "", row[col("bank_code")], label);
    assert.equal(r.warnings.join(";"), row[col("warnings")], label);
  }
});

test("check digits round trip for every bank", () => {
  for (const code of BANKS.keys()) {
    const account = "000000608010167519";
    assert.equal(mod97(`SA${checkDigits(code, account)}${code}${account}`), 1);
  }
});

test("lenient bank lookup", () => {
  const r = validateSaudiIban("SA3399000000608010167519", { strictBank: false });
  assert.equal(r.valid, true);
  assert.deepEqual(r.warnings, ["UNKNOWN_BANK"]);
});

test("result fields", () => {
  const r = validateSaudiIban("sa03 8000 0000 6080 1016 7519");
  assert.equal(r.iban, "SA0380000000608010167519");
  assert.equal(r.formatted, "SA03 8000 0000 6080 1016 7519");
  assert.equal(r.bank?.swift, "RJHISARI");
});
