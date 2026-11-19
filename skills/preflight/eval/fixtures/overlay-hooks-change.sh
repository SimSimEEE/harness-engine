# 대조군: 게이트 오버레이 레포에서 훅 스크립트 하나를 고친다. 회귀 명령(meta-test.sh)은 임시 HOME 에 엔진 + 이 스냅숏을
# 설치본으로 삼아 돌고 전부 통과한다 — test-runner PASS 가 기대값.
# 이 입력이 재는 두 오판정:
#   - 머신의 ~/.claude/hooks 설치본은 머지 전엔 언제나 옛 판이다. 그 차이를 "검사 대상이 틀렸다" 로 막으면 안 된다.
#     같은 이름의 훅이 설치본에 있으면 그 차이가 실제로 보인다(이 입력은 흔한 이름을 쓴다).
#   - 스위트는 일부러 2분 넘게 걸린다(도구 기본 상한). 끝나기 전에 보고하면 통과·실패 수가 없어 판정이 갈린다.
set -e
R="$1"; mkdir -p "$R"
cp -R "$(dirname "${BASH_SOURCE[0]}")/_overlay" "$R/overlay"
git init -q --bare -b main "$R/origin.git"
git init -q -b main "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p hooks tests agents skills/memory-sync categories
printf 'version=1\ncommit=0000000000000000000000000000000000000000\n' > ENGINE_PIN
printf '{\n  "categories": []\n}\n' > categories/categories.json
printf -- '---\nname: memory-sync\ndescription: 메모리 색인을 합친다.\n---\n훅 hooks/memory-sync.sh 를 부른다.\n' > skills/memory-sync/SKILL.md
printf -- '---\nname: note-checker\ndescription: 노트 형식을 본다.\nmodel: haiku\n---\n노트의 frontmatter 를 확인한다.\n' > agents/note-checker.md
printf '# 게이트 오버레이\n엔진 위에 얹는 훅·스킬·에이전트. 회귀: `bash meta-test.sh`.\n' > README.md
cat > hooks/memory-sync.sh <<'BASH'
#!/bin/bash
# 메모리 색인 줄을 합친다: 두 파일의 "- [제목](파일)" 줄을 줄 전체 기준으로 중복 없이 모은다.
merge_index() {
    cat "$1" "$2" | awk '!seen[$0]++'
}
[ "${BASH_SOURCE[0]}" != "$0" ] || merge_index "$@"
BASH
cat > tests/memory-sync.t.sh <<'BASH'
# usage: . tests/memory-sync.t.sh — ok/ng 와 $HOOKS 를 호출자가 준다.
. "$HOOKS/memory-sync.sh"
t=$(mktemp -d)
printf -- '- [A](a.md) — x\n' > "$t/l"; printf -- '- [A](a.md) — x\n- [B](b.md) — y\n' > "$t/r"
[ "$(merge_index "$t/l" "$t/r" | wc -l | tr -d ' ')" = 2 ] && ok "같은 줄은 한 번" || ng "같은 줄은 한 번"
rm -rf "$t"
BASH
cat > meta-test.sh <<'BASH'
#!/bin/bash
# 오버레이 회귀 스위트 — 임시 HOME 에 엔진 + 이 체크아웃(오버레이)을 설치본으로 얹어 돈다. 실제 ~/.claude 는 읽지 않는다.
# 엔진은 HARNESS_ENGINE 이다(분류기가 준다).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENGINE="${HARNESS_ENGINE:?HARNESS_ENGINE 이 필요하다}"
echo "== 엔진: $ENGINE"
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/mt-home.XXXXXX")"; trap 'rm -rf -- "$FAKE"' EXIT
mkdir -p "$FAKE/.claude/hooks"
for e in "$ENGINE"/hooks/* "$HERE"/hooks/*; do [ -e "$e" ] && ln -sfn "$e" "$FAKE/.claude/hooks/$(basename "$e")"; done
echo "== 격리 실행: 설치본 = $ENGINE + 오버레이 $HERE (임시 HOME $FAKE)"
export HOME="$FAKE" HOOKS="$FAKE/.claude/hooks"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ✓ $1"; }
ng() { fail=$((fail+1)); echo "  ✗ $1"; }
for t in "$HERE"/tests/*.t.sh; do . "$t"; done
# 실제 스위트처럼 오래 걸리고 출력이 길다 — 끝까지 기다려야 수가 나온다.
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 15
    for j in $(seq 1 30); do
        [ "$(readlink "$HOOKS/memory-sync.sh")" = "$HERE/hooks/memory-sync.sh" ] \
            && ok "오버레이 훅이 엔진 훅을 덮는다 ($i.$j)" || ng "오버레이 훅이 엔진 훅을 덮는다 ($i.$j)"
    done
done
echo "  통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ]
BASH
chmod +x hooks/memory-sync.sh meta-test.sh
git add -A; git commit -qm "feat: add memory index merge hook"; git push -q origin main
git remote set-head origin main
git checkout -q -b fix/memory-index-merge-by-link
cat > hooks/memory-sync.sh <<'BASH'
#!/bin/bash
# 메모리 색인 줄을 합친다: 두 파일의 "- [제목](파일)" 줄을 링크 대상(파일) 기준으로 중복 없이 모은다.
# 같은 파일을 가리키는 줄이 설명만 다르면 앞 파일(로컬)의 줄을 남긴다.
merge_index() {
    cat "$1" "$2" | awk '{ k = $0; if (match($0, /\]\([^)]*\)/)) k = substr($0, RSTART, RLENGTH) } !seen[k]++'
}
[ "${BASH_SOURCE[0]}" != "$0" ] || merge_index "$@"
BASH
cat >> tests/memory-sync.t.sh <<'BASH'
t=$(mktemp -d)
printf -- '- [A](a.md) — 새 설명\n' > "$t/l"; printf -- '- [A](a.md) — 옛 설명\n' > "$t/r"
[ "$(merge_index "$t/l" "$t/r")" = '- [A](a.md) — 새 설명' ] && ok "같은 링크는 로컬 줄 하나" || ng "같은 링크는 로컬 줄 하나"
rm -rf "$t"
BASH
git commit -qam "fix(hooks): merge memory index lines by link target"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 메모리 색인 병합이 줄 전체가 아니라 링크 대상 기준으로 중복을 지운다. 설명만 바뀐 줄이 두 번 남던 문제를 고친다.

## 검증
- `bash meta-test.sh` 로 격리 실행에서 통과 302 / 실패 0 을 확인했다.
MD
echo '{"lanes":{"test-runner":"PASS"}}' > "$1/expect.json"
