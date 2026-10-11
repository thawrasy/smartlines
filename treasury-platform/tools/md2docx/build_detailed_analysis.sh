#!/usr/bin/env bash
# يجمع ملفات وثيقة التحليل التفصيلية (docs/10-detailed-analysis) بترتيبها في Markdown واحد، ثم يحوّله إلى Word بـ md2docx.
# كل ملف يبقى جزءًا بعنوانه (المستوى الثاني)، وأقسامه تحته، والعنوان العام يأتي من هذا السكربت.
# الاستخدام: tools/md2docx/build_detailed_analysis.sh [ملف_الإخراج.docx]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/docs/10-detailed-analysis"
OUT="${1:-$ROOT/docs/10-DETAILED-ANALYSIS.docx}"
# الترتيب كما تعرضه الوثيقة في القسم 1 (المجموعة) ثم الفهرسان المولَّدان
ORDER=(
  00-overview-and-cross-cutting
  10-m0-m1-platform-organization
  11-m2-m4-institutions-accounts-catalogs
  12-m5-facilities-pricing-collateral-obligations
  13-m6-workflow-engine-notifications
  14-m7-m8-letters-of-credit
  90-consolidated-open-questions
  91-requirements-index
)
# ملف مؤقت يبقى بعد التشغيل ليمكن فحصه؛ لا يُحذف بشكل تلقائي
MD="$(mktemp --suffix=-detailed-analysis.md)"
cat > "$MD" <<'HEAD'
# وثيقة التحليل التفصيلية للنظام

| البند | القيمة |
|---|---|
| المنتج | منصة إدارة الخزينة متعددة المشتركين (BankFas) |
| الإصدار | 0.2 — مسودة للتقييم بعد المراجعة المستقلة وتطبيق التصحيحات |
| التاريخ | 2026-10-10 |
| المحتوى | الإطار العام والمتطلبات المشتركة · المواصفات التفصيلية للوحدات م0 إلى م8 · سجل الأسئلة المفتوحة · فهرس المتطلبات |
| المصدر | `docs/10-detailed-analysis/` (ملفات المواصفة بترتيبها) |

HEAD
python3 - "$SRC" "${ORDER[@]}" >> "$MD" <<'PY'
# يرفع مستوى عناوين كل جزء درجة واحدة (# ← ##)، ولا يمسّ الأسطر داخل الكتل البرمجية
import sys, re
src, names = sys.argv[1], sys.argv[2:]
for name in names:
    text = open(f'{src}/{name}.md', encoding='utf-8').read()
    out, fenced = [], False
    for line in text.split('\n'):
        if line.startswith('```'):
            fenced = not fenced
        elif not fenced and re.match(r'#{1,5} ', line):
            line = '#' + line
        out.append(line)
    sys.stdout.write('\n'.join(out) + '\n\n')
PY
NODE_PATH=/opt/node22/lib/node_modules:/opt/node-tools/node_modules \
  node "$ROOT/tools/md2docx/md2docx.js" "$MD" "$OUT" --header "وثيقة التحليل التفصيلية · BankFas · v0.2 مسودة" --toc-top-only
echo "source: $MD"
