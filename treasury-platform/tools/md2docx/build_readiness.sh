#!/usr/bin/env bash
# Builds the readiness documents (docs/30-readiness/DOC-*.md) into Word:
#   - one .docx per document in docs/30-readiness/word/
#   - one combined volume docs/30-READINESS-P0.docx (every document in register order: DOC-F, DOC-S, DOC-B)
# Diagrams: set MMDC to the mermaid-cli binary (and MMDC_PUPPETEER to its puppeteer config when Chromium needs flags);
# without MMDC the Mermaid blocks stay as code, which is not fit for review, so the script refuses to run.
# Usage: MMDC=/path/to/mmdc [MMDC_PUPPETEER=/path/to/pp.json] tools/md2docx/build_readiness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/docs/30-readiness"
OUT_DIR="$SRC/word"
VOLUME="$ROOT/docs/30-READINESS-P0.docx"
: "${MMDC:?set MMDC to the mermaid-cli binary (mmdc) so diagrams are rendered as pictures}"
export MMDC
# docx and jszip: added to any NODE_PATH already set (some environments preset it to another folder)
export NODE_PATH="${NODE_PATH:+$NODE_PATH:}/opt/node22/lib/node_modules:/opt/node-tools/node_modules"
CONVERT=(node "$ROOT/tools/md2docx/md2docx.js")
mkdir -p "$OUT_DIR"

# Register order: DOC-F, then DOC-S, then DOC-B, each by number.
mapfile -t DOCS < <(cd "$SRC" && for p in 'DOC-F*.md' 'DOC-S*.md' 'DOC-B*.md'; do ls $p 2>/dev/null; done)
[ "${#DOCS[@]}" -gt 0 ] || { echo "no DOC-*.md in $SRC"; exit 1; }

for f in "${DOCS[@]}"; do
    id="${f:0:7}"   # DOC-F01
    "${CONVERT[@]}" "$SRC/$f" "$OUT_DIR/${f%.md}.docx" --header "$id · BankFas · مستندات الجاهزية P0 · 0.1 مسودة"
done

# Combined volume: each document becomes one part (its headings move down one level).
MD="$(mktemp --suffix=-readiness.md)"
cat > "$MD" <<HEAD
# مستندات الجاهزية للتنفيذ — المجموعة P0 (قبل S0)

| البند | القيمة |
|---|---|
| المنتج | منصة إدارة الخزينة متعددة المشتركين (BankFas) |
| الإصدار | 0.1 — مسودة للمراجعة |
| التاريخ | $(date -u +%Y-%m-%d) |
| المحتوى | ${#DOCS[@]} مستندًا من سجل المستندات الناقصة بأولوية P0 |
| المصدر | \`docs/30-readiness/\` و\`docs/30-readiness-documents.md\` |
| طريقة القراءة | 🟢 قائم في المستودع أو قرره المالك · 🟡 اقتراح بافتراض يُعتمد أو يُعدَّل · قسم «القرارات المطلوبة» في كل مستند يجمع ما ينتظر قرارًا |

HEAD
python3 - "$SRC" "${DOCS[@]}" >> "$MD" <<'PY'
# Shift every heading of each part down one level (# -> ##); lines inside fenced blocks are left alone.
import re, sys
src, names = sys.argv[1], sys.argv[2:]
for name in names:
    out, fenced = [], False
    for line in open(f'{src}/{name}', encoding='utf-8').read().split('\n'):
        if line.startswith('```'):
            fenced = not fenced
        elif not fenced and re.match(r'#{1,5} ', line):
            line = '#' + line
        out.append(line)
    sys.stdout.write('\n'.join(out) + '\n\n')
PY
"${CONVERT[@]}" "$MD" "$VOLUME" --header "مستندات الجاهزية P0 · BankFas · 0.1 مسودة" --toc-top-only
rm -f "$MD"
echo "built ${#DOCS[@]} documents in $OUT_DIR and the volume $VOLUME"
