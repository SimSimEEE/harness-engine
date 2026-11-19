#!/bin/bash
# preflight 빈 게이트 단축 경로 — 선택된 lane 이 0개인 커밋을 워크플로 없이 기록한다.
#
# 분류(classify.sh) → 선택 0개 확인 → 기록(receipt.sh record, via fast-path)을 한 호출로 한다.
# 선택이 하나라도 있으면 아무것도 기록하지 않고 exit 10 — 정식 절차(/preflight 워크플로)를 돌린다.
# 기록 판정은 receipt.sh 가 한다: 같은 절차 검사(인덱스·브랜치·모드·HEAD 결속, 시크릿 재스캔, 하네스 뷰)를 지나고,
# via fast-path 로 표시된 기록은 분류의 필수 lane 이 비어 있지 않으면 거부된다(fast-path-not-empty).
# 근거는 DECISIONS.md 「빈 게이트 단축 경로」.
#
# usage: preflight-fast.sh <repo> commit [--msg-file=<커밋 메시지 초안>]
#   pr·all 모드와 --qa·--review·--body-file 은 받지 않는다 — PR 게이트는 pr-quality 가 늘 선택되고,
#   --qa·--review 는 lane 을 고르게 하는 플래그라 선택 0개가 될 수 없다.
# exit: 0 기록됨 · 10 선택된 lane 있음(기록 안 함) · 2 인자 거부 · 그 밖은 classify.sh / receipt.sh 의 종료코드
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${1:-}"; mode="${2:-}"
usage="usage: preflight-fast.sh <repo> commit [--msg-file=<커밋 메시지 초안>]"
[ -n "$repo" ] && [ -n "$mode" ] || { echo "$usage" >&2; exit 2; }
case "$mode" in
    commit) ;;
    pr) echo "단축 경로는 commit 만 받는다 — PR 게이트는 pr-quality 가 늘 선택되어 해당 없다. /preflight pr 절차를 돌려라" >&2; exit 2 ;;
    all) echo "단축 경로는 commit 만 받는다 — all 은 대상이 없어도 lane 을 돌리는 모드다" >&2; exit 2 ;;
    *) echo "모르는 모드: $mode — $usage" >&2; exit 2 ;;
esac
for _f in "${@:3}"; do
    case "$_f" in
        --msg-file=?*) ;;
        --qa|--review) echo "단축 경로는 $_f 를 받지 않는다 — lane 을 고르게 하는 플래그라 선택 0개가 될 수 없다. /preflight 절차를 돌려라" >&2; exit 2 ;;
        --body-file=*) echo "단축 경로는 --body-file 을 받지 않는다 — PR 본문은 PR 게이트의 입력이다" >&2; exit 2 ;;
        *) echo "알 수 없는 플래그: '$_f' — $usage" >&2; exit 2 ;;
    esac
done
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $repo" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pf-fast.XXXXXX") || exit 2
trap 'rm -rf -- "$tmp"' EXIT
"$P/classify.sh" "$top" commit "${@:3}" >"$tmp/cls.json" 2>"$tmp/cls.err"; rc=$?
grep -v '^classify-sha256: ' "$tmp/cls.err" >&2
[ "$rc" = 0 ] || { echo "classify.sh 실패(rc=$rc) — 기록하지 않는다" >&2; exit "$rc"; }

# 분류에서 요약과 기록 입력을 만든다. stdout 셋째 줄부터가 요약, 첫 줄은 결정(record|selected)이다.
python3 - "$tmp/cls.json" "$tmp/lanes.json" > "$tmp/plan.txt" 2>"$tmp/py.err" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
sel = list(c.get('selected') or {})
for chain in (c.get('sequential') or []):
    sel += [l for l in chain if l not in sel]
ss = c.get('secretScan') or {}
cc = c.get('claimCheck') or {}
lines = [f"카테고리: {c.get('category')} · 시크릿 스캔: {ss.get('status')} ({ss.get('mode')}) · 변경 파일 {len((c.get('files') or {}).get('all') or [])}개"]
if cc.get('status') == 'WARN':
    n = (cc.get('counts') or {}).get('warn')
    lines.append(f"사실 주장 검사: WARN {n}건 — 판정에는 영향 없다(참고). 출처 없는 수치는 커밋 전에 고쳐라")
if sel:
    print('selected')
    lines.append(f"선택된 lane: {', '.join(sel)} — 기록하지 않았다. 정식 절차(/preflight 워크플로)를 돌려라")
else:
    print('record')
    ns = c.get('notSelected') or {}
    json.dump({l: {'status': 'SKIPPED', 'reason': str(r)} for l, r in sorted(ns.items())},
              open(sys.argv[2], 'w'), ensure_ascii=False)
    lines.append(f"선택된 lane 없음 — 전부 SKIPPED({len(ns)}개, 사유는 분류의 notSelected)")
print('\n'.join(lines))
PY
[ $? = 0 ] || { echo "분류 출력을 읽지 못했다 — 기록하지 않는다: $(tail -2 "$tmp/py.err")" >&2; exit 1; }
decision=$(head -1 "$tmp/plan.txt")
tail -n +2 "$tmp/plan.txt"
if [ "$decision" != record ]; then
    exit 10
fi
PF_RECORD_VIA=fast-path "$P/receipt.sh" record commit "$top" "@$tmp/lanes.json" "@$tmp/cls.json"; rc=$?
if [ "$rc" = 0 ]; then
    echo "이제 \`git -C '$top' commit\` 을 별도 Bash 호출로 실행해라 (스테이징과 같은 호출에 넣지 마라)"
else
    echo "기록 거부(rc=$rc) — 위 사유를 보고 고친 뒤 다시 돌려라" >&2
fi
exit "$rc"
