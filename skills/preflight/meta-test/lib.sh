#!/bin/bash
# meta-test 공용 머리 — meta-test.sh 가 source 한다. 단독 실행하지 않는다.
# 설치본·워킹트리 대조값, 임시 디렉터리($T)와 로그 격리, 단언 헬퍼(ok·ng·_diag·_pytb·nocc), 공용 픽스처 레포($repo)를 만든다.
# MT_DIR(skills/preflight 의 실제 경로)과 MT_FILES(source 할 파일 목록)는 드라이버가 정하고, MT_ALL(그 파일들을 이은 사본)은 여기서 만든다.
: "${MT_DIR:?meta-test.sh 가 source 해야 한다}" "${MT_FILES:?meta-test.sh 가 source 해야 한다}"

# 이 스위트는 대부분 **설치본**($HOME/.claude)을 검사한다 — 훅과 스킬은 실제로 그것이 실행된다.
# lane 계약 검사만 레포 판($MT_DIR)이다. 둘이 갈리면 무엇을 검증했는지 알 수 없으므로 먼저 밝힌다.
# 경로 계산으로 레포를 추정하면 --copy 설치본에서 `$HOME/.claude` 를 레포로 착각해
# 자기 자신을 비교하고 늘 통과한다. git 이 답하게 한다.
_mt_repo="$(git -C "$MT_DIR" rev-parse --show-toplevel 2>/dev/null || echo '')"
_mt_drift=""
# **목록을 손으로 적지 않는다.** 이 가드 자체가 열거를 고치려고 쓴 것인데 5개만 적어
# preflight.js·lib.sh 를 빠뜨렸다. 대상은 git 이 답한다 — 파일이 늘어도 따라간다.
# config.json 과 .qa-endpoints.json 은 설치 시 생성되는 로컬 파일이라 제외한다.
if [ -n "$_mt_repo" ]; then
    # `-z` 로 받는다. 기본 출력은 비ASCII 경로를 따옴표+8진 이스케이프로 내놓고, 워드
    # 스플릿은 공백까지 가른다 — 둘 다 없는 파일로 읽혀 **가짜 drift** 를 만든다.
    # 오버레이(드라이버의 MT_OVERLAY)가 같은 경로를 가지면 설치본은 오버레이 것이다 — 그쪽과 비교한다.
    while IFS= read -r -d '' _f; do
        case "$_f" in *config.json|*.qa-endpoints.json) continue ;; esac
        _src="$_mt_repo/$_f"
        [ -n "${MT_OVERLAY:-}" ] && [ -e "$MT_OVERLAY/$_f" ] && _src="$MT_OVERLAY/$_f"
        [ -e "$HOME/.claude/$_f" ] || { _mt_drift="$_mt_drift $_f(없음)"; continue; }
        diff -q "$_src" "$HOME/.claude/$_f" >/dev/null 2>&1 || _mt_drift="$_mt_drift $_f"
    done < <(git -C "$_mt_repo" ls-files -z agents hooks skills 2>/dev/null)
    if [ -n "${MT_OVERLAY:-}" ] && git -C "$MT_OVERLAY" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r -d '' _f; do
            [ -e "$HOME/.claude/$_f" ] || { _mt_drift="$_mt_drift $_f(없음)"; continue; }
            diff -q "$MT_OVERLAY/$_f" "$HOME/.claude/$_f" >/dev/null 2>&1 || _mt_drift="$_mt_drift $_f"
        done < <(git -C "$MT_OVERLAY" ls-files -z agents hooks skills 2>/dev/null)
    fi
fi
R="$HOME/.claude/skills/preflight/receipt.sh"
H="$HOME/.claude/hooks/preflight-gate.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 파일 전체를 세는 형태 가드(출력 유무 판정·py.err 짝 등)는 이 사본을 센다 — 테스트가 여러 파일로 나뉘어도
# 한 파일만 세고 나머지를 놓치지 않게. 목록은 드라이버가 실제로 source 하는 파일 그대로다.
MT_ALL="$T/meta-test.all.sh"; cat "${MT_FILES[@]}" > "$MT_ALL"
# CONTRACT: suite-log-isolated
# 스위트 **전체**를 실 로그에서 격리한다. 개별 단언이 자기 PF_LOG 를 지정하는 것은 그대로 동작한다.
# 줄마다 붙이는 방식은 절 안에서 절반만 적용돼 fixture 이벤트가 실 로그에 쌓였다 (실측 47/436).
export PF_LOG="$T/pf.jsonl"
# vault 대기 목록도 같다 — PR 게이트 기록이 등록 레포의 드리프트를 ~/.claude/vault-queue 에 적재한다.
export PF_VAULT_QUEUE_DIR="$T/vault-queue"
pass=0; fail=0
ok(){ printf "  ✅ %s\n" "$1"; pass=$((pass+1)); }
ng(){ printf "  ❌ %s\n     기대: %s\n" "$1" "$2"; fail=$((fail+1)); }
# 진단 파일의 끝 두 줄을 ` — <내용>` 으로 낸다. 비었으면 아무것도 내지 않는다.
# 공백만 남는 경우까지 턴다 — `tr` 뒤에는 개행뿐인 stderr 가 공백 문자열이 되어 truthy 다.
_diag() { local e; e=$(tail -2 "$1" 2>/dev/null | tr -s '[:space:]' ' '); e=${e# }; e=${e% }
          printf '%s' "${e:+ — $e}"; }
# python 프로브의 stderr 는 버리지 않고 "$T/py.err" 로 받는다 (#4). 앞단 명령이 있으면 그 stderr 도
# 같은 파일이다 — 앞단이 `>` 로 비우고 python 은 `>>` 로 붙인다. 앞단이 죽어 python 이 빈 입력에
# JSONDecodeError 를 내도 원인이 같은 파일에 남는다. 판정 값에는 섞지 않는다.
#   · 참·거짓을 종료코드로 내는 자리는 거짓과 사망이 둘 다 exit 1 이라 실패 메시지에 `_diag` 를 싣는다.
#   · 값을 내는 자리는 뒤에 `_pytb $LINENO` 를 둔다 — 죽었을 때만(Traceback) 부른 파일(skills/preflight 기준)·줄 번호와 원인을
#     stderr 로 낸다. 종료코드는 그대로 돌려준다.
_pytb(){ local rc=$?; grep -q '^Traceback' "$T/py.err" 2>/dev/null \
  && printf '     ⚠️  python 프로브가 죽었다 (%s:%s)%s\n' "${BASH_SOURCE[1]#"$MT_DIR"/}" "$1" "$(_diag "$T/py.err")" >&2; return $rc; }

# CONTRACT: structural-guards-count-occurrences
# **소스 토큰을 세는 구조 가드는 출현 횟수를 센다.** `grep -c` 는 매칭된 **라인 수**라 한 줄에
# 둘이 오면 하나로 세고, 정확한 개수를 요구하는 가드는 그 순간 초록인 채 폴백·계약이 빠진
# 자리를 통과시킨다. 실패 메시지가 "N 곳" 이라고 적는 것도 라인 수면 거짓이다.
# 줄 전체 주석은 제외한다(`#` 와 `//` 둘 다). **행말 주석과 문자열 안의 언급은 그대로
# 세어지고, 그 방향은 가드 형태마다 다르다** — 한쪽으로 뭉개 적지 마라:
#   · 정확한 개수·`0` 을 요구하는 자리 → 과다계수는 거짓 실패다 (fail-closed).
#   · `-ge N` 자리 → 과다계수가 **통과시킨다** (fail-open). 임계에 딱 걸려 있으면 진짜 호출부
#     하나가 빠진 것을 행말 주석 언급 하나가 되메운다. **실측값을 여기 적지 않는다** — 호출부가
#     늘면 낡는데 주석 문구를 검사하는 가드는 없어 조용히 어긋난다. 방향이 계약이고 수치는 아니다.
# **픽스처의 줄 수를 세는 자리는 이 계약 밖이다** — 보고서가 묶음마다 한 줄을 내는지,
# PEM 패턴이 몇 줄을 잡는지는 애초에 라인이 단위다.
# 대상 파일이 없으면 **개수를 내지 않는다.** `wc -l` 은 빈 입력에 `0` 을 내므로, 0 을 기대하는
# 가드와 두 개수를 비교하는 가드가 파일 부재만으로 조용히 통과한다. 패턴을 섞은 **비수치**
# 값을 내 어떤 비교도 맞지 않게 한다: 등식은 양쪽 패턴이 달라 어긋나고, 수치 비교는
# 피연산자가 정수가 아니어서 실패한다.
_nocode(){ grep -vE '^[[:space:]]*(#|//)' "$1"; }
nocc(){  [ -f "$1" ] || { printf 'NOFILE(%s)\n' "$2"; return; }
         _nocode "$1" | grep -oF -- "$2" | wc -l | tr -d ' '; }   # 고정 문자열
noccE(){ [ -f "$1" ] || { printf 'NOFILE(%s)\n' "$2"; return; }
         _nocode "$1" | grep -oE -- "$2" | wc -l | tr -d ' '; }   # 확장 정규식

# `preflight.js` 는 `node --check` 로 그냥 검사할 수 없다. 워크플로 스크립트라 최상위
#  `return` 이 정상인데(런타임이 감싸 실행한다), `export` 가 있어 node 가 ESM 으로 읽고
#  `Illegal return statement` 를 낸다.
#
# CONTRACT: 오류 문구로 거르지 마라. `node --check` 는 **첫 오류만** 보고하므로, 그 문구를
#  허용하면 그 뒤의 진짜 구문 오류가 전부 가려진다(실측: 파일 끝에 `const = broken;` 를
#  넣어도 통과했다). 대신 async 함수로 감싼다 — CJS 는 최상위 `await` 를 거절하므로 둘 다
#  받는 자리는 async 함수 본문뿐이다. `export`(함수 안에서 불법)는 `default` 까지 함께 떼야
#  `default …` 가 남아 같은 오탐이 되돌아오지 않는다.
check_js_syntax(){
    # 빈 파일은 래퍼만 남아 `async function __check(){}` 라 유효한 JS 가 된다 — 먼저 거른다.
    # 빈 프로그램은 그 자체로 유효하므로 `node --check` 도 빈 파일은 통과시킨다(실측 rc=0,
    # 부재 파일만 rc=1). 이 가드가 없으면 '구문이 유효하다' 가 파일 없이도 초록불이 된다.
    [ -s "$1" ] || return 1
    # 스위트 임시 디렉터리 안에 둔다 — EXIT trap 이 치운다.
    # `$(mktemp -t x).cjs` 는 mktemp 이 만든 파일과 쓰는 파일이 갈려 원본이 남는다.
    _tmp="$T/pjcheck.$$.cjs"
    { printf 'async function __check(){\n'; sed -E 's/^export (default )?//' "$1"; printf '\n}\n'; } > "$_tmp"
    node --check "$_tmp" >/dev/null 2>&1
    _rc=$?
    rm -f "$_tmp"
    return $_rc
}

repo="$T/repo"; mkdir -p "$repo"; cd "$repo"
git init -q -b main; git config user.email t@t; git config user.name t
# 공용 픽스처는 어느 카테고리 신호도 없는 범용 레포다(기본 카테고리 generic). 카테고리 규칙(vault 등록 조회·dev 배포 안내 등)은
# 그 카테고리로 둔다(package.json name 이 @acme/*). 한 줄 JSON 이라 의존성 줄(DEP_KEY)에 걸리지 않는다.
printf '{"name":"@acme/thing"}\n' > package.json; git add package.json
echo one > a.txt; git add a.txt; git commit -qm init

G="com""mit"
CL="$HOME/.claude/skills/preflight/classify.sh"
reclassify(){ "$CL" "$repo" "$G" >/dev/null 2>&1; }
# 이 레포의 변경은 .txt 뿐이라 분류가 고르는 lane 은 secret-scanner 하나다.
LANE=secret-scanner
# 선택된 lane 전부를 PASS 로 만드는 헬퍼. 하드코딩하면 분류가 바뀔 때 테스트가 거짓 실패한다.
lanes_all_pass(){ python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps({k:"PASS" for k in d["selected"]}))' "$repo/.git/claude-preflight.classify.json"; }
