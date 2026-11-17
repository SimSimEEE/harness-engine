#!/bin/bash
# meta-test — 요청 시점 카테고리 표시 훅(hooks/category-context.sh, #47)
# meta-test.sh 가 lib.sh 다음에 source 한다 — lib.sh 의 ok·ng·$T·$_mt_repo 만 쓴다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 요청 시점 카테고리 표시 훅 (#47) =="
# 근거·출력 규약은 DECISIONS.md 2026-11-16 (요청 시점 카테고리 표시 훅).
HK="$HOME/.claude/hooks/category-context.sh"
CSH="$HOME/.claude/skills/preflight/category.sh"
KH="$T/cathook"; mkdir -p "$KH"
# 카테고리는 테스트 전용 오버레이(meta-test/fixtures/overlay — fx-backend·fx-vault)로 고정한다. 설치본에 어떤 조직 오버레이가
# 얹혀 있어도 이 절의 판정이 그것에 기대지 않게 한다. 절 끝에서 되돌린다.
_kh_ov="${PF_OVERLAY_DIR-__unset__}"; export PF_OVERLAY_DIR="$MT_DIR/meta-test/fixtures/overlay"
# 픽스처: 종류(vault·backend·none)의 표식을 커밋한 레포.
khrepo(){ local d="$KH/$1"; shift; rm -rf "$d"; mkdir -p "$d/sub"; git init -q -b main "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  for k in "$@"; do case "$k" in
    vault) printf '# rules\n' > "$d/VAULT_RULES.md" ;;
    backend) printf '{\n  "name": "svc",\n  "dependencies": {\n    "acme-core": "^3"\n  }\n}\n' > "$d/package.json" ;;
    none) printf 'x\n' > "$d/README.txt" ;;
  esac; done
  printf 'x\n' > "$d/sub/y.txt"; git -C "$d" add -A; git -C "$d" "com""mit" -qm base; }
# 훅 입력은 Claude Code 가 주는 UserPromptSubmit JSON 이다. 출력은 stdout, 종료코드는 $_hrc.
khrun(){ printf '{"hook_event_name":"UserPromptSubmit","prompt":"x","cwd":"%s"}' "$1" | env -u PF_ROOT "${2:-$HK}" > "$T/kh.out" 2> "$T/kh.err"; _hrc=$?; }

khrepo backend backend; khrepo vault vault; khrepo none none; khrepo over vault backend

# H1 — 카테고리와 근거·절차를 그대로 옮긴다 (판정은 category.sh 의 것)
khrun "$KH/backend"
[ "$_hrc" = 0 ] && grep -qF "$KH/backend: fx-backend (근거: package.json: dependencies.acme-core)" "$T/kh.out" \
  && grep -q '^  절차 P1: ' "$T/kh.out" && grep -q '^  절차 P2: ' "$T/kh.out" \
  && ok "H1: backend 레포 → 카테고리·근거·절차 P1·P2 를 낸다" || ng "H1: backend 레포 출력이 어긋난다 [rc=$_hrc] $(head -3 "$T/kh.out" | tr '\n' '|')" "fx-backend · 근거 · 절차 P1·P2"
khrun "$KH/vault"
[ "$_hrc" = 0 ] && grep -qF "$KH/vault: fx-vault (근거: VAULT_RULES.md)" "$T/kh.out" && grep -qx '  카테고리 절차: 없음' "$T/kh.out" \
  && ok "H1: vault 레포 → 카테고리와 '절차 없음' 을 낸다" || ng "H1: vault 레포 출력이 어긋난다 [rc=$_hrc] $(head -3 "$T/kh.out" | tr '\n' '|')" "fx-vault · 절차 없음"
khrun "$KH/none"
[ "$_hrc" = 0 ] && grep -qF "$KH/none: generic (근거: fallback — 다른 카테고리의 신호가 없다)" "$T/kh.out" && grep -qx '  카테고리 절차: 없음' "$T/kh.out" \
  && ok "H1: 신호 없는 레포 → 기본 카테고리 generic 과 근거 fallback" || ng "H1: 신호 없는 레포 출력이 어긋난다 [rc=$_hrc] $(head -3 "$T/kh.out" | tr '\n' '|')" "generic · fallback · 절차 없음"

# H2 — 표시와 조회가 같은 카테고리를 말한다 (훅이 따로 판정하지 않는다)
_hmis=''
for _r in backend vault none; do
  _want=$("$CSH" "$KH/$_r" 2>"$T/py.err" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("category") or "없음")' 2>>"$T/py.err"; _pytb $LINENO)
  khrun "$KH/$_r"; _got=$(sed -n '1s/^\[하네스 카테고리\] [^:]*: \([^ ]*\).*/\1/p' "$T/kh.out")
  [ -n "$_want" ] && [ "$_want" = "$_got" ] || _hmis="$_hmis $_r(조회=$_want 표시=$_got)"
done
[ -z "$_hmis" ] && ok "H2: 세 픽스처에서 표시 카테고리 = category.sh 카테고리" || ng "H2: 표시와 조회가 다르다:$_hmis$(_diag "$T/py.err")" "같다"

# H3 — 하위 디렉터리에서 요청해도 그 레포의 카테고리다
khrun "$KH/backend/sub"
[ "$_hrc" = 0 ] && grep -qF "$KH/backend: fx-backend" "$T/kh.out" \
  && ok "H3: 하위 디렉터리 cwd → 레포 최상위로 조회" || ng "H3: 하위 디렉터리 cwd 출력이 어긋난다 [rc=$_hrc] $(head -1 "$T/kh.out")" "$KH/backend: fx-backend"

# H4 — 겹침(category.sh exit 3)은 막지 않고 겹침을 알린다
khrun "$KH/over"
[ "$_hrc" = 0 ] && grep -qF "$KH/over: 겹침 — " "$T/kh.out" && grep -q 'fx-vault' "$T/kh.out" && grep -q 'fx-backend' "$T/kh.out" && ! grep -q '분류 불가' "$T/kh.out" \
  && ok "H4: 겹침 → exit 0, '겹침' 과 걸린 카테고리 이름을 낸다" || ng "H4: 겹침 출력이 어긋난다 [rc=$_hrc] $(head -2 "$T/kh.out" | tr '\n' '|')" "exit 0 · 겹침 · fx-vault · fx-backend"

# H4 — 같은 exit 3 이라도 카테고리 적재 실패는 겹침이라고 하지 않는다. 실제 적재 실패를 만든다: 설치본 사본에서 선언을 지운다
rm -rf "$KH/broken"; mkdir -p "$KH/broken/hooks"; cp "$HK" "$KH/broken/hooks/"
cp -RL "$HOME/.claude/skills/preflight" "$KH/broken/preflight.tmp" 2>/dev/null; mkdir -p "$KH/broken/skills"
mv "$KH/broken/preflight.tmp" "$KH/broken/skills/preflight"; rm -f "$KH/broken/skills/preflight/categories/categories.json"
khrun "$KH/backend" "$KH/broken/hooks/category-context.sh"
[ "$_hrc" = 0 ] && grep -qF "$KH/backend: 분류 불가 — 카테고리 적재 실패" "$T/kh.out" && ! grep -q '겹침' "$T/kh.out" \
  && ok "H4: 카테고리 적재 실패(exit 3) → exit 0, '분류 불가' 이고 '겹침' 이 아니다" \
  || ng "H4: 적재 실패 출력이 어긋난다 [rc=$_hrc] $(head -2 "$T/kh.out" | tr '\n' '|')" "exit 0 · 분류 불가 — 카테고리 적재 실패 · 겹침 없음"

# H5 — fail-open: 무엇이 실패해도 exit 0 이고 stdout 은 비어 있다 (UserPromptSubmit 의 exit 2 는 요청을 막는다)
mkdir -p "$KH/nogit"
_hbad=''
khrun "$KH/nogit"; { [ "$_hrc" = 0 ] && [ ! -s "$T/kh.out" ]; } || _hbad="$_hbad git레포아님(rc=$_hrc)"
# 설치 고장: category.sh 없음 · 죽음(exit 1) · exit 2 · 깨진 JSON
_hroot(){ rm -rf "$KH/root"; mkdir -p "$KH/root/hooks" "$KH/root/skills/preflight"; cp "$HK" "$KH/root/hooks/"; }
_hroot; khrun "$KH/backend" "$KH/root/hooks/category-context.sh"
{ [ "$_hrc" = 0 ] && [ ! -s "$T/kh.out" ]; } || _hbad="$_hbad category.sh없음(rc=$_hrc)"
for _body in 'echo boom >&2; exit 1' 'exit 2' 'echo "{not json"; exit 0'; do
  _hroot; printf '#!/bin/bash\n%s\n' "$_body" > "$KH/root/skills/preflight/category.sh"
  khrun "$KH/backend" "$KH/root/hooks/category-context.sh"
  { [ "$_hrc" = 0 ] && [ ! -s "$T/kh.out" ]; } || _hbad="$_hbad [$_body](rc=$_hrc)"
done
# 입력이 JSON 이 아니면 훅의 작업 디렉터리로 조회한다 — git 레포 밖이면 아무것도 내지 않는다
( cd "$KH/nogit" && printf '{broken' | env -u PF_ROOT "$HK" > "$T/kh.out" 2>/dev/null ); _hrc=$?
{ [ "$_hrc" = 0 ] && [ ! -s "$T/kh.out" ]; } || _hbad="$_hbad 깨진입력(rc=$_hrc)"
[ -z "$_hbad" ] && ok "H5: git 레포 아님·category.sh 없음/실패/깨진 출력·깨진 입력 → exit 0, 출력 없음" \
  || ng "H5: fail-open 이 깨졌다:$_hbad" "전부 exit 0 · stdout 비어 있음"

# H6 — 등록: 레포 템플릿과 플러그인이 UserPromptSubmit 에 이 훅을 등록하고, install.sh 병합은 남의 항목을 보존하며 반복해도 하나다
_hreg=$(python3 - "$_mt_repo/settings.hooks.json" 2>"$T/py.err" <<'PY'
import json, sys
ups = json.load(open(sys.argv[1]))["hooks"].get("UserPromptSubmit", [])
print(sum(h["command"].endswith('/hooks/category-context.sh"') for e in ups for h in e.get("hooks", [])))
PY
)
[ "$_hreg" = 1 ] && ok "H6: settings.hooks.json 의 UserPromptSubmit 에 category-context.sh 가 하나" \
  || ng "H6: settings.hooks.json 등록 수가 $_hreg 다$(_diag "$T/py.err")" "1"
HI="$KH/home"; rm -rf "$HI"; mkdir -p "$HI/.claude"
printf '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"other.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"mine.sh"}]},{"hooks":[{"type":"command","command":"/old/hooks/category-context.sh"}]}]}}\n' > "$HI/.claude/settings.json"
HOME="$HI" CLAUDE_HOME="$HI/.claude" bash "$_mt_repo/install.sh" --copy >/dev/null 2>&1
HOME="$HI" CLAUDE_HOME="$HI/.claude" bash "$_mt_repo/install.sh" --copy >/dev/null 2>&1
_hmrg=$(python3 - "$HI/.claude/settings.json" 2>"$T/py.err" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
cmds = lambda ev: [x["command"] for e in h.get(ev, []) for x in e.get("hooks", [])]
u, p = cmds("UserPromptSubmit"), cmds("PreToolUse")
print(sum("category-context.sh" in c for c in u), "mine.sh" in u, "/old/hooks/category-context.sh" in u,
      sum("preflight-gate.sh" in c for c in p), "other.sh" in p)
PY
)
[ "$_hmrg" = "1 True False 1 True" ] && ok "H6: install.sh 두 번 → 훅마다 하나, 옛 경로는 교체, 남의 항목(mine.sh·other.sh) 보존" \
  || ng "H6: install.sh 병합이 어긋난다 [$_hmrg]$(_diag "$T/py.err")" "1 True False 1 True"
# 테스트 오버레이를 되돌린다
if [ "$_kh_ov" = __unset__ ]; then unset PF_OVERLAY_DIR; else export PF_OVERLAY_DIR="$_kh_ov"; fi
