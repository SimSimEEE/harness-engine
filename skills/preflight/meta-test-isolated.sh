#!/bin/bash
# meta-test 를 **이 체크아웃**을 설치본으로 삼아 돌린다.
#
# meta-test.sh 는 설치본($HOME/.claude)을 검사하고, 설치본이 커밋될 워킹트리와 다르면 실패한다.
# 설치본은 한 체크아웃만 가리키므로, 그 체크아웃이 다른 브랜치에 있으면 어느 워크트리의 변경도
# 게이트를 통과할 수 없다. 이 래퍼는 임시 HOME 을 만들어 그 안의 .claude 를 이 체크아웃으로
# 연결하고 이 체크아웃의 meta-test.sh 를 실행한다 — 실제 설치본과 실제 로그는 건드리지 않는다.
#
# 머신 로컬 파일(config.json · .qa-endpoints.json)은 커밋되지 않으므로 실제 설치본에서 복사한다.
# 체크아웃 안에 쓰지 않는다: skills/preflight 는 파일 단위 심링크를 담은 실제 디렉터리로 만든다.
#
# --overlay <디렉터리> 를 주면 그 디렉터리를 오버레이로 얹는다(install.sh --overlay 와 같은 배치):
# agents·hooks·skills 는 엔진 것 위에 오버레이 것을 항목 단위로 덮고, PF_OVERLAY_DIR 로 그 디렉터리의
# categories/·profiles/ 를 분류기에 더한다. 오버레이 레포(조직 전용 카테고리)가 엔진 체크아웃과 함께 검증할 때 쓴다.
#
# usage: meta-test-isolated.sh [--overlay <dir>] [meta-test.sh 인자...]
# exit: meta-test.sh 의 종료코드. 준비 실패는 2.
set -uo pipefail
OV=""
if [ "${1:-}" = --overlay ]; then
    [ -n "${2:-}" ] && [ -d "$2" ] || { echo "--overlay 디렉터리가 없다: ${2:-}" >&2; exit 2; }
    OV="$(cd "$2" && pwd -P)"; shift 2
fi
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "$SELF" rev-parse --show-toplevel 2>/dev/null)" || { echo "체크아웃이 아니다: $SELF" >&2; exit 2; }
for d in agents hooks skills/preflight; do
    [ -d "$ROOT/$d" ] || { echo "게이트 레포가 아니다 ($d 없음): $ROOT" >&2; exit 2; }
done
REAL="$HOME/.claude/skills/preflight"
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/mt-home.XXXXXX")" || exit 2
trap 'rm -rf -- "$FAKE"' EXIT

C="$FAKE/.claude"
mkdir -p "$C/skills/preflight" || exit 2
if [ -z "$OV" ]; then
    ln -s "$ROOT/agents" "$C/agents"
    ln -s "$ROOT/hooks" "$C/hooks"
else
    # 항목 단위 링크 — 엔진 먼저, 오버레이가 같은 이름을 덮는다(install.sh --overlay 와 같은 순서).
    mkdir -p "$C/agents" "$C/hooks" || exit 2
    for d in agents hooks; do
        for e in "$ROOT/$d"/* ${OV:+"$OV/$d"/*}; do
            [ -e "$e" ] && ln -sfn "$e" "$C/$d/$(basename "$e")"
        done
    done
fi
for e in "$ROOT"/skills/* ${OV:+"$OV"/skills/*}; do
    [ -e "$e" ] || continue
    [ ! -d "$e" ] || [ -f "$e/SKILL.md" ] || continue   # SKILL.md 없는 디렉터리는 스킬이 아니다(install.sh 와 같은 규칙)
    [ "$(basename "$e")" = preflight ] || ln -sfn "$e" "$C/skills/$(basename "$e")"
done
# 디렉터리는 실제로 만들고 파일만 심링크한다. 하위 디렉터리를 통째로 심링크하면 그 안의
# 스크립트가 `pwd -P` 로 자기 위치를 풀 때 체크아웃으로 빠져나가 config.json 을 못 찾는다
# (eval/flip.sh 가 그렇다). 숨김 파일도 포함된다.
_src="$ROOT/skills/preflight"
while IFS= read -r -d '' e; do
    rel="${e#"$_src"/}"
    case "$rel" in config.json|.qa-endpoints.json) continue ;; esac
    if [ -d "$e" ]; then mkdir -p "$C/skills/preflight/$rel"
    else ln -s "$e" "$C/skills/preflight/$rel"; fi
done < <(find "$_src" -mindepth 1 \( -name node_modules -prune \) -o -print0)
for f in config.json .qa-endpoints.json; do
    if [ -f "$REAL/$f" ]; then cp "$REAL/$f" "$C/skills/preflight/$f"
    else echo "  (참고) 실제 설치본에 $f 가 없다 — 그 파일에 기대는 단언은 실패할 수 있다" >&2; fi
done

# git 전역 설정(사용자 이름 등)은 실제 HOME 의 것을 쓴다 — 임시 HOME 에는 없다
_gc="${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}"
echo "== 격리 실행: 설치본 = $ROOT${OV:+ + 오버레이 $OV} (임시 HOME $FAKE)"
# 오버레이를 주지 않으면 실제 설치본 config.json 의 overlayDir 도 쓰지 않는다 — 엔진만 검증한다.
HOME="$FAKE" GIT_CONFIG_GLOBAL="$_gc" PF_OVERLAY_DIR="$OV" bash "$ROOT/skills/preflight/meta-test.sh" "$@"
