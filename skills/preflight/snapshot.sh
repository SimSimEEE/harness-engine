#!/bin/bash
# preflight snapshot — 검사 대상(트리)을 격리 체크아웃으로 푼다 (#8 R8·R9).
#
# 생성·트리 대조·정리는 이 결정론 코드가 한다. lane(LLM)은 받은 경로를 쓰기만 한다 — lane 이
# git 명령을 조합해 체크아웃을 만들면 무엇을 검사했는지가 lane 의 성실성에 달린다.
#
# usage:
#   snapshot.sh create <repo> <tree-ish>   stdout: {"path":…,"tree":…,"commit":…}  · 실패 시 exit 1 + stderr 사유
#   snapshot.sh remove <repo> <path>       이 스크립트가 만든 경로(pf-snap.*)만 지운다
#
# 원본 체크아웃은 바꾸지 않는다(I3): 워킹트리·인덱스·HEAD·ref 를 건드리지 않는다. 트리를 체크아웃하려면
# 커밋이 필요해 `commit-tree` 로 **객체만** 만든다 — ref 에 걸지 않으므로 gc 가 거둔다.
# 경로는 실행마다 고유하다(mktemp) — 같은 레포에서 동시에 도는 게이트가 서로의 스냅숏을 덮지 않는다.
# 대조가 다르거나 생성 도중 실패하면 **원본 경로로 대체하지 않고** 실패한다(I4). 만든 것은 지우고 나간다.
# 중단(kill)으로 남은 등록은 이 스크립트가 지우지 않는다 — 어느 실행의 것인지 판정할 근거가 없다.
#   그래서 `git worktree prune` 도 부르지 않는다(남의 잔여까지 지운다).
set -uo pipefail

cmd="${1:-}"; repo="${2:-}"; arg="${3:-}"
die() { echo "snapshot: $*" >&2; exit 1; }
[ -n "$cmd" ] && [ -n "$repo" ] && [ -n "$arg" ] || { echo "usage: snapshot.sh create|remove <repo> <tree-ish|path>" >&2; exit 2; }
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "git 레포가 아니다: $repo"

case "$cmd" in
create)
    tree=$(git -C "$repo" rev-parse --verify -q "${arg}^{tree}") || die "트리를 해석하지 못했다: $arg"
    parent=()
    head=$(git -C "$repo" rev-parse --verify -q HEAD) && parent=(-p "$head")
    commit=$(GIT_AUTHOR_NAME=preflight GIT_AUTHOR_EMAIL=preflight@localhost \
             GIT_COMMITTER_NAME=preflight GIT_COMMITTER_EMAIL=preflight@localhost \
             git -C "$repo" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m 'preflight snapshot' 2>/dev/null) \
        || die "스냅숏 커밋 객체를 만들지 못했다: $tree"
    _tmp="${TMPDIR:-/tmp}"
    dir=$(mktemp -d "${_tmp%/}/pf-snap.XXXXXX") || die "임시 경로를 만들지 못했다"
    # 여기서부터 실패하면 만든 것을 지운다 — 같은 프로세스 안의 실패 경로는 자기 등록을 남기지 않는다(I3).
    fail() { git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1; rm -rf -- "$dir"; die "$*"; }
    git -C "$repo" worktree add --detach -q "$dir" "$commit" >/dev/null 2>&1 || fail "worktree 를 만들지 못했다: $dir"
    # 실패 경로를 meta-test 가 주입할 수 있게 둔다. 판정 값을 바꾸는 자리가 아니라 실패를 만드는 자리다.
    [ -z "${PF_SNAP_FAIL_AFTER_ADD:-}" ] || fail "주입된 실패 (PF_SNAP_FAIL_AFTER_ADD)"
    got=$(git -C "$dir" rev-parse --verify -q 'HEAD^{tree}')
    [ -z "${PF_SNAP_FAKE_TREE:-}" ] || got="$PF_SNAP_FAKE_TREE"
    [ "$got" = "$tree" ] || fail "트리 대조 불일치: 체크아웃 ${got:-없음} != 대상 $tree"
    DIR="$dir" TREE="$tree" COMMIT="$commit" python3 -c '
import json, os
print(json.dumps({"path": os.environ["DIR"], "tree": os.environ["TREE"], "commit": os.environ["COMMIT"]}))'
    ;;
remove)
    case "$(basename -- "$arg")" in pf-snap.*) ;; *) die "이 스크립트가 만든 경로가 아니다: $arg" ;; esac
    git -C "$repo" worktree remove --force "$arg" >/dev/null 2>&1
    [ -e "$arg" ] && rm -rf -- "$arg"
    [ ! -e "$arg" ] || die "지우지 못했다: $arg"
    ;;
*) echo "usage: snapshot.sh create|remove <repo> <tree-ish|path>" >&2; exit 2 ;;
esac
