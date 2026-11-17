#!/bin/bash
# UserPromptSubmit — 요청마다 현재 작업 레포의 하네스 카테고리·절차를 짧게 컨텍스트로 넣는다 (#47).
#
# 판정하지 않는다. `skills/preflight/category.sh <레포>` 의 결과를 옮겨 적을 뿐이다 — 따로 판정하면
# 이 표시와 게이트가 다른 카테고리를 말하게 된다. 레포는 훅 입력의 cwd 가 속한 git 레포다.
#
# 출력(stdout 은 Claude 컨텍스트에 붙는다):
#   카테고리 있음  "[하네스 카테고리] <레포>: <이름> (근거: …)" + 절차 줄
#     + 프로필이 없으면(처음 보는 레포) 한 줄 더:
#       origin 있음  "  프로필 없음 — 추론 카테고리 <이름>(근거: …) — 사용자가 확인하면 `/harness-profile`(…),
#                     조정 없이 바로 만들려면 `bash …/profile.sh init <레포>`"
#       origin 없음  "  프로필 없음 — origin 리모트가 없어 프로필 키를 정할 수 없다(만들지 않는다)"
#     프로필을 쓰지 않는다. 생성은 사용자 확인 뒤 생성기 스킬 harness-profile(이력 실측·승인 → profile.sh init --adjustments)
#     이나 profile.sh init 직접 실행(조정 없음)이 한다. profile.sh 가 설치본에 없으면 이 줄을 내지 않는다.
#   카테고리 없음  "[하네스 카테고리] <레포>: 없음 …"
#   겹침(exit 3)   "[하네스 카테고리] <레포>: 겹침 — <category.sh stderr 첫 줄>"
#   그 밖의 exit 3(카테고리 적재 실패)  "[하네스 카테고리] <레포>: 분류 불가 — <stderr 첫 줄>"
#   그 밖(git 레포 아님·조회 실패·파싱 실패)  아무것도 내지 않는다
#
# CONTRACT: category-hook-fail-open
# **언제나 exit 0 이다.** UserPromptSubmit 에서 exit 2 는 사용자 요청을 막는다. 이 훅은 안내일 뿐이라
# 무엇이 실패해도 요청을 막지 않는다. 오류는 stdout 에 싣지 않는다(컨텍스트에 잡음이 된다).
set -u
trap 'exit 0' EXIT

# 설치 루트는 이 스크립트의 부모 — ~/.claude 설치본과 플러그인 설치본이 같은 배치다(preflight-gate.sh 와 같다).
# PF_ROOT 는 메타테스트가 설치 고장(category.sh 없음)을 흉내 낼 때 쓰는 override 다.
PF_ROOT="${PF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
CS="$PF_ROOT/skills/preflight/category.sh"
[ -f "$CS" ] || exit 0

input=$(cat 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    sys.stdout.buffer.write(str(json.load(sys.stdin).get("cwd") or "").encode("utf-8", "surrogateescape"))
except Exception:
    pass
' 2>/dev/null) || exit 0
[ -n "$cwd" ] || cwd=$PWD
repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0

err=$(mktemp "${TMPDIR:-/tmp}/cathook.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -f -- "$err"; exit 0' EXIT
out=$(bash "$CS" "$repo" 2>"$err"); rc=$?

# exit 3 은 겹침과 카테고리 적재 실패 둘 다다(classify.sh _cat_fail). stderr 첫 줄로 가른다 — 겹침 문구가 아니면
# 겹침이라고 하지 않는다(표식을 정리하라는 조치가 틀린 조치가 된다).
if [ "$rc" -eq 3 ]; then
    first=$(head -1 "$err")
    case "$first" in
        "카테고리 판정이 겹친다"*) label="겹침"; act="표식 하나를 정리하거나 사용자에게 알린다." ;;
        *) label="분류 불가"; act="설치본의 skills/preflight/categories 를 점검하거나 사용자에게 알린다." ;;
    esac
    printf '[하네스 카테고리] %s: %s — %s\n' "$repo" "$label" "$first"
    printf '  게이트(classify.sh)도 이 레포를 분류하지 않는다. %s\n' "$act"
    exit 0
fi
[ "$rc" -eq 0 ] || exit 0

# 바이트로 쓴다 — 비UTF-8 경로가 strict stdout 에서 print 를 죽이지 않게(preflight-gate.sh 의 hook-emits-bytes-not-str 와 같은 이유).
PS="$PF_ROOT/skills/preflight/profile.sh"; [ -f "$PS" ] || PS=''
printf '%s' "$out" | PS="$PS" python3 -c '
import sys, json, os, shlex
def emit(s):
    sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape") + b"\n")
d = json.load(sys.stdin)
repo, cat = d.get("repo"), d.get("category")
if not cat:
    emit(f"[하네스 카테고리] {repo}: 없음 — 어느 카테고리 표식에도 걸리지 않는다")
    sys.exit(0)
ev = ", ".join(d.get("evidence", {}).get(cat, []))
emit(f"[하네스 카테고리] {repo}: {cat} (근거: {ev})")
procs = d.get("procedures") or []
if not procs:
    emit("  카테고리 절차: 없음")
for p in procs:
    emit("  절차 " + str(p.get("id")) + ": " + str(p.get("text")))
# 처음 보는 레포 — 안내만 한다. "origin" 키가 없는 조회 출력(옛 설치본)은 판단 근거가 없어 내지 않는다.
ps = os.environ.get("PS")
if ps and "origin" in d and not d.get("profile"):
    if d["origin"]:
        cmd = "bash " + shlex.quote(ps) + " init " + shlex.quote(repo)
        emit(f"  프로필 없음 — 추론 카테고리 {cat}(근거: {ev}) — 사용자가 확인하면 `/harness-profile`(이력 실측·규칙 승인 뒤 생성), 조정 없이 바로 만들려면 `{cmd}` (확인 없이 실행하지 않는다)")
    else:
        emit("  프로필 없음 — origin 리모트가 없어 프로필 키를 정할 수 없다(만들지 않는다)")
' 2>/dev/null
exit 0
