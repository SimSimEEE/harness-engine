#!/bin/bash
# 하네스의 현재 상태를 README.md 의 마커 사이에 생성한다.
#
#   make-harness-view.sh            README.md 를 갱신한다
#   make-harness-view.sh --check    README 가 하네스와 어긋나면 1 로 끝낸다
#   make-harness-view.sh --stdout   README 를 건드리지 않고 마커 블록만 낸다
#   make-harness-view.sh --stdout-from-index
#                                   같되 입력(agents·settings.hooks.json)을 **인덱스**에서 읽는다.
#                                   게이트 기록이 쓴다 — 커밋될 내용으로 생성한 표를 커밋될
#                                   README 와 대조해야 판정이 인덱스에 선다.
#   make-harness-view.sh --write-from-index
#                                   인덱스 입력으로 생성해 README.md 를 갱신한다. 입력에
#                                   미스테이징 수정이 있을 때 그냥 재생성하면 커밋되지 않을
#                                   내용이 README 에 들어가 기록이 계속 거부된다 — 그 자리에
#                                   쓰는 모드다.
#
# 종료코드: 0 정상 · 1 드리프트(--check 전용) · 2 잘못된 인자 · 4 그 밖의 실패
#
# 출처와 그 한계 — 이 구분이 이 스크립트의 전부다:
#
#   선언적이라 직접 파싱해도 안전한 것
#     agents/*.md frontmatter   lane 이름과 모델
#     settings.hooks.json       훅 등록 (머신 로컬 settings.json 이 아니라 레포 정본을 읽는다)
#
#   생성하지 않는 것: 줄 수·비율. 머지마다 바뀌어 드리프트만 쌓이고, 그 숫자로 정하는 것이
#   없다. 유동적인 값을 커밋되는 파일에 넣으면 --check 가 신호가 아니라 잡음이 된다.
#
#   명령형이라 출력만 소비하는 것
#     lane 집합                 <gitdir>/claude-preflight.classify.json — classify.sh 가 쓴 것
#
# **lane 이 "언제 도는가"는 생성하지 않는다.** 그 조건은 classify.sh 안에 흩어진 Python
# 분기이고, 소스를 파싱하면 조용히 드리프트한다 — 틀린 표는 없는 표보다 나쁘다. 조건 설명은
# 사람이 쓴 산문으로 마커 **밖에** 둔다. 마커 안은 기계가 셀 수 있는 것만 들어간다.
#
# 다이어그램 두 장은 구조이지 데이터가 아니므로 템플릿이다. 구조가 바뀌면 사람이 고친다.
# 다만 lane 개수를 함께 박아 두어, 개수가 어긋나면 diff 에 드러나게 한다.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 4

MODE=write
# 환경에서 물려받은 값이 모드를 정하면 안 된다 — 플래그만 본다.
FROM_INDEX=''
case "${1:-}" in
    '') ;;
    --check)  MODE=check ;;
    --stdout) MODE=stdout ;;
    --stdout-from-index) MODE=stdout ; FROM_INDEX=1 ;;
    --write-from-index)  MODE=write  ; FROM_INDEX=1 ;;
    *) echo "쓸 수 있는 것: (없음) | --check | --stdout | --stdout-from-index | --write-from-index" >&2; exit 2 ;;
esac

BEGIN='<!-- harness:begin -->'
END='<!-- harness:end -->'

GITDIR=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) || {
    echo "git 레포가 아니다: $ROOT" >&2; exit 4; }
CLASSIFY="$GITDIR/claude-preflight.classify.json"

[ -f "$CLASSIFY" ] || {
    echo "classify 출력이 없다: $CLASSIFY" >&2
    echo "lane 집합을 추측하지 않는다. /preflight 를 한 번 돌려 분류 결과를 만든 뒤 다시 실행해라." >&2
    exit 4; }

# 입력을 어디서 읽는가. 기본은 워킹트리다. `--stdout-from-index` 는 인덱스의 blob 을 임시
# 폴더에 풀어 **그것만** 읽는다 — 미스테이징 수정이 표에 새지 않고, 그래서 호출자가
# "워킹트리가 깨끗한가" 를 따로 보지 않아도 된다. 분류 산출물은 그대로 진짜 <gitdir> 에서 읽는다.
# 정리는 한 핸들러로 모은다 — bash 의 EXIT 트랩은 한 벌뿐이라 뒤에서 또 걸면 앞의 것이 덮인다.
IN_TMP=''; TMP=''
trap 'rm -f "$TMP"; rm -rf "$IN_TMP"' EXIT

IN_ROOT="$ROOT"
if [ -n "$FROM_INDEX" ]; then
    IN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/harness-view-idx.XXXXXX") || {
        echo "임시 폴더를 만들 수 없다" >&2; exit 4; }
    IN_ROOT="$IN_TMP"
    git -C "$ROOT" ls-files -z -- agents settings.hooks.json \
        | git -C "$ROOT" checkout-index -z --stdin --prefix="$IN_ROOT/" || {
        echo "인덱스에서 생성기 입력을 풀 수 없다" >&2; exit 4; }
    # 위 pathspec 과 아래 python 이 읽는 입력이 갈리면 빈 표가 조용히 생성되고, 그러면 모든
    # 커밋이 드리프트로 거부된다. 하나도 못 풀었으면 거부가 아니라 **판단 불가**로 끝낸다.
    [ -d "$IN_ROOT/agents" ] || { echo "인덱스에 생성기 입력(agents/)이 없다 — 판정하지 않는다" >&2; exit 4; }
fi

GENERATED=$(ROOT="$IN_ROOT" CLASSIFY="$CLASSIFY" BEGIN="$BEGIN" END="$END" python3 - <<'PY'
import json, os, re, pathlib, shlex

root = pathlib.Path(os.environ["ROOT"])
out  = []

# ---- lane 집합: classify.sh 의 출력만 믿는다 -------------------------------
cls   = json.load(open(os.environ["CLASSIFY"]))
sel   = cls.get("selected") or {}
nsel  = cls.get("notSelected") or {}
lanes = sorted(set(sel) | set(nsel))

# ---- 에이전트 frontmatter: 선언적 -----------------------------------------
models, descs = {}, {}
def cell(s, limit=50):
    # 표가 깨지지 않게 파이프를 막고, 한글이 단어 중간에서 끊기지 않게 경계에서 자른다.
    s = s.replace("|", "\\|").strip()
    s = re.split(r"(?<=[.。])\s|(?= PROACTIVELY)|(?= 단순)", s)[0].strip().rstrip(".")
    if len(s) <= limit:
        return s
    cut = s[:limit]
    for sep in ("·", ", ", " "):
        i = cut.rfind(sep)
        if i >= limit // 2:
            return cut[:i].rstrip(" ,·") + "…"
    return cut + "…"

for f in sorted((root / "agents").glob("*.md")):
    txt   = f.read_text(encoding="utf-8", errors="replace")
    parts = txt.split("---")
    head  = parts[1] if len(parts) > 2 else ""
    m = re.search(r"^model:\s*(\S+)", head, re.M)
    d = re.search(r"^description:\s*(.+)$", head, re.M)
    models[f.stem] = m.group(1) if m else "(기본)"
    if d:
        descs[f.stem] = cell(d.group(1).strip().strip('"'))

# ---- 훅: 레포 정본 조각 ---------------------------------------------------
hooks = []
hj = root / "settings.hooks.json"
if hj.exists():
    for ev, arr in (json.load(open(hj)).get("hooks") or {}).items():
        for blk in arr:
            for hk in blk.get("hooks", []):
                # "<경로>" <인자…> — 스크립트 이름 뒤에 인자를 그대로 붙인다 (memory-sync.sh session-start)
                toks = shlex.split(hk.get("command", "")) or [""]
                name = " ".join([pathlib.PurePath(toks[0]).name] + toks[1:])
                hooks.append((ev, blk.get("matcher", "*"), name, hk.get("timeout", "-")))

# ---- 출력 ----------------------------------------------------------------
w = out.append
w(os.environ["BEGIN"])
w("")
w("<!-- make-harness-view.sh 가 생성한다. 손으로 고치지 마라. -->")
w("")
w("### 강제 경로")
w("")
w("```mermaid")
w("flowchart TD")
w('  SKILL["/preflight"] --> CLS["classify.sh · lane 선택"]')
w('  CLS --> PF["preflight.js · lane 병렬 실행·집계"]')
w('  PF --> REC["receipt.sh · 통과 기록"]')
w('  CMD["git commit · gh pr create"] --> HOOK["preflight-gate.sh"]')
w('  HOOK -.->|기록 확인| REC')
w('  HOOK --> PASS["통과 · 커밋 진행"]')
w('  HOOK --> DENY["차단 · 커밋 거부"]')
w("```")
w("")
w("### 계획이 닫히는 고리")
w("")
w("```mermaid")
w("flowchart LR")
w('  P["/plan"] --> CP["change-planner"] --> PR["plan-reviewer"]')
w('  PR --> ART["계획 아티팩트"] --> RT["requirements-tracer"]')
w("```")
w("")
w(f"### lane {len(lanes)}개")
w("")
w("이번 분류에서 `classify.sh` 가 보고한 lane 이다 (선택 + 미선택).")
w("")
w("| lane | 모델 | 하는 일 |")
w("|---|---|---|")
for l in lanes:
    w(f"| `{l}` | {models.get(l, '(에이전트 정의 없음)')} | {descs.get(l, '—')} |")
w("")
plan_only = sorted(set(models) - set(lanes))
if plan_only:
    w(f"에이전트 정의는 있으나 `classify.sh` 의 lane 집합에 없는 것 {len(plan_only)}개: "
      + ", ".join(f"`{a}`" for a in plan_only)
      + ". 무엇이 이들을 부르는지는 각 정의가 적는다 — 여기서는 유도할 수 없다.")
    w("")
w("### 훅")
w("")
w("| 이벤트 | matcher | 스크립트 | timeout |")
w("|---|---|---|---|")
for ev, mt, nm, to in hooks:
    # matcher 는 정규식이라 `Edit|Write` 처럼 파이프를 담는다 — 코드 스팬 안이어도 표 칸을 가르므로 막는다.
    w(f"| {ev} | `{mt.replace('|', chr(92) + '|')}` | `{nm}` | " + (f"{to}s" if isinstance(to, int) else "-") + " |")
w("")
w("<sub>lane 집합 출처: `classify.sh` 의 분류 출력</sub>")
w("")
w(os.environ["END"])
print("\n".join(out))
PY
) || { echo "생성 실패" >&2; exit 4; }

if [ "$MODE" = stdout ]; then
    printf '%s\n' "$GENERATED"
    exit 0
fi

[ -f README.md ] || { echo "README.md 가 없다" >&2; exit 4; }
grep -qF "$BEGIN" README.md || { echo "README.md 에 마커가 없다: $BEGIN" >&2; exit 4; }
grep -qF "$END"   README.md || { echo "README.md 에 마커가 없다: $END" >&2; exit 4; }

NEW=$(BEGIN="$BEGIN" END="$END" GEN="$GENERATED" python3 - <<'PY'
import os, re, sys
src = open("README.md", encoding="utf-8").read()
b, e = re.escape(os.environ["BEGIN"]), re.escape(os.environ["END"])
new, n = re.subn(b + r".*?" + e, lambda _: os.environ["GEN"], src, count=1, flags=re.S)
if n != 1:
    sys.stderr.write("마커 블록 치환이 0회다 — 마커 순서가 뒤집혔거나 중복이다. README 를 고치지 않았다.\n")
    sys.exit(3)
sys.stdout.write(new)
PY
) || { echo "치환 실패" >&2; exit 4; }

TMP=$(mktemp "${TMPDIR:-/tmp}/harness-view.XXXXXX") || { echo "임시 파일을 만들 수 없다" >&2; exit 4; }
printf '%s\n' "$NEW" > "$TMP"

if [ "$MODE" = check ]; then
    if cmp -s "$TMP" README.md; then
        echo "README 가 하네스와 일치한다."
        exit 0
    fi
    echo "README 가 하네스보다 뒤처졌다. make-harness-view.sh 를 돌려라." >&2
    diff README.md "$TMP" | head -40 >&2
    exit 1
fi

# cat 으로 쓴다 — mktemp 는 0600 이라 mv 하면 README 의 권한이 바뀐다.
cat "$TMP" > README.md
echo "README.md 갱신했다 (lane·에이전트·훅은 생성, 조건 설명은 마커 밖 그대로)."
