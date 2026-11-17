#!/bin/bash
# meta-test — 처음 보는 레포 확인 절차(profile.sh init · 카테고리 훅의 '프로필 없음' 줄, #47)
# meta-test.sh 가 lib.sh 다음에 source 한다 — lib.sh 의 ok·ng·$T 만 쓴다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 처음 보는 레포 확인 절차 (#47) =="
# 근거는 DECISIONS.md 2026-11-16 (처음 보는 레포 확인 절차).
# 설치본 사본에서 돈다 — profile.sh 는 자기 설치본의 profiles/ 에 쓰므로 실제 설치본에 돌리면 레포에 파일이 생긴다.
PI="$T/pinit"; rm -rf "$PI"; mkdir -p "$PI/root/hooks" "$PI/root/skills"
cp -RL "$HOME/.claude/skills/preflight" "$PI/root/skills/preflight" 2>/dev/null
cp "$HOME/.claude/hooks/category-context.sh" "$PI/root/hooks/"
PS="$PI/root/skills/preflight/profile.sh"; PCS="$PI/root/skills/preflight/category.sh"; PHK="$PI/root/hooks/category-context.sh"
PPROF="$PI/root/skills/preflight/profiles"
# 카테고리는 테스트 전용(meta-test/fixtures/overlay 의 fx-backend·fx-vault)을 이 사본의 categories/ 에 넣어 쓴다 — 설치본에 얹힌
# 조직 오버레이에 기대지 않게 오버레이는 이 절 동안 끈다. 기본 카테고리(fallback)도 끈다: "카테고리 없음" 경로를 그대로 본다
# (fallback 자체는 overlay.sh 가 본다).
_pi_ov="${PF_OVERLAY_DIR-__unset__}"; export PF_OVERLAY_DIR=""
cp -R "$MT_DIR/meta-test/fixtures/overlay/categories/fx-backend" "$MT_DIR/meta-test/fixtures/overlay/categories/fx-vault" "$PI/root/skills/preflight/categories/"
python3 - "$PI/root/skills/preflight/categories/categories.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop('fallback', None); d['categories'] += ['fx-backend', 'fx-vault']
json.dump(d, open(sys.argv[1], 'w'))
PY
# 픽스처: 표식(vault·backend·none) + origin(없으면 '-')
pirepo(){ local d="$PI/$1" o="$2"; shift 2; rm -rf "$d"; mkdir -p "$d"; git init -q -b main "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  for k in "$@"; do case "$k" in
    vault) printf '# rules\n' > "$d/VAULT_RULES.md" ;;
    backend) printf '{\n  "name": "svc",\n  "dependencies": {\n    "acme-core": "^3"\n  }\n}\n' > "$d/package.json" ;;
    none) printf 'x\n' > "$d/README.txt" ;;
  esac; done
  git -C "$d" add -A; git -C "$d" "com""mit" -qm base
  [ "$o" = - ] || git -C "$d" remote add origin "$o"; }
pirepo wiki git@github.com:Acme/Wiki.git vault
pirepo local - vault
pirepo plain https://github.com/Acme/Plain.git none
pirepo over git@github.com:Acme/Over.git vault backend
pirepo svc https://github.com/Acme/Svc.git backend
pirepo spaced 'git@github.com:Acme/Wi ki.git' vault
pihook(){ printf '{"hook_event_name":"UserPromptSubmit","prompt":"x","cwd":"%s"}' "$1" | env -u PF_ROOT "$PHK" > "$T/pi.out" 2>/dev/null; _phrc=$?; }
# 프로필 자리의 파일 목록(경로) — 생성·롤백을 파일 수가 아니라 집합으로 본다
pifiles(){ (cd "$PPROF" 2>/dev/null && find . -type f | LC_ALL=C sort); }
_pbase=$(pifiles)

# PI1 — 조회 출력의 origin: 슬러그 원문, 없으면 null
_po=$( { "$PCS" "$PI/wiki"; "$PCS" "$PI/local"; } 2>"$T/py.err" | python3 -c '
import json, sys
dec = json.JSONDecoder(); s = sys.stdin.read(); i = 0; out = []
while i < len(s):
    if s[i].isspace(): i += 1; continue
    o, i = dec.raw_decode(s, i); out.append(repr(o.get("origin", "<없음>")))
print(" ".join(out))' 2>>"$T/py.err"; _pytb $LINENO)
[ "$_po" = "'Acme/Wiki' None" ] && ok "PI1: category.sh 의 origin — 슬러그 원문 · origin 없으면 null" \
  || ng "PI1: category.sh origin 이 어긋난다 [$_po]$(_diag "$T/py.err")" "'Acme/Wiki' None"

# PI2 — 훅: 프로필 없는 레포에 추론 카테고리·근거·생성기 스킬(/harness-profile)과 대안 생성 명령을 안내하고, 파일을 쓰지 않는다
# 훅이 싣는 레포는 git 최상위(심링크를 푼 경로)다 — $T 가 /var 이면 /private/var 가 된다
_pwr=$(git -C "$PI/wiki" rev-parse --show-toplevel)
pihook "$PI/wiki"
_pwant="  프로필 없음 — 추론 카테고리 fx-vault(근거: VAULT_RULES.md) — 사용자가 확인하면 \`/harness-profile\`(이력 실측·규칙 승인 뒤 생성), 조정 없이 바로 만들려면 \`bash $PS init $_pwr\` (확인 없이 실행하지 않는다)"
[ "$_phrc" = 0 ] && grep -qxF -- "$_pwant" "$T/pi.out" && [ "$(pifiles)" = "$_pbase" ] \
  && ok "PI2: 훅 → '프로필 없음 — 추론 카테고리(근거) — /harness-profile, 대안 생성 명령' 한 줄, 프로필은 쓰지 않는다" \
  || ng "PI2: 훅 안내가 어긋난다 [rc=$_phrc] $(tr '\n' '|' < "$T/pi.out")" "$_pwant · 프로필 자리 변화 없음"
# 명령의 경로는 셸 인용된다 — 공백 든 레포 경로도 그대로 실행된다
pirepo 'sp ace' git@github.com:Acme/Space.git vault
pihook "$PI/sp ace"
grep -qF "init '$(git -C "$PI/sp ace" rev-parse --show-toplevel)'\`" "$T/pi.out" && ok "PI2: 공백 든 레포 경로는 명령 안에서 인용된다" \
  || ng "PI2: 공백 경로 인용이 없다 [$(grep '프로필 없음' "$T/pi.out")]" "init '<경로>'"

# PI3 — 훅: origin 없음은 안내만, 카테고리 없음·겹침은 프로필 줄을 내지 않는다
pihook "$PI/local"
[ "$_phrc" = 0 ] && grep -qxF '  프로필 없음 — origin 리모트가 없어 프로필 키를 정할 수 없다(만들지 않는다)' "$T/pi.out" && ! grep -q 'profile.sh' "$T/pi.out" \
  && ok "PI3: origin 없는 레포 → 키를 정할 수 없다는 안내, 생성 명령 없음" \
  || ng "PI3: origin 없음 안내가 어긋난다 [rc=$_phrc] $(tr '\n' '|' < "$T/pi.out")" "origin 없음 안내 · 명령 없음"
_pbad=''
pihook "$PI/plain"; { [ "$_phrc" = 0 ] && [ "$(wc -l < "$T/pi.out" | tr -d ' ')" = 1 ] && ! grep -q '프로필' "$T/pi.out"; } || _pbad="$_pbad 카테고리없음"
pihook "$PI/over"; { [ "$_phrc" = 0 ] && grep -q '겹침' "$T/pi.out" && ! grep -q '프로필 없음' "$T/pi.out"; } || _pbad="$_pbad 겹침"
[ -z "$_pbad" ] && ok "PI3: 카테고리 없음·겹침 → 프로필 줄을 내지 않는다" || ng "PI3: 프로필 줄이 나왔다:$_pbad" "없음"

# PI4 — init 이 만들지 않는 경우: exit 3, 프로필 자리 변화 없음
_pbad=''
pirefuse(){ local want="$1"; shift; bash "$PS" init "$@" > "$T/pi.out" 2> "$T/pi.err"; local rc=$?
  { [ "$rc" = 3 ] && grep -qF -- "$want" "$T/pi.err" && [ "$(pifiles)" = "$_pbase" ]; } || _pbad="$_pbad [$*](rc=$rc $(head -1 "$T/pi.err"))"; }
pirefuse 'origin 리모트가 없어' "$PI/local"
pirefuse '카테고리 없는 레포에는 만들지 않는다' "$PI/plain"
pirefuse '카테고리 겹침은 프로필로 풀지 않는다' "$PI/over"
pirefuse '추론 카테고리 fx-vault 와 다르다' "$PI/wiki" --category shell-tool
pirefuse '카테고리 없는 레포에는 만들지 않는다' "$PI/plain" --category fx-vault
[ -z "$_pbad" ] && ok "PI4: origin 없음·카테고리 없음·겹침·--category 불일치 → exit 3, 파일 없음" \
  || ng "PI4: 거부가 어긋난다:$_pbad" "exit 3 · 사유 · 프로필 자리 변화 없음"
_pbad=''
for _a in "" "init" "make $PI/wiki" "init $PI/wiki --category" "init $PI/wiki --bogus"; do
  # shellcheck disable=SC2086
  bash "$PS" $_a >/dev/null 2>&1; _rc=$?; [ "$_rc" = 2 ] || _pbad="$_pbad [$_a](rc=$_rc)"
done
bash "$PS" init "$PI/nowhere" >/dev/null 2>&1; _rc=$?; [ "$_rc" = 2 ] || _pbad="$_pbad [git아님](rc=$_rc)"
[ -z "$_pbad" ] && [ "$(pifiles)" = "$_pbase" ] && ok "PI4: 인자 오류·git 레포 아님 → exit 2" || ng "PI4: 인자 오류 처리가 어긋난다:$_pbad" "exit 2"

# PI5 — 엔진 버전을 못 읽으면 만들지 않는다. 다른 프로필이 없는 사본에서 본다 — 적재기가 먼저 거르지 않게
PI2R="$PI/noeng"; rm -rf "$PI2R"; mkdir -p "$PI2R/skills"; cp -R "$PI/root/skills/preflight" "$PI2R/skills/preflight"
rm -rf "$PI2R/skills/preflight/profiles"; printf 'next\n' > "$PI2R/skills/preflight/ENGINE_VERSION"
bash "$PI2R/skills/preflight/profile.sh" init "$PI/wiki" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 3 ] && grep -qF 'ENGINE_VERSION)을 읽지 못했다' "$T/pi.err" && [ ! -e "$PI2R/skills/preflight/profiles" ] \
  && ok "PI5: ENGINE_VERSION 형식 아님 → exit 3, profiles/ 를 만들지 않는다" \
  || ng "PI5: 엔진 버전 거부가 어긋난다 [rc=$_rc] $(head -1 "$T/pi.err")" "exit 3 · ENGINE_VERSION 못 읽음 · profiles/ 없음"

# PI6 — 적재기가 받지 않는 프로필은 지운다. origin 슬러그에 공백이 들면 조회는 슬러그를 내지만 적재기는 repo 형식으로 거부한다
bash "$PS" init "$PI/spaced" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 3 ] && grep -qF '적재기가 새 프로필을 받지 않아 지웠다' "$T/pi.err" && [ "$(pifiles)" = "$_pbase" ] && [ ! -e "$PPROF/acme" ] \
  && "$PCS" "$PI/wiki" >/dev/null 2>&1 \
  && ok "PI6: 적재 확인 실패 → 쓴 파일과 새로 만든 owner 디렉터리를 지우고 exit 3, 다른 레포 조회는 그대로" \
  || ng "PI6: 롤백이 어긋난다 [rc=$_rc] $(head -1 "$T/pi.err") · $(pifiles | tr '\n' ' ')" "exit 3 · 파일·디렉터리 없음 · 조회 정상"

# PI7 — 생성: 추론 카테고리가 기본값, 내용은 repo(원문)·category·engineVersion(ENGINE_VERSION 문자열)·adjustments []
_pver=$(head -n 1 "$PI/root/skills/preflight/ENGINE_VERSION" | tr -d '[:space:]')
bash "$PS" init "$PI/wiki" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
_pc=$(python3 - "$PPROF/acme/wiki.json" "$_pver" 2>"$T/py.err" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d == {"repo": "Acme/Wiki", "category": "fx-vault", "engineVersion": sys.argv[2], "adjustments": []}
      and type(d["engineVersion"]) is str and list(d) == ["repo", "category", "engineVersion", "adjustments"])
PY
)
[ "$_rc" = 0 ] && [ "$_pc" = True ] && grep -qF "프로필 생성: $PPROF/acme/wiki.json" "$T/pi.out" \
  && ok "PI7: init(카테고리 생략) → profiles/acme/wiki.json, repo 원문·추론 카테고리·engineVersion \"$_pver\"·조정 없음" \
  || ng "PI7: 생성이 어긋난다 [rc=$_rc 내용=$_pc] $(head -1 "$T/pi.err")$(_diag "$T/py.err")" "exit 0 · 정확한 네 키"
_pg=$("$PCS" "$PI/wiki" 2>"$T/py.err" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("profile") or {}).get("path"))' 2>>"$T/py.err"; _pytb $LINENO)
[ "$_pg" = profiles/acme/wiki.json ] && ok "PI7: 생성 뒤 조회가 그 파일을 이 레포의 프로필로 읽는다" \
  || ng "PI7: 생성 뒤 조회 profile.path=$_pg$(_diag "$T/py.err")" "profiles/acme/wiki.json"
pihook "$PI/wiki"
[ "$_phrc" = 0 ] && grep -qF "$PI/wiki: fx-vault" "$T/pi.out" && ! grep -q '프로필 없음' "$T/pi.out" \
  && ok "PI7: 프로필이 생긴 레포 → 훅이 '프로필 없음' 을 내지 않는다" || ng "PI7: 프로필 있는데 안내가 나왔다 $(tr '\n' '|' < "$T/pi.out")" "프로필 없음 줄 없음"
# 이미 있으면 덮어쓰지 않는다
cp "$PPROF/acme/wiki.json" "$T/pi.before"
bash "$PS" init "$PI/wiki" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 3 ] && grep -qF '이미 프로필이 있다: profiles/acme/wiki.json' "$T/pi.err" && cmp -s "$T/pi.before" "$PPROF/acme/wiki.json" \
  && ok "PI7: 다시 init → exit 3 '이미 있다', 파일 그대로" || ng "PI7: 재실행이 어긋난다 [rc=$_rc] $(head -1 "$T/pi.err")" "exit 3 · 파일 불변"

# PI8 — --category 가 추론과 같으면 만든다(확인의 명시). 원문 대소문자는 repo 에, 자리는 소문자
bash "$PS" init "$PI/svc" --category fx-backend > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
_pc=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["category"])' "$PPROF/acme/svc.json" 2>"$T/py.err")
[ "$_rc" = 0 ] && [ "$_pc" = "Acme/Svc fx-backend" ] && ok "PI8: --category 가 추론과 같으면 생성(profiles/acme/svc.json)" \
  || ng "PI8: --category 일치 생성이 어긋난다 [rc=$_rc $_pc] $(head -1 "$T/pi.err")$(_diag "$T/py.err")" "exit 0 · Acme/Svc fx-backend"

# PI9 — 롤백은 EXIT trap 에 묶여 있다: 쓰기와 적재 확인 사이에서 끊겨도(TERM) 쓴 파일·새 디렉터리가 남지 않는다.
# 사본의 category.sh 를 감싸 두 번째 호출(적재 확인)에서 profile.sh 에 TERM 을 보낸다. 첫 호출은 진짜 조회다.
PIK="$PI/killroot"; rm -rf "$PIK"; mkdir -p "$PIK/skills"; cp -R "$PI/root/skills/preflight" "$PIK/skills/preflight"
_pks="$PIK/skills/preflight"; mv "$_pks/category.sh" "$_pks/category.real.sh"
cat > "$_pks/category.sh" <<'SH'
#!/bin/bash
if [ -e "$PI_MARK" ]; then
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$PI_PIDF" ] && break; sleep 0.1; done
  kill -TERM "$(cat "$PI_PIDF")"; exit 0
fi
: > "$PI_MARK"; exec bash "$(dirname "$0")/category.real.sh" "$@"
SH
_pkf="$_pks/profiles/kilo/kill.json"
pirepo kill git@github.com:Kilo/Kill.git vault
rm -f "$T/pi.mark" "$T/pi.pid"
PI_MARK="$T/pi.mark" PI_PIDF="$T/pi.pid" bash "$_pks/profile.sh" init "$PI/kill" > "$T/pi.out" 2> "$T/pi.err" & _pkp=$!
echo "$_pkp" > "$T/pi.pid"; wait "$_pkp"; _rc=$?
[ "$_rc" = 143 ] && [ -e "$T/pi.mark" ] && [ ! -e "$_pkf" ] && [ ! -e "$_pks/profiles/kilo" ] \
  && ok "PI9: 적재 확인 중 TERM → exit 143, 쓴 프로필과 새 owner 디렉터리를 지운다" \
  || ng "PI9: 끊김 롤백이 어긋난다 [rc=$_rc 표식=$([ -e "$T/pi.mark" ] && echo 있음 || echo 없음) 파일=$([ -e "$_pkf" ] && echo 남음 || echo 없음)] $(head -1 "$T/pi.err")" "exit 143 · 파일·디렉터리 없음"
# profiles/ 자체가 없던 설치본 — 롤백이 profiles/ 까지 지운다(빈 디렉터리를 남기지 않는다)
PIE="$PI/emptyroot"; rm -rf "$PIE"; mkdir -p "$PIE/skills"; cp -R "$PI/root/skills/preflight" "$PIE/skills/preflight"; rm -rf "$PIE/skills/preflight/profiles"
bash "$PIE/skills/preflight/profile.sh" init "$PI/spaced" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 3 ] && grep -qF '적재기가 새 프로필을 받지 않아 지웠다' "$T/pi.err" && [ ! -e "$PIE/skills/preflight/profiles" ] \
  && ok "PI9: profiles/ 가 없던 설치본에서 적재 확인 실패 → profiles/ 까지 지운다" \
  || ng "PI9: profiles/ 가 남았다 [rc=$_rc] $(head -1 "$T/pi.err")" "exit 3 · profiles/ 없음"

# PI10 — 쓰는 중에 끊겨도 남기지 않는다. python3 를 감싸 프로필 쓰기 호출이 끝난 직후(걸기 전) profile.sh 에 TERM 을 보낸다.
# 쓰기가 끝난 뒤에야 지울 대상을 세우면 이 자리에서 확인되지 않은 파일이 남는다.
_prpy=$(command -v python3); PIW="$T/pishim"; rm -rf "$PIW"; mkdir -p "$PIW"
cat > "$PIW/python3" <<SH
#!/bin/bash
case "\$*" in *'open(sys.argv[1], "x"'*) "$_prpy" "\$@"; _r=\$?; kill -TERM "\$PPID"; exit \$_r ;; esac
exec "$_prpy" "\$@"
SH
chmod +x "$PIW/python3"
pirepo write git@github.com:Wrt/Write.git vault
PATH="$PIW:$PATH" bash "$PS" init "$PI/write" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 143 ] && [ ! -e "$PPROF/wrt" ] && "$PCS" "$PI/wiki" >/dev/null 2>&1 \
  && ok "PI10: 프로필 쓰기 직후 TERM → exit 143, 임시 파일·프로필·새 owner 디렉터리가 남지 않는다" \
  || ng "PI10: 쓰는 중 끊김 롤백이 어긋난다 [rc=$_rc 남은것=$(ls -A "$PPROF/wrt" 2>/dev/null | tr '\n' ' ')] $(head -1 "$T/pi.err")" "exit 143 · profiles/wrt 없음"
_pleft=$(find "$PPROF" -name '.*.tmp' 2>/dev/null | wc -l | tr -d ' ')
[ "$_pleft" = 0 ] && ok "PI10: 성공·거부·끊김을 거친 뒤 profiles/ 에 숨김 임시 파일이 0개" \
  || ng "PI10: 숨김 임시 파일이 $_pleft 개 남았다" "0"

# PI11 — 걸기 전에 같은 자리에 남의 파일이 생기면 ln 이 실패하고, 롤백은 그 파일을 지우지 않는다(이 실행이 건 파일만 지운다).
# python3 를 감싸 임시 파일을 쓴 직후 같은 자리에 다른 내용의 파일을 만든다.
cat > "$PIW/python3" <<SH
#!/bin/bash
case "\$*" in *'open(sys.argv[1], "x"'*)
  "$_prpy" "\$@"; _r=\$?; _t="\${@: -1}"; _b=\$(basename "\$_t"); _b=\${_b#.}; _b=\${_b%.*.tmp}
  printf 'foreign\n' > "\$(dirname "\$_t")/\$_b"; exit \$_r ;; esac
exec "$_prpy" "\$@"
SH
pirepo race git@github.com:Acme/Race.git vault
PATH="$PIW:$PATH" bash "$PS" init "$PI/race" > "$T/pi.out" 2> "$T/pi.err"; _rc=$?
[ "$_rc" = 3 ] && grep -qF '를 걸지 못했다' "$T/pi.err" && [ "$(cat "$PPROF/acme/race.json" 2>/dev/null)" = foreign ] \
  && [ "$(find "$PPROF" -name '.*.tmp' | wc -l | tr -d ' ')" = 0 ] \
  && ok "PI11: 걸기 전에 남의 파일이 생기면 exit 3, 그 파일은 그대로 두고 임시 파일만 지운다" \
  || ng "PI11: 경합 처리가 어긋난다 [rc=$_rc 내용=$(cat "$PPROF/acme/race.json" 2>/dev/null)] $(head -1 "$T/pi.err")" "exit 3 · foreign 보존 · 임시 파일 0"
rm -f "$PPROF/acme/race.json"
if [ "$_pi_ov" = __unset__ ]; then unset PF_OVERLAY_DIR; else export PF_OVERLAY_DIR="$_pi_ov"; fi
