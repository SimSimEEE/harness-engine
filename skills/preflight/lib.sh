# preflight 공용 — 분류·기록·검증이 **같은 값**을 봐야 한다. 한 곳에만 둔다.
# source 전용. 실행하지 않는다.

# 지금 체크아웃된 브랜치 이름. **브랜치를 판정하는 자리는 전부 이 함수를 지난다** (meta-test 가 고정).
# symbolic-ref 가 먼저인 이유: 첫 커밋 전 브랜치에서도 이름을 준다 (`rev-parse --abbrev-ref` 는 실패한다).
# detached HEAD 는 symbolic-ref 가 실패하므로 rev-parse 의 'HEAD' 로 떨어진다.
# CONTRACT: branch-is-one-function — 훅은 이 파일을 source 하지 못해 같은 식을 옮겨 적는다.
pf_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

pf_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 1 | cut -d' ' -f1; else sha1sum | cut -d' ' -f1; fi; }

# 게이트 종류(commit|pr)에 쓸 수 있는 분류 모드. 공백 구분.
# CONTRACT: ok-modes-is-one-function — record 와 verify 가 **이 출력**으로 판정한다. 두 곳이 각자
#  적으면 다음에 갈린다(#2). `all` 은 PR 을 대신하지 못한다: classify.sh 의 base 해석이 pr 에만
#  걸려 `all` 분류는 커밋 뒤 변경이 0건으로 보인다.
pf_ok_modes() { if [ "$1" = pr ]; then echo pr; else echo "all $1"; fi; }

# 검사 대상(스냅숏)의 내용 다이제스트 — 분류 artifact 의 `contentDigest` (#8).
#
# 커밋 모드의 대상은 **커밋될 인덱스**다. 워킹트리만 바꾸는 조작(미추적 파일·미스테이징 수정·
# 미스테이징 변경만의 stash)은 값을 바꾸지 않고, 스테이징 내용이나 스테이징 집합이 바뀌면 바뀐다.
# 두 번째 인자(base)를 주면 PR 모드다 — 대상은 base..HEAD 의 커밋뿐이다(인덱스·워킹트리 무관).
# 원시 diff 출력(경로·모드·블롭 해시)을 그대로 해시한다. 블롭 해시가 내용을 대신하므로 파일을
# 읽지 않고, `-z` 라 경로 문자가 무엇이든 같은 바이트열이 나온다(CONTRACT: git-paths-read-with-z).
# 변경이 없어도 빈 입력의 해시가 나온다 — 빈 문자열이 아니다(record 의 스키마 검사가 요구한다).
pf_index_digest() {
    local d="$1" base="${2:-}"
    if [ -n "$base" ]; then
        git -C "$d" diff-tree -r --no-renames -z "$base" HEAD 2>/dev/null
    elif git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        git -C "$d" diff-index --cached --no-renames -z HEAD 2>/dev/null
    else
        git -C "$d" ls-files -s -z 2>/dev/null
    fi | pf_sha
}

# CONTRACT: git-paths-read-with-z — **정본은 여기다.**
# **git 이 내는 경로 목록은 `-z` 로 받는다** — 이 레포에서 그 목록을 경로로 되쓰는 자리
# 전부(`classify.sh` 의 `git_z`, `receipt.sh` 의 차이 목록, `claim-extract.sh`, 위 `pf_index_digest`)가
# 같은 규칙이다. 기본 출력은 비ASCII·개행·따옴표·역슬래시가 든 경로를 C-quote 하고, 그 문자열은
# 실제 파일 이름이 아니라 `[ -f ]` 같은 경로 검사가 실패한다 (2026-09-28 실측).
# `-c core.quotePath=false` 로는 부족하다 — 비ASCII 만 풀리고 개행 경로는 그대로 따옴표다.
# 출력 구분자도 NUL 이다. 경로에 진짜 개행이 들면 줄 단위로는 서로 다른 파일 집합이
# 같은 바이트열이 된다.

# CONTRACT: json-out-is-one-function — **정본은 여기다.** 각 스크립트의 `_json_out`/`pf_deny`
# 는 이 설명을 한 줄로 가리킨다 (사본이 여러 벌이면 한 벌만 고쳐져 갈라진다).
#
# 위 `git-paths-read-with-z` 때문에 경로는 원시 바이트다 (git 의 C-quote 가 주던 ASCII
# 보장이 없다). python 은 그것을 surrogateescape 로 디코딩하는데(`os.environ` 도 그렇다), 그 문자열은
# UTF-8 로 인코딩할 수 없다. 그래서 경로가 실릴 수 있는 출력은 **쓰는 자리마다 막지 않고 한
# 함수를 지난다** — 자리마다 막으면 빠뜨린다.
#   · `ensure_ascii=True` 로 떨어지면 `\udcXX` 이스케이프가 된다. JSON 으로 유효하고
#     `json.loads` 가 원래 문자열을 되돌린다. 한글 경로만 있으면 이 갈래에 오지 않지만,
#     같은 payload 에 비UTF-8 경로가 하나라도 섞이면 한글까지 함께 이스케이프된다.
#   · 사람에게 보이는 경로는 `backslashreplace` 로 이스케이프한다 — 표시가 죽으면 안 된다.
#   · **stdout 의 errors 는 로케일에 달려 있다.** 이 맥은 LANG 이 비어 `surrogateescape` 지만
#     `LANG=…UTF-8` 이면 strict 다. 파일 write 는 어느 쪽이든 strict 다. 로케일에 기대지 않는다.
# **대상 목록을 여기 적지 않는다.** 정본은 meta-test 의 개수 표 하나이고, 그 표에 없는 파일은
# 대상이 아니다 — 눈으로 고르면 틀린다 (`pr-format-check.sh` 는 브랜치만 본다고 읽히지만
# `out['repo']` 에 레포 경로를 싣는다).
# 표에 넣을지 판단하는 기준은 **게이트의 출력에 경로가 실리는가** 다: 실리면 넣고, 테스트
# 하네스의 probe 입력이나 경로 아닌 값(도메인·basePath)만 싣는 자리는 넣지 않는다.

# append-only 관측 로그의 위치. **판정에 관여하지 않는다.**
# 이 로그가 없거나 못 써도 게이트 동작은 조금도 달라지지 않아야 한다 —
# 관측 장치가 관측 대상을 막으면 그건 관측이 아니다.
PF_LOG="${PF_LOG:-$HOME/.claude/preflight-log.jsonl}"
export PF_LOG

# 엔진 버전 — 같은 디렉터리의 `ENGINE_VERSION` 첫 줄. 손으로 올린다(근거: DECISIONS.md 「엔진 버전 표식」).
# 형식은 `MAJOR.MINOR` 만 받는다. 파일이 없거나 형식이 아니면 **빈 문자열**을 낸다 — 기록하는 쪽이
# null 로 남긴다. **판정에 관여하지 않는다**: 읽지 못해도 record 는 그대로 진행된다.
pf_engine_version() {
    local f v
    f="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ENGINE_VERSION"
    v=$(head -n 1 "$f" 2>/dev/null | tr -d '[:space:]')
    case "$v" in
        ''|*[!0-9.]*|.*|*.|*.*.*) return 0 ;;
        *.*) printf '%s' "$v" ;;
    esac
}

# 오버레이 루트 — 엔진 체크아웃 밖에서 카테고리·프로필을 더하는 디렉터리다. 그 아래 `categories/`(선언
# `categories.json` 과 카테고리 디렉터리)와 `profiles/<owner>/<repo>.json` 을 엔진의 것에 더해 읽는다.
# 조직 전용 규칙을 공개 엔진 체크아웃에 넣지 않으려고 둔다.
# 출처: 환경변수 `PF_OVERLAY_DIR` 이 **설정돼 있으면** 그 값(빈 값 = 오버레이 없음), 아니면 같은 디렉터리
# `config.json` 의 `overlayDir`. 앞의 `$HOME`·`~` 는 전개한다. 경로가 디렉터리인지는 읽는 쪽(classify.sh)이
# 판정한다 — 설정했는데 없으면 분류하지 않는다(조용히 빠지면 그 카테고리의 검사가 사라진다).
pf_overlay_dir() {
    local sd v
    if [ "${PF_OVERLAY_DIR+x}" = x ]; then
        v="$PF_OVERLAY_DIR"
    else
        sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        v=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("overlayDir") or "")
except Exception: print("")' "$sd/config.json" 2>/dev/null)
    fi
    case "$v" in
        '$HOME'*) v="$HOME${v#\$HOME}" ;;
        '~'*) v="$HOME${v#\~}" ;;
    esac
    printf '%s' "$v"
}

# 카테고리 루트 목록(콜론 구분) — 엔진의 `categories` 다음에 오버레이의 `categories`(있을 때만).
# 이름으로 카테고리 디렉터리를 찾는 자리(receipt.sh 의 vault-queue.sh 등)는 이 순서로 찾는다.
pf_category_roots() {
    local sd ov
    sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ov="$(pf_overlay_dir)"
    if [ -n "$ov" ] && [ -d "$ov/categories" ]; then printf '%s:%s' "$sd/categories" "$ov/categories"
    else printf '%s' "$sd/categories"; fi
}
