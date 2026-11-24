#!/bin/bash
# preflight 빈 게이트 단축 경로 — 선택된 lane 이 0개인 커밋을 워크플로 없이 기록한다.
#
# 분류(classify.sh) → 선택 0개 확인 → 기록(receipt.sh record, via fast-path)을 한 호출로 한다.
# 선택이 하나라도 있으면 아무것도 기록하지 않고 exit 10 — 정식 절차(/preflight 워크플로)를 돌린다.
# 기록 판정은 receipt.sh 가 한다: 같은 절차 검사(인덱스·브랜치·모드·HEAD 결속, 시크릿 재스캔, 하네스 뷰)를 지나고,
# via fast-path 로 표시된 기록은 분류의 필수 lane 이 비어 있지 않으면 거부된다(fast-path-not-empty).
# 근거는 DECISIONS.md 「빈 게이트 단축 경로」. 대상 조건·판정·기록은 lib.sh 의 pf_fast_* 이고 preflight-run.sh prepare 도 같은 함수를 쓴다.
#
# usage: preflight-fast.sh <repo> commit [--msg-file=<커밋 메시지 초안>]
#   pr·all 모드와 --qa·--review·--body-file 은 받지 않는다 — PR 게이트는 pr-quality 가 늘 선택되고,
#   --qa·--review 는 lane 을 고르게 하는 플래그라 선택 0개가 될 수 없다.
# exit: 0 기록됨 · 10 선택된 lane 있음(기록 안 함) · 2 인자 거부 · 그 밖은 classify.sh / receipt.sh 의 종료코드
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$P/lib.sh"
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
pf_fast_eligible "$mode" "${@:3}" || { echo "단축 경로 대상이 아니다 — $usage" >&2; exit 2; }
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $repo" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pf-fast.XXXXXX") || exit 2
trap 'rm -rf -- "$tmp"' EXIT
"$P/classify.sh" "$top" commit "${@:3}" >"$tmp/cls.json" 2>"$tmp/cls.err"; rc=$?
grep -v '^classify-sha256: ' "$tmp/cls.err" >&2
[ "$rc" = 0 ] || { echo "classify.sh 실패(rc=$rc) — 기록하지 않는다" >&2; exit "$rc"; }

# 판정·기록은 lib.sh 의 pf_fast_plan·pf_fast_record 다 — preflight-run.sh prepare 와 같은 함수를 쓴다.
pf_fast_plan "$tmp/cls.json" "$tmp/lanes.json" > "$tmp/plan.json" 2>"$tmp/py.err" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("selected" if d["selected"] else "record"); print("\n".join(d["summary"] + [d["tail"]]))' "$tmp/plan.json" > "$tmp/plan.txt" 2>>"$tmp/py.err"
[ $? = 0 ] || { echo "분류 출력을 읽지 못했다 — 기록하지 않는다: $(tail -2 "$tmp/py.err")" >&2; exit 1; }
decision=$(head -1 "$tmp/plan.txt")
tail -n +2 "$tmp/plan.txt"
if [ "$decision" != record ]; then
    exit 10
fi
pf_fast_record "$top" "$tmp/cls.json" "$tmp/lanes.json"; rc=$?
if [ "$rc" = 0 ]; then
    echo "이제 \`git -C '$top' commit\` 을 별도 Bash 호출로 실행해라 (스테이징과 같은 호출에 넣지 마라)"
else
    echo "기록 거부(rc=$rc) — 위 사유를 보고 고친 뒤 다시 돌려라" >&2
fi
exit "$rc"
