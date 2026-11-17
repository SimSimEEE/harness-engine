#!/bin/bash
# 사실 주장 검사 픽스처 실행기 — 픽스처마다 입력 레포를 만들고 PR 모드(merge-base..HEAD + 커밋 메시지)로
# claim-verify.sh 를 돌려 expect.json 과 rule 별 개수를 대조한다. 결정론이라 한 번이면 된다.
#
# usage: run.sh [--verify <claim-verify.sh>] [fixture...]
#   --verify 를 주면 그 검사기로 돈다 (meta-test 가 설치본·변이본을 넘긴다). 기본은 이 레포의 것.
# exit: 하나라도 어긋나면 1.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CV="$(dirname "$(dirname "$SELF")")/claim-verify.sh"
[ "${1:-}" = "--verify" ] && { CV="$2"; shift 2; }
if [ $# -gt 0 ]; then names=("$@")
else names=(); for f in "$SELF"/[!_]*.sh; do n="$(basename "$f" .sh)"; [ "$n" = run ] || names+=("$n"); done
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 검증된 샌드박스가 없는 플랫폼(macOS·Linux bwrap 밖)에서 검사기는 어떤 명령도 실행하지 않는다(DECISIONS.md 의 OS 샌드박스 항).
# 그때는 픽스처의 "nobox" 기대로 대조한다 — 실행 결과에 기대는 rule 이 claim/unverifiable 로 떨어지고 실행이 0 건임을 고정한다.
BOX=0; [ -n "$("$CV" --sandbox-profile 2>/dev/null)" ] && BOX=1
bad=0
for n in "${names[@]}"; do
    fx="$SELF/$n.sh"
    [ -f "$fx" ] || { echo "  ❌ $n — 없는 픽스처"; bad=1; continue; }
    if ! bash "$fx" "$T/$n" >/dev/null 2>"$T/$n.err"; then
        echo "  ❌ $n — 입력 생성 실패: $(tail -1 "$T/$n.err")"; bad=1; continue
    fi
    r="$T/$n/r"
    mb=$(git -C "$r" merge-base origin/develop HEAD)
    "$CV" --json --repo "$r" --from "$mb" --commits "$mb..HEAD" > "$T/$n.out" 2>"$T/$n.cverr"
    python3 - "$T/$n.out" "$T/$n/expect.json" "$n" "$BOX" <<'PY' || bad=1
import json, sys, collections
try:
    got = json.load(open(sys.argv[1])); exp = json.load(open(sys.argv[2]))
except Exception as e:
    print(f'  ❌ {sys.argv[3]} — 결과를 못 읽었다: {e}'); sys.exit(1)
nobox = sys.argv[4] != '1'
tag = ''
if nobox and 'nobox' in exp:
    exp = {**exp, **exp['nobox']}; tag = ' (샌드박스 없음 — 실행하지 않는 기대)'
ran = sum(1 for f in got['findings'] for c in f.get('commands', []) if c.get('ran'))
cnt = {sev: collections.Counter(f['rule'] for f in got['findings'] if f['severity'] == sev) for sev in ('warn', 'info')}
diffs = []
for sev in ('warn', 'info'):
    if dict(cnt[sev]) != exp[sev]:
        diffs.append(f'{sev} 기대 {exp[sev]} · 실제 {dict(cnt[sev])}')
if got['counts']['verified'] != exp['verified']:
    diffs.append(f"verified 기대 {exp['verified']} · 실제 {got['counts']['verified']}")
if any(f.get('blocking') for f in got['findings']):
    diffs.append('blocking 지적이 있다 — 이 검사기는 막지 않는다')
if nobox and ran:
    diffs.append(f'샌드박스가 없는데 명령 {ran} 건을 실행했다')
if diffs:
    print(f'  ❌ {sys.argv[3]}{tag} — ' + ' / '.join(diffs)); sys.exit(1)
print(f'  ✅ {sys.argv[3]}{tag}')
PY
done
exit $bad
