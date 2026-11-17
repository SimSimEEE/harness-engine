#!/bin/bash
# harness-engine 을 ~/.claude 에 설치한다.
#
#   ./install.sh --link [--overlay <dir>]   로컬: ~/.claude/{agents,skills,hooks} 안에 항목 단위 심링크를 건다 (정본은 체크아웃 하나)
#   ./install.sh --copy [--overlay <dir>]   클라우드 세션/일회성 환경: 기존 디렉터리에 **합쳐서** 복사한다 (플랫폼 스킬·훅 보존)
#
# 오버레이(<dir>)는 조직 전용 카테고리·프로필·에이전트를 담은 레포다. 그 아래
#   agents/*.md · skills/<이름>/ · hooks/*  — 엔진 것 위에 같은 이름을 덮는다(엔진 먼저, 오버레이 나중)
#   categories/ · profiles/               — 설치본 config.json 의 overlayDir 로 분류기에 더한다(classify.sh)
#   settings.hooks.json                   — 엔진 조각과 함께 ~/.claude/settings.json 에 병합한다
# 를 읽는다. 오버레이 없이 설치하면 엔진 카테고리(shell-tool·generic)만 쓴다.
#
# 공통으로 ~/.claude/settings.json 의 hooks 에 settings.hooks.json 의 항목(이벤트마다)을 병합하고,
# skills/preflight/config.json 이 없으면 config.example.json 에서 만든다.
# 기존 항목을 치울 때는 ~/.claude/backups/harness-engine-<ts>/ 로 옮긴다. 삭제하지 않는다.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --link|--copy) ;;
    *) echo "usage: $0 --link|--copy [--overlay <dir>]" >&2; exit 2 ;;
esac
shift
OV=""
if [ "${1:-}" = --overlay ]; then
    [ -n "${2:-}" ] && [ -d "$2" ] || { echo "--overlay 디렉터리가 없다: ${2:-}" >&2; exit 2; }
    OV="$(cd "$2" && pwd -P)"; shift 2
fi
[ $# -eq 0 ] || { echo "알 수 없는 인자: $*" >&2; exit 2; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DST="${CLAUDE_HOME:-$HOME/.claude}"
TS="$(date +%Y%m%d-%H%M%S)"
BAK="$DST/backups/harness-engine-$TS"
mkdir -p "$DST"

stash() {   # 경로 하나를 백업 자리로 옮긴다
    mkdir -p "$BAK/$(dirname "$1")"
    mv "$DST/$1" "$BAK/$1"
    echo "backup: $DST/$1 -> $BAK/$1"
}

# 소스 목록 — 엔진 먼저, 오버레이 나중. 같은 이름이면 나중 것이 이긴다.
sources() { printf '%s\n' "$SRC/$1"; [ -z "$OV" ] || printf '%s\n' "$OV/$1"; }

for name in agents skills hooks; do
    target="$DST/$name"
    if [ "$MODE" = "--link" ]; then
        # 디렉터리 통째 심링크(이전 설치 방식)는 실제 디렉터리로 바꾼다. 옛 링크 대상에만 있던 항목
        # (플랫폼이 쓴 skills/synced 등, 엔진·오버레이가 관리하지 않는 것)은 그 자리로 다시 링크해 잃지 않는다.
        old=""
        if [ -L "$target" ]; then
            old="$(cd "$target" 2>/dev/null && pwd -P || true)"
            stash "$name"
        fi
        mkdir -p "$target"
        while IFS= read -r base; do
            [ -d "$base" ] || continue
            for e in "$base"/*; do
                [ -e "$e" ] || continue
                n="$(basename "$e")"
                case "$n" in *.bak|.DS_Store|hooks.json) continue ;; esac
                # 스킬 디렉터리는 SKILL.md 가 있어야 스킬이다 — 오버레이 체크아웃에 머신 로컬 파일만 남은
                # 디렉터리(옛 skills/preflight/config.json 등)가 엔진 스킬을 덮지 않게 한다.
                [ "$name" != skills ] || [ ! -d "$e" ] || [ -f "$e/SKILL.md" ] || continue
                p="$target/$n"
                if [ -L "$p" ] && [ "$(readlink "$p")" = "$e" ]; then continue; fi
                if [ -e "$p" ] || [ -L "$p" ]; then
                    # 우리가 건 링크(엔진·오버레이를 가리키는)는 바꾼다 — 오버레이가 엔진 것을 덮는 자리다.
                    # 그 밖의 실제 파일·남의 링크는 백업한다.
                    case "$(readlink "$p" 2>/dev/null || true)" in
                        "$SRC"/*|"${OV:-/nonexistent}"/*) rm -f "$p" ;;
                        *) stash "$name/$n" ;;
                    esac
                fi
                ln -s "$e" "$p"
                echo "link:   $p -> $e"
            done
        done < <(sources "$name")
        if [ -n "$old" ] && [ -d "$old" ]; then
            for e in "$old"/*; do
                [ -e "$e" ] || continue
                n="$(basename "$e")"
                [ -e "$target/$n" ] || [ -L "$target/$n" ] || { ln -s "$e" "$target/$n"; echo "keep:   $target/$n -> $e (옛 설치에만 있던 항목)"; }
            done
        fi
        # 엔진·오버레이를 가리키는데 대상이 사라진 링크는 걷어낸다
        for p in "$target"/*; do
            { [ -L "$p" ] && [ ! -e "$p" ]; } || continue
            case "$(readlink "$p")" in "$SRC"/*|"${OV:-/nonexistent}"/*) rm -f "$p"; echo "unlink: $p (대상 없음)" ;; esac
        done
    else
        # 복사 모드는 **합친다**. 클라우드 컨테이너의 ~/.claude/skills 와 hooks 에는 플랫폼이 넣어둔
        # 것이 이미 있다. 통째로 치우면 그게 사라진다. 심링크 잔재만 걷어내고, 같은 이름만 덮어쓴다.
        [ -L "$target" ] && rm -f "$target"
        mkdir -p "$target"
        while IFS= read -r base; do
            [ -d "$base" ] || continue
            cp -R "$base/." "$target/"
            echo "merge:  $base -> $target"
        done < <(sources "$name")
    fi
done

# 오버레이의 categories·profiles 자리. 링크 모드는 오버레이 체크아웃을 그대로 가리키고,
# 복사 모드는 체크아웃이 사라져도 분류가 서도록 ~/.claude/harness-overlay 로 복사한다.
OVDIR=""
if [ -n "$OV" ]; then
    if [ "$MODE" = "--link" ]; then
        OVDIR="$OV"
    else
        OVDIR="$DST/harness-overlay"
        rm -rf "$OVDIR"; mkdir -p "$OVDIR"
        for d in categories profiles; do [ -d "$OV/$d" ] && cp -R "$OV/$d" "$OVDIR/$d"; done
        echo "copy:   $OV/{categories,profiles} -> $OVDIR"
    fi
fi

# 머신 로컬 설정 — 설치본 skills/preflight/config.json (링크 모드면 엔진 체크아웃 안, gitignore).
CFG="$DST/skills/preflight/config.json"
if [ ! -e "$CFG" ]; then
    if [ -f "$BAK/skills/preflight/config.json" ]; then
        cp "$BAK/skills/preflight/config.json" "$CFG"; echo "config: restored from backup"
    elif [ -n "$OV" ] && [ -f "$OV/skills/preflight/config.json" ]; then
        # 엔진이 오버레이 레포 안에 있던 시절의 설정(머신 로컬, 커밋 안 됨)을 옮긴다
        cp "$OV/skills/preflight/config.json" "$CFG"; echo "config: migrated from $OV/skills/preflight/config.json"
    else
        cp "$DST/skills/preflight/config.example.json" "$CFG"
        echo "config: created from example (vaultDir 등을 이 머신에 맞게 고쳐라)"
    fi
fi
CFG="$CFG" OVDIR="$OVDIR" python3 - <<'PY'
import json, os
p = os.environ['CFG']
d = json.load(open(p))
ov = os.environ['OVDIR']
if ov:
    d['overlayDir'] = ov
else:
    d.pop('overlayDir', None)
with open(p, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write('\n')
print('config: overlayDir =', ov or '(없음)')
PY
# 캐시 자리도 백업·옛 설치에서 옮긴다(없으면 카테고리 스크립트가 다시 만든다)
if [ -f "$BAK/skills/preflight/.qa-endpoints.json" ] && [ ! -e "$DST/skills/preflight/.qa-endpoints.json" ]; then
    cp "$BAK/skills/preflight/.qa-endpoints.json" "$DST/skills/preflight/.qa-endpoints.json"
fi
if [ -n "$OV" ] && [ -f "$OV/skills/preflight/.qa-endpoints.json" ] && [ ! -e "$DST/skills/preflight/.qa-endpoints.json" ]; then
    cp "$OV/skills/preflight/.qa-endpoints.json" "$DST/skills/preflight/.qa-endpoints.json"
fi

chmod +x "$DST/hooks/"*.sh "$DST/skills/preflight/"*.sh 2>/dev/null || true

# settings.json 에 hook 병합. 이벤트마다 조각의 스크립트(파일 이름)를 가리키는 기존 항목은 교체하고 나머지는 보존한다.
SETTINGS="$DST/settings.json"
FRAGS="$SRC/settings.hooks.json"
[ -n "$OV" ] && [ -f "$OV/settings.hooks.json" ] && FRAGS="$FRAGS:$OV/settings.hooks.json"
SETTINGS="$SETTINGS" FRAGS="$FRAGS" python3 - <<'PY'
import json, os
sp = os.environ["SETTINGS"]
s = json.load(open(sp)) if os.path.exists(sp) else {}
hooks = s.setdefault("hooks", {})
for fp in os.environ["FRAGS"].split(":"):
    for ev, frags in json.load(open(fp))["hooks"].items():
        ours = {h["command"].strip('"').split('"')[0].rsplit("/", 1)[-1] for f in frags for h in f.get("hooks", [])}
        kept = [e for e in hooks.get(ev, [])
                if not any(n in h.get("command", "") for h in e.get("hooks", []) for n in ours)]
        hooks[ev] = kept + frags
with open(sp, "w") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("hooks:  merged into", sp)
PY

echo "done ($MODE${OV:+ + overlay $OV})"
