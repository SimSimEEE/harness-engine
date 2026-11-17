#!/bin/bash
# 레포별 프로필 생성 — 처음 보는 레포(프로필 없음)의 카테고리를 사용자가 확인한 뒤 프로필로 고정한다 (#47).
#
# 자동으로 부르지 않는다. 요청 시점 훅(hooks/category-context.sh)은 이 명령을 **안내만** 한다 — 사용자가
# 추론 카테고리를 확인한 뒤에 실행한다.
#
# 판정하지 않는다. 카테고리·origin 슬러그·기존 프로필은 category.sh(= classify.sh category 모드)의 출력을 쓴다.
# 프로필은 신호 추론을 **고정**할 뿐이라(DECISIONS F2·F3·F4) 추론과 다른 카테고리, 카테고리 없음, 겹침은 만들지 않는다 —
# 만들면 그 순간부터 그 레포의 분류·조회가 exit 3 이 된다.
# 쓴 뒤에는 실제 적재기(category.sh)로 다시 조회해 이 파일이 그 레포의 프로필로 읽히는지 확인한다. 아니면 쓴 파일을 지운다 —
# 프로필 하나라도 적재에 실패하면 어느 레포도 분류되지 않는다(F6).
#
# 생성 파일: <이 디렉터리>/profiles/<owner>/<repo>.json (origin 슬러그 소문자)
#   {"repo": <origin 슬러그 원문>, "category": <추론>, "engineVersion": <ENGINE_VERSION>, "adjustments": [] 또는 --adjustments 파일}
#   engineVersion 의 검증·호환 검사는 적재기의 몫이다. 여기서는 lib.sh pf_engine_version 의 값을 적기만 한다.
#
# usage: profile.sh init <repo> [--category <이름>] [--adjustments <파일>]
#   --category 는 확인의 명시다. 추론과 다르면 만들지 않는다.
#   --adjustments 는 사용자가 승인한 조정 항목의 JSON 목록이다(profile-measure.sh select 가 낸다).
#     항목 형식은 여기서 검사하지 않는다 — 쓴 뒤 적재기가 거부하면 아래 확인이 지운다(형식의 정본은 적재기 하나).
#   stdout : 생성한 파일 경로와 다음 할 일
#   exit   : 0 생성 · 2 인자 오류 · 3 만들지 않음(origin 없음·카테고리 없음/겹침/불일치·이미 있음·엔진 버전 못 읽음·적재 확인 실패)
#            143 등 시그널로 끊김(쓴 파일은 지운다)
set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELFDIR/lib.sh"

usage(){ echo "usage: profile.sh init <repo> [--category <이름>] [--adjustments <파일>]" >&2; exit 2; }
refuse(){ printf '프로필을 만들지 않는다 — %s\n' "$1" >&2; exit 3; }

[ "${1:-}" = init ] || usage
[ $# -ge 2 ] && [ -n "$2" ] || usage
repo_arg=$2; want=''; adj_file=''
shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --category) [ $# -ge 2 ] && [ -n "$2" ] || usage; want=$2; shift 2 ;;
        --adjustments) [ $# -ge 2 ] && [ -n "$2" ] || usage; adj_file=$2; shift 2 ;;
        *) usage ;;
    esac
done

repo=$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $repo_arg" >&2; exit 2; }
# 조정 목록은 목록인지만 본다 — 항목 형식은 적재기가 판정한다(쓴 뒤 확인 단계).
adj='[]'
if [ -n "$adj_file" ]; then
    adj=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(d, list):
    sys.exit(4)
print(json.dumps(d, ensure_ascii=False))' "$adj_file" 2>/dev/null) || refuse "--adjustments $adj_file 은 JSON 목록이어야 한다"
fi

err=$(mktemp "${TMPDIR:-/tmp}/pfprof.XXXXXX") || exit 2
trap 'rm -f -- "$err"' EXIT
out=$(bash "$SELFDIR/category.sh" "$repo" 2>"$err"); rc=$?
if [ "$rc" -ne 0 ]; then
    first=$(head -1 "$err")
    case "$first" in
        "카테고리 판정이 겹친다"*) refuse "카테고리 겹침은 프로필로 풀지 않는다. 표식 하나를 정리한 뒤 다시 실행한다: $first" ;;
        *) refuse "조회가 실패했다(exit $rc): $first" ;;
    esac
fi

# 조회 출력에서 필요한 값만 뽑는다. 한 줄에 하나씩: origin, category, profile 경로(없으면 빈 줄).
vals=$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "origin" not in d:
    sys.exit(4)
p = d.get("profile") or {}
for v in (d.get("origin") or "", d.get("category") or "", p.get("path") or ""):
    sys.stdout.buffer.write(str(v).encode("utf-8", "surrogateescape") + b"\n")
') || refuse "조회 출력을 읽지 못했다(origin 키가 없는 옛 category.sh 일 수 있다)"
{ IFS= read -r slug; IFS= read -r cat; IFS= read -r have; } <<< "$vals"

[ -n "$have" ] && refuse "이미 프로필이 있다: $have"
[ -n "$slug" ] || refuse "origin 리모트가 없어 프로필 키(<owner>/<repo>)를 정할 수 없다. origin 을 추가한 뒤 다시 실행한다"
[ -n "$cat" ] || refuse "$slug 는 어느 카테고리 표식에도 걸리지 않는다. 프로필은 신호 추론을 고정할 뿐이라 카테고리 없는 레포에는 만들지 않는다"
[ -z "$want" ] || [ "$want" = "$cat" ] \
    || refuse "--category $want 는 추론 카테고리 $cat 와 다르다. 프로필이 추론과 다르면 그 레포는 분류되지 않는다 — 신호(표식)를 먼저 고친다"
ver=$(pf_engine_version)
[ -n "$ver" ] || refuse "엔진 버전($SELFDIR/ENGINE_VERSION)을 읽지 못했다"

rel=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]').json
# 오버레이가 설정돼 있으면 프로필은 오버레이의 profiles/ 에 쓴다 — 엔진 체크아웃(공개)에 레포 정보를 남기지 않는다.
ov=$(pf_overlay_dir)
PROOT="${ov:+$ov/profiles}"; PROOT="${PROOT:-$SELFDIR/profiles}"
dest="$PROOT/$rel"
for _other in "$SELFDIR/profiles/$rel" "${ov:+$ov/profiles/$rel}"; do
    [ -n "$_other" ] && [ "$_other" != "$dest" ] && [ -e "$_other" ] && refuse "$_other 가 이미 있다 — 프로필은 엔진과 오버레이 중 한 곳에만 둔다"
done
[ -e "$dest" ] && refuse "$dest 가 이미 있다(조회는 이 레포의 프로필로 읽지 않았다 — 파일을 확인한다)"
# 이 실행이 새로 만든 디렉터리(owner, 그리고 없었다면 profiles/) — 롤백 때 이것만 지운다.
new_dirs=()
[ -d "$PROOT" ] || new_dirs+=("$PROOT")
# macOS bash 3.2 는 set -u 에서 빈 배열 "${a[@]}" 를 unbound 로 본다 — ${a[@]+…} 로 감싼다.
[ -d "$(dirname "$dest")" ] || new_dirs=("$(dirname "$dest")" ${new_dirs[@]+"${new_dirs[@]}"})

# 롤백은 EXIT trap 에 묶는다 — 디렉터리를 만들 때부터 확인이 끝날 때까지 끊기거나 확인이 실패하면 남기지 않는다.
# bash 는 TERM 으로 끝날 때도 EXIT trap 을 돈다(meta-test PI9 가 고정 — 시그널마다 trap 을 따로 걸어도 결과가 같아 걸지 않았다).
# 남으면 적재기가 거부하는 파일 하나로 모든 레포의 분류가 멈춘다(F6).
# 내용은 숨김 임시 파일에 쓰고(적재기는 . 으로 시작하는 파일을 읽지 않는다 — 덜 쓴 파일이 보이지 않는다) ln 으로 한 번에 건다.
# ln 은 대상이 있으면 실패한다 — 남의 파일을 덮지 않는다. 임시 파일은 확인이 끝날 때까지 두고, 롤백은 dest 가 임시 파일과
# 같은 inode(-ef)일 때만 지운다 — 이 실행이 건 파일만 지우고, 걸기 전·ln 실패 때 그 자리에 있는 남의 파일은 두며, 플래그 없이
# ln 직후의 끊김도 덮는다. 확인을 통과하면 written 을 내려 trap 이 지우지 않게 한 뒤 임시 파일을 지운다.
tmp="$(dirname "$dest")/.$(basename "$dest").$$.tmp"
_rmdirs(){ local d; for d in ${new_dirs[@]+"${new_dirs[@]}"}; do rmdir -- "$d" 2>/dev/null; done; return 0; }
_undo(){ [ "$dest" -ef "$tmp" ] && rm -f -- "$dest"; rm -f -- "$tmp"; _rmdirs; }
written=1
trap 'rm -f -- "$err"; [ -n "$written" ] && _undo' EXIT
mkdir -p "$(dirname "$dest")" || refuse "$(dirname "$dest") 를 만들지 못했다"
SLUG="$slug" CAT="$cat" VER="$ver" ADJ="$adj" python3 -c '
import json, os, sys
d = {"repo": os.environ["SLUG"], "category": os.environ["CAT"], "engineVersion": os.environ["VER"],
     "adjustments": json.loads(os.environ["ADJ"])}
with open(sys.argv[1], "x", encoding="utf-8") as f:
    f.write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
' "$tmp" || refuse "$tmp 를 쓰지 못했다"
ln -- "$tmp" "$dest" 2>/dev/null || refuse "$dest 를 걸지 못했다(그 사이 같은 자리에 파일이 생겼을 수 있다 — 확인한다)"

# 적재기로 확인한다 — 이 레포의 조회가 방금 쓴 파일을 프로필로 읽어야 한다. 실패하면 exit 의 trap 이 지운다.
# 한계: 건 뒤 확인까지 짧은 구간에는 동시에 도는 조회·게이트가 이 파일을 본다. 적재기가 거부할 파일이면 그 구간 동안 적재 실패다.
chk=$(bash "$SELFDIR/category.sh" "$repo" 2>"$err"); rc=$?
[ "$rc" -eq 0 ] || refuse "적재기가 새 프로필을 받지 않아 지웠다(exit $rc): $(head -1 "$err")"
got=$(printf '%s' "$chk" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("profile") or {}).get("path") or "")' 2>/dev/null)
[ "$got" = "profiles/$rel" ] || refuse "다시 조회해도 새 프로필로 읽히지 않아 지웠다(읽힌 프로필: ${got:-없음})"
written=''
rm -f -- "$tmp"

printf '프로필 생성: %s\n' "$dest"
nadj=$(printf '%s' "$adj" | python3 -c 'import json,sys; a=json.load(sys.stdin); print(", ".join(x.get("id","?") for x in a) or "없음")')
printf '  repo %s · category %s · engineVersion %s · adjustments %s\n' "$slug" "$cat" "$ver" "$nadj"
printf '  다른 설치본에 퍼지려면 이 파일을 담은 레포(오버레이 또는 엔진)에 커밋한다.\n'
