// Draws the BankFas logo files of app/web/src/brand from the identity guide (v2.0, October 2026): the symbol from its
// geometry, the name in Sekuya turned into outlines, so the site never loads the logo's font (guide p.16).
// Usage: node logo.js <sekuya-latin-400-normal.woff> <out dir>, with opentype.js 1.3.4 and @fontsource/sekuya 5.3.0.
const opentype = require('opentype.js');
const fs = require('fs');
const font = opentype.loadSync(process.argv[2]);
// The symbol on its 200 grid (identity guide p.6): block radius 46, letter 106x128 from (46,36), fold 18 at 45 degrees,
// two slots 38x26 slanted 8, 28 apart.
const letter = 'M46 36H152V146L134 164H46Z M93 58H131L123 84H85Z M93 112H131L123 138H85Z';
function symbol(id, fill) {
  return `<rect width="200" height="200" rx="46" fill="${fill}"/><path d="${letter}" fill="#fff" fill-rule="evenodd"/>`;
}
const grad = id => `<linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#01503D"/><stop offset=".5" stop-color="#00A97F"/><stop offset="1" stop-color="#37DDB1"/></linearGradient>`;
const cap = 112, size = cap / (font.tables.os2.sCapHeight / font.unitsPerEm);
function words(x, baseline) {
  const a = font.getPath('BANK', x, baseline, size);
  const w = font.getAdvanceWidth('BANK', size);
  const b = font.getPath('FAS', x + w, baseline, size);
  const wb = font.getAdvanceWidth('FAS', size);
  return { bank: a.toPathData(1), fas: b.toPathData(1), end: x + w + wb };
}
const out = process.argv[3];
fs.writeFileSync(`${out}/symbol.svg`, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><defs>${grad('g')}</defs>${symbol('g','url(#g)')}</svg>\n`);
for (const [name, bank, fas] of [['logo', '#062A22', '#00A97F'], ['logo-inverse', '#F4F7F5', '#37DDB1']]) {
  const w = words(250, 100 + cap / 2);
  const width = Math.ceil(w.end);
  fs.writeFileSync(`${out}/${name}.svg`, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} 200" role="img" aria-label="BankFas"><defs>${grad('g')}</defs>${symbol('g','url(#g)')}<path d="${w.bank}" fill="${bank}"/><path d="${w.fas}" fill="${fas}"/></svg>\n`);
}
