#!/usr/bin/env bash
# Builds the readiness documents (docs/30-readiness/DOC-*.md) into Word:
#   - one .docx per document in docs/30-readiness/word/
#   - one combined volume per priority group, every document in register order (DOC-F, DOC-S, DOC-B):
#       P0     -> docs/30-READINESS-P0.docx     (before slice S0)
#       P1P2   -> docs/30-READINESS-P1-P2.docx  (P1 before S2/S3, P2 before launch)
#     A document's group comes from the "الأولوية" row of its metadata table.
# Diagrams: set MMDC to the mermaid-cli binary (and MMDC_PUPPETEER to its puppeteer config when Chromium needs flags);
# without MMDC the Mermaid blocks stay as code, which is not fit for review, so the script refuses to run.
# Usage: MMDC=/path/to/mmdc [MMDC_PUPPETEER=/path/to/pp.json] [BUILD_GROUPS="P0 P1P2"] tools/md2docx/build_readiness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/docs/30-readiness"
OUT_DIR="$SRC/word"
BUILD_GROUPS="${BUILD_GROUPS:-P0 P1P2}"
: "${MMDC:?set MMDC to the mermaid-cli binary (mmdc) so diagrams are rendered as pictures}"
export MMDC
# docx and jszip: added to any NODE_PATH already set (some environments preset it to another folder)
export NODE_PATH="${NODE_PATH:+$NODE_PATH:}/opt/node22/lib/node_modules:/opt/node-tools/node_modules"
CONVERT=(node "$ROOT/tools/md2docx/md2docx.js")
mkdir -p "$OUT_DIR"

# Register order: DOC-F, then DOC-S, then DOC-B, each by number.
mapfile -t ALL < <(cd "$SRC" && for p in 'DOC-F*.md' 'DOC-S*.md' 'DOC-B*.md'; do ls $p 2>/dev/null; done)
[ "${#ALL[@]}" -gt 0 ] || { echo "no DOC-*.md in $SRC"; exit 1; }

group_of() {   # P0 or P1P2, from the priority row of the metadata table
    if grep -m1 '^| الأولوية |' "$SRC/$1" | grep -q 'P0'; then echo P0; else echo P1P2; fi
}

build_group() {   # $1 = P0 | P1P2
    local g="$1" volume title scope label
    case "$g" in
        P0)   volume="$ROOT/docs/30-READINESS-P0.docx"; label="P0"
              title="مستندات الجاهزية للتنفيذ — المجموعة P0 (قبل S0)"; scope="بأولوية P0" ;;
        P1P2) volume="$ROOT/docs/30-READINESS-P1-P2.docx"; label="P1 وP2"
              title="مستندات الجاهزية للتنفيذ — المجموعتان P1 (قبل S2 وS3) وP2 (قبل الإطلاق)"; scope="بأولوية P1 وP2" ;;
        *) echo "unknown group $g"; exit 2 ;;
    esac
    local docs=()
    for f in "${ALL[@]}"; do [ "$(group_of "$f")" = "$g" ] && docs+=("$f"); done
    [ "${#docs[@]}" -gt 0 ] || { echo "group $g: no documents"; return; }

    for f in "${docs[@]}"; do
        "${CONVERT[@]}" "$SRC/$f" "$OUT_DIR/${f%.md}.docx" --header "${f:0:7} · BankFas · مستندات الجاهزية $label · 0.1 مسودة"
    done

    # Combined volume: each document becomes one part (its headings move down one level).
    local md
    md="$(mktemp --suffix=-readiness.md)"
    cat > "$md" <<HEAD
# $title

| البند | القيمة |
|---|---|
| المنتج | منصة إدارة الخزينة متعددة المشتركين (BankFas) |
| الإصدار | 0.1 — مسودة للمراجعة |
| التاريخ | $(date -u +%Y-%m-%d) |
| المحتوى | ${#docs[@]} مستندًا من سجل المستندات الناقصة $scope |
| المصدر | \`docs/30-readiness/\` و\`docs/30-readiness-documents.md\` |
| طريقة القراءة | 🟢 قائم في المستودع أو قرره المالك · 🟡 اقتراح بافتراض يُعتمد أو يُعدَّل · قسم «القرارات المطلوبة» في كل مستند يجمع ما ينتظر قرارًا |

HEAD
    python3 - "$SRC" "${docs[@]}" >> "$md" <<'PY'
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
    "${CONVERT[@]}" "$md" "$volume" --header "مستندات الجاهزية $label · BankFas · 0.1 مسودة" --toc-top-only
    rm -f "$md"
    echo "group $g: built ${#docs[@]} documents in $OUT_DIR and the volume $volume"
}

for g in $BUILD_GROUPS; do build_group "$g"; done
