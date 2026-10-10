#!/usr/bin/env python3
"""Regenerates docs/10-detailed-analysis/90-consolidated-open-questions.md and 91-requirements-index.md
from the FR-/Q- table rows of module specs 10..14.  Run:  python3 tools/gen_indexes.py"""
import re, glob, collections, os, sys
BASE=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','docs','10-detailed-analysis')
names={'10':'م0/م1 المنصة والهيكل المؤسسي والأشخاص','11':'م2–م4 المنشآت والحسابات والكتالوجات','12':'م5 التسهيلات والتسعير والضمانات والالتزامات','13':'م6 محرك الطلبات والإشعارات','14':'م7/م8 الاعتمادات المستندية'}
FR=collections.defaultdict(list); Q=collections.defaultdict(list)
for f in sorted(glob.glob(os.path.join(BASE,'1[0-4]-*.md'))):
    k=os.path.basename(f)[:2]
    for ln in open(f,encoding='utf-8'):
        if ln.startswith('| FR-') or ln.startswith('| Q-'):
            cells=[c.strip() for c in ln.strip().strip('|').split('|')]
            (FR if ln.startswith('| FR-') else Q)[k].append(cells)
def norm(sl): return sl.strip().split(' ')[0] if sl else sl
out=["# سجل الأسئلة المفتوحة الموحّد","","> مُولَّد آليًا بـ `tools/gen_indexes.py` من القسم 14 في ملفات `10…14` (لا يُعدَّل يدويًا). لكل سؤال **قيمة افتراضية موصى بها**؛ والمحسوم منها يبدأ بـ ✅.","",f"**الإجمالي: {sum(len(v) for v in Q.values())} سؤالًا — المحسوم منها: {sum(1 for v in Q.values() for c in v if len(c)>2 and '✅' in c[2])}.**",""]
for k in sorted(Q):
    out+= [f"## {names[k]} — {len(Q[k])} سؤالًا","","| المعرّف | السؤال | الافتراضي الموصى به |","|---|---|---|"]
    for c in Q[k]: out.append(f"| {c[0]} | {c[1]} | {c[2] if len(c)>2 else ''} |")
    out.append("")
open(os.path.join(BASE,'90-consolidated-open-questions.md'),'w',encoding='utf-8').write('\n'.join(out))
idx=["# فهرس المتطلبات الوظيفية","","> مُولَّد آليًا بـ `tools/gen_indexes.py` من جداول المتطلبات في `10…14`.","",f"**الإجمالي: {sum(len(v) for v in FR.values())} متطلبًا وظيفيًا.**","","## توزيع بحسب الوحدة","","| الوحدة | العدد | Must | Should | Could |","|---|---|---|---|---|"]
for k in sorted(FR):
    pr=collections.Counter(c[2] for c in FR[k] if len(c)>3)
    idx.append(f"| {names[k]} | {len(FR[k])} | {pr['Must']} | {pr['Should']} | {pr['Could']} |")
idx+=["","## توزيع بحسب الشريحة","","| الشريحة | Must | Should | Could | المجموع |","|---|---|---|---|---|"]
sl=collections.defaultdict(collections.Counter)
for k,v in FR.items():
    for c in v:
        if len(c)>3: sl[norm(c[3])][c[2]]+=1
for s_ in sorted(sl,key=lambda x:(x[:2],x)):
    t=sl[s_]; idx.append(f"| {s_} | {t['Must']} | {t['Should']} | {t['Could']} | {sum(t.values())} |")
idx.append("")
for k in sorted(FR):
    idx+= [f"## {names[k]}","","| المعرّف | المتطلب | الأولوية | الشريحة |","|---|---|---|---|"]
    for c in FR[k]:
        if len(c)>3:
            t=c[1].replace('\n',' '); t=t if len(t)<=110 else t[:107]+'…'
            idx.append(f"| {c[0]} | {t} | {c[2]} | {c[3]} |")
    idx.append("")
open(os.path.join(BASE,'91-requirements-index.md'),'w',encoding='utf-8').write('\n'.join(idx))
print('FR',{k:len(v) for k,v in FR.items()},'Q',{k:len(v) for k,v in Q.items()})
