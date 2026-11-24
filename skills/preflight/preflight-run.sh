#!/bin/bash
# preflight 분류 한 번 — 분류 → Workflow 인자 → (선택 0개 커밋이면) 단축 경로 기록을 한 호출로 끝낸다.
#
# 근거: 메인 세션이 게이트마다 classify.sh 를 단독으로 돌린 뒤 같은 인자로 다시 분류(pf_gate_args)하는 턴이 많았다
#   (DECISIONS.md 「분류 한 번 — preflight-run.sh prepare」). 분류를 한 번만 돌리고 그 결과로 다음 행동까지 정한다.
# 절차는 SKILL.md gate-args 블록과 같다 — 그 블록의 pf_gate_args 는 이 스크립트의 gate-args 를 부른다(한 벌).
#   classify.sh 실패면 그 종료코드로 끝나고 stdout 은 비어 있다. classify-sha256 이 없으면 실패(1).
#   데이터 스크립트 폴더는 PF_CLS_DIR, 없으면 대상 레포 gitdir — 작업 트리 안 거부는 cls-data-script.py 가 한다.
# 단축 경로의 대상 조건·판정·기록은 lib.sh 의 pf_fast_* 다(preflight-fast.sh 와 같은 함수).
#
# usage: preflight-run.sh prepare <repo> commit|pr|all [--round=N] [--prior=<findingIds JSON 배열 파일>] [classify.sh 플래그…]
#   --round·--prior 는 여기서 쓰고 classify.sh 에 넘기지 않는다. 나머지 플래그는 그대로 넘긴다(모르는 플래그 거부는 classify.sh).
#   stdout(JSON 한 줄):
#     {"action":"recorded","via":"fast-path","repo","mode":"commit","selected":[],"summary":[…],"next":<커밋 명령 안내>}
#     {"action":"workflow","scriptPath":<preflight.js>,"args":{repo,mode,round,classificationScript,classificationSha256,
#       prBodyFile?,priorFindings?},"selected":[lane…],"summary":[…]}
#   scriptPath 는 심링크를 푼 preflight.js 다. PF_CLS_DIR 가 있으면 그 폴더에 복사한 사본이다(Workflow 가 읽을 수 있는 자리).
# usage: preflight-run.sh gate-args <repo> <classify.sh 인자…>
#   stdout: {classificationScript, classificationSha256} — SKILL.md pf_gate_args 와 같은 출력.
# exit: 0 · 2 인자 거부 · 그 밖은 classify.sh / cls-data-script.py / receipt.sh 의 종료코드
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$P/lib.sh"
usage="usage: preflight-run.sh prepare <repo> commit|pr|all [--round=N] [--prior=<파일>] [classify.sh 플래그…] | gate-args <repo> <classify.sh 인자…>"
sub="${1:-}"; repo="${2:-}"
[ -n "$sub" ] && [ -n "$repo" ] || { echo "$usage" >&2; exit 2; }
shift 2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pf-run.XXXXXX") || exit 2
trap 'rm -rf -- "$tmp"' EXIT

# 분류 한 번. stdout 은 $tmp/cls.json, sha 는 $sha. 실패면 그 코드를 돌려준다.
classify_once() {
    local target="$1" rc; shift
    "$P/classify.sh" "$target" "$@" >"$tmp/cls.json" 2>"$tmp/cls.err"; rc=$?
    sha=$(sed -n 's/^classify-sha256: //p' "$tmp/cls.err" | tail -1)
    grep -v '^classify-sha256: ' "$tmp/cls.err" >&2
    [ "$rc" = 0 ] || { echo "classify.sh 실패(rc=$rc) — args 를 만들지 않는다" >&2; return "$rc"; }
    [ -n "$sha" ] || { echo "classify.sh 가 classify-sha256 을 내지 않았다(분류 파일 쓰기 실패) — args 를 만들지 않는다" >&2; return 1; }
    return 0
}

case "$sub" in
gate-args)
    gd=$(git -C "$repo" rev-parse --absolute-git-dir) || exit 1
    classify_once "$repo" "$@" || exit $?
    python3 "$P/cls-data-script.py" "$repo" "$gd/claude-preflight.classify.json" "$sha" "${PF_CLS_DIR:-$gd}"
    exit $?
    ;;
prepare) ;;
*) echo "$usage" >&2; exit 2 ;;
esac

mode="${1:-}"
case "$mode" in commit|pr|all) shift ;; *) echo "mode 는 commit|pr|all 이다: '${mode}' — $usage" >&2; exit 2 ;; esac
round=1; prior=''; body=''; cls_args=()
for _f in "$@"; do
    case "$_f" in
        --round=*) round="${_f#--round=}"
            case "$round" in ''|0*|*[!0-9]*) echo "--round 는 1 이상의 정수다: '$round'" >&2; exit 2 ;; esac ;;
        --prior=?*) prior="${_f#--prior=}" ;;
        --prior=) echo "--prior 에 파일이 없다" >&2; exit 2 ;;
        *) [ "${_f#--body-file=}" != "$_f" ] && body="${_f#--body-file=}"
           cls_args+=("$_f") ;;
    esac
done
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $repo" >&2; exit 2; }
gd=$(git -C "$top" rev-parse --absolute-git-dir) || exit 1
# --prior 는 분류 전에 읽는다 — 형식이 틀리면 분류를 돌리지 않는다.
if [ -n "$prior" ]; then
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d, list) and all(isinstance(x, str) for x in d), "문자열 배열이 아니다"
json.dump(d, open(sys.argv[2], "w"))' "$prior" "$tmp/prior.json" 2>"$tmp/py.err" \
      || { echo "--prior 파일이 findingIds JSON 배열이 아니다: $prior ($(tail -1 "$tmp/py.err"))" >&2; exit 2; }
fi

classify_once "$top" "$mode" ${cls_args[@]+"${cls_args[@]}"} || exit $?
python3 -c 'import hashlib,sys; sys.exit(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest() != sys.argv[2])' "$tmp/cls.json" "$sha" \
    || { echo "분류 출력이 classify-sha256 과 다르다 — args 를 만들지 않는다" >&2; exit 1; }
pf_fast_plan "$tmp/cls.json" "$tmp/lanes.json" > "$tmp/plan.json" 2>"$tmp/py.err" \
    || { echo "분류 출력을 읽지 못했다 — args 를 만들지 않는다: $(tail -2 "$tmp/py.err")" >&2; exit 1; }

# JSON 한 줄을 낸다 — 경로가 실리므로 lib.sh json-out 규칙(UTF-8 로 못 쓰면 ASCII 이스케이프)을 따른다.
emit() {
    python3 - "$tmp/plan.json" "$@" <<'PY'
import json, os, sys
plan = json.load(open(sys.argv[1]))
kv = dict(a.split('=', 1) for a in sys.argv[2:])
out = {'action': kv['action']}
if kv['action'] == 'recorded':
    out.update(via='fast-path', repo=kv['repo'], mode='commit')
else:
    out['scriptPath'] = kv['scriptPath']
    args = {'repo': kv['repo'], 'mode': kv['mode'], 'round': int(kv['round'])}
    args.update(json.load(open(kv['keys'])))
    if kv.get('body'):
        args['prBodyFile'] = os.path.abspath(kv['body'])
    if kv.get('prior'):
        args['priorFindings'] = json.load(open(kv['prior']))
    out['args'] = args
out['selected'] = plan['selected']
out['summary'] = plan['summary']
if kv['action'] == 'recorded':
    out['next'] = f"git -C '{kv['repo']}' commit 을 별도 Bash 호출로 실행해라 (스테이징과 같은 호출에 넣지 마라)"
# CONTRACT: json-out-is-one-function — 정본은 lib.sh.
try:
    b = json.dumps(out, ensure_ascii=False).encode('utf-8')
except UnicodeEncodeError:
    b = json.dumps(out, ensure_ascii=True).encode('ascii')
sys.stdout.buffer.write(b + b'\n')
PY
}

if pf_fast_eligible "$mode" ${cls_args[@]+"${cls_args[@]}"} \
   && python3 -c 'import json,sys; sys.exit(bool(json.load(open(sys.argv[1]))["selected"]))' "$tmp/plan.json"; then
    pf_fast_record "$top" "$tmp/cls.json" "$tmp/lanes.json" >&2; rc=$?
    [ "$rc" = 0 ] || { echo "단축 경로 기록 거부(rc=$rc) — 위 사유를 보고 고친 뒤 다시 돌려라" >&2; exit "$rc"; }
    emit action=recorded "repo=$top"
    exit $?
fi

dir="${PF_CLS_DIR:-$gd}"
python3 "$P/cls-data-script.py" "$top" "$gd/claude-preflight.classify.json" "$sha" "$dir" > "$tmp/keys.json" || exit $?
wf=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$P/preflight.js") || exit 1
if [ -n "${PF_CLS_DIR:-}" ]; then
    # 데이터 스크립트와 같은 폴더 — 위 cls-data-script.py 가 이 폴더를 이미 검사했다(작업 트리 밖).
    _real=$(cd "$dir" && pwd -P) || exit 1
    cp "$wf" "$_real/.preflight.js.tmp.$$" && mv -f "$_real/.preflight.js.tmp.$$" "$_real/preflight.js" \
        || { rm -f "$_real/.preflight.js.tmp.$$"; echo "preflight.js 를 $dir 에 복사하지 못했다" >&2; exit 1; }
    wf="$_real/preflight.js"
fi
emit action=workflow "repo=$top" "mode=$mode" "round=$round" "scriptPath=$wf" "keys=$tmp/keys.json" \
    "body=$body" "prior=${prior:+$tmp/prior.json}"
