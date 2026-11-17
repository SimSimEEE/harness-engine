#!/bin/bash
# meta-test — 오버레이 루트(lib.sh pf_overlay_dir)·기본 카테고리(fallback)·루트 사이 겹침
# meta-test.sh 가 lib.sh 다음에 source 한다 — lib.sh 의 ok·ng·_diag·$T·$CL·ixrepo 를 쓴다. 순서의 정본은 meta-test.sh 머리말이다.
# 근거는 DECISIONS.md 2026-11-17 「엔진을 독립 레포로 분리했다」.

echo "== 오버레이 루트 · 기본 카테고리 (fallback) =="
OVT="$T/ovl"; rm -rf "$OVT"; mkdir -p "$OVT"
_ov_saved="${PF_OVERLAY_DIR-__unset__}"
OV="$OVT/overlay"; mkdir -p "$OV"; cp -R "$MT_DIR/meta-test/fixtures/overlay/categories" "$OV/categories"
CSO="$HOME/.claude/skills/preflight/category.sh"
# 픽스처 레포: backend(acme-core 의존) · plain(신호 없음) — origin 은 프로필 절에서 쓴다
ovrepo(){ local d="$OVT/$1" k="$2" o="$3"; ixrepo "$d"
  case "$k" in
    backend) printf '{\n  "name": "svc",\n  "dependencies": {\n    "acme-core": "^3"\n  }\n}\n' > "$d/package.json" ;;
    plain) printf 'x\n' > "$d/README.txt" ;;
  esac
  git -C "$d" add -A; git -C "$d" "$G" -qm base; [ -z "$o" ] || git -C "$d" remote add origin "$o"; }
ovrepo backend backend git@github.com:Acme/Back.git
ovrepo plain plain git@github.com:Acme/Plain.git
ovq(){ "$CSO" "$1" 2>"$T/ov.err" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>>"$T/ov.err"; }

# O1 — 오버레이의 카테고리를 엔진 카테고리 다음에 읽는다. 오버레이를 끄면 같은 레포가 기본 카테고리로 간다
_o1=$(PF_OVERLAY_DIR="$OV" ovq "$OVT/backend" 'd["category"], d["evidence"].get("fx-backend")')
_o1b=$(PF_OVERLAY_DIR="" ovq "$OVT/backend" 'd["category"]')
[ "$_o1" = "fx-backend ['package.json: dependencies.acme-core']" ] && [ "$_o1b" = generic ] \
  && ok "O1: 오버레이 카테고리로 분류하고, 오버레이를 끄면 기본 카테고리다" \
  || ng "O1: 오버레이 적재가 어긋난다 [$_o1 / 끔: $_o1b]$(_diag "$T/ov.err")" "fx-backend · 근거 / generic"

# O2 — 신호가 없으면 기본 카테고리(fallback), 근거가 그렇게 남는다. 분류(classify.sh)도 같은 카테고리다
_o2=$(PF_OVERLAY_DIR="$OV" ovq "$OVT/plain" 'd["category"], d["evidence"]["generic"]')
_o2c=$(PF_OVERLAY_DIR="$OV" "$CL" "$OVT/plain" commit 2>"$T/ov.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["category"])' 2>>"$T/ov.err")
[ "$_o2" = "generic ['fallback — 다른 카테고리의 신호가 없다']" ] && [ "$_o2c" = generic ] \
  && ok "O2: 신호 없는 레포 → generic, 근거 fallback · 조회와 분류가 같다" \
  || ng "O2: 기본 카테고리가 어긋난다 [$_o2 / 분류 $_o2c]$(_diag "$T/ov.err")" "generic · fallback"

# O3 — 루트 사이 이름 겹침 · 설정했는데 디렉터리가 아님 · fallback 둘 · fallback 이 선언 밖 → 적재 실패(exit 3)
ovfail(){ local want="$1"; shift; "$@" > "$T/ov.out" 2> "$T/ov.err"; local rc=$?
  { [ "$rc" = 3 ] && grep -qF -- "$want" "$T/ov.err" && ! grep -q '"category"' "$T/ov.out"; } || _o3="$_o3 [$want rc=$rc $(head -1 "$T/ov.err")]"; }
_o3=''
OD="$OVT/dup"; rm -rf "$OD"; cp -R "$OV" "$OD"; cp -R "$OD/categories/fx-vault" "$OD/categories/generic"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["categories"].append("generic"); json.dump(d,open(p,"w"))' "$OD/categories/categories.json"
PF_OVERLAY_DIR="$OD" ovfail '카테고리 이름이 엔진과 오버레이에서 겹친다: generic' "$CSO" "$OVT/plain"
PF_OVERLAY_DIR="$OVT/nowhere" ovfail '가 디렉터리가 아니다' "$CSO" "$OVT/plain"
OF="$OVT/fb2"; rm -rf "$OF"; cp -R "$OV" "$OF"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["fallback"]="fx-vault"; json.dump(d,open(p,"w"))' "$OF/categories/categories.json"
PF_OVERLAY_DIR="$OF" ovfail 'fallback 이 둘이다' "$CSO" "$OVT/plain"
OF2="$OVT/fb3"; rm -rf "$OF2"; cp -R "$OV" "$OF2"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["fallback"]="nope"; json.dump(d,open(p,"w"))' "$OF2/categories/categories.json"
PF_OVERLAY_DIR="$OF2" ovfail '는 같은 선언의 카테고리가 아니다' "$CSO" "$OVT/plain"
PF_OVERLAY_DIR="$OF2" ovfail '는 같은 선언의 카테고리가 아니다' "$CL" "$OVT/plain" commit
[ -z "$_o3" ] && ok "O3: 이름 겹침·오버레이 경로 없음·fallback 둘·선언 밖 fallback → 조회·분류 exit 3, 출력 없음" \
  || ng "O3: 적재 실패 처리가 어긋난다:$_o3" "exit 3 · 사유"

# O4 — 카테고리 없이 프로필만 둔 오버레이도 된다 · 오버레이 프로필을 읽는다 · 같은 슬러그가 두 루트에 있으면 적재 실패
_ev=$(head -n 1 "$HOME/.claude/skills/preflight/ENGINE_VERSION" | tr -d '[:space:]')
OP="$OVT/profonly"; mkdir -p "$OP/profiles/acme"
printf '{"repo":"Acme/Plain","category":"generic","engineVersion":"%s","adjustments":[]}\n' "$_ev" > "$OP/profiles/acme/plain.json"
_o4=$(PF_OVERLAY_DIR="$OP" ovq "$OVT/plain" 'd["category"], d["profile"]["path"]')
[ "$_o4" = "generic profiles/acme/plain.json" ] && ok "O4: 카테고리 없는 오버레이의 프로필을 읽는다 (프로필이 기본 카테고리를 고정)" \
  || ng "O4: 오버레이 프로필을 못 읽었다 [$_o4]$(_diag "$T/ov.err")" "generic profiles/acme/plain.json"
OC="$OVT/copy"; rm -rf "$OC"; mkdir -p "$OC/skills"; cp -RL "$HOME/.claude/skills/preflight" "$OC/skills/preflight" 2>/dev/null
rm -f "$OC/skills/preflight/config.json"; rm -rf "$OC/skills/preflight/profiles"; mkdir -p "$OC/skills/preflight/profiles/acme"
cp "$OP/profiles/acme/plain.json" "$OC/skills/preflight/profiles/acme/plain.json"
_o3=''; PF_OVERLAY_DIR="$OP" ovfail '이 엔진과 오버레이 양쪽에 있다' "$OC/skills/preflight/category.sh" "$OVT/plain"
[ -z "$_o3" ] && ok "O4: 같은 슬러그의 프로필이 엔진·오버레이 양쪽에 있으면 exit 3" || ng "O4: 프로필 겹침이 통과했다:$_o3" "exit 3"
rm -rf "$OC/skills/preflight/profiles"

# O5 — 오버레이가 설정돼 있으면 profile.sh init 은 오버레이의 profiles/ 에 쓰고 엔진 설치본에는 쓰지 않는다
OW="$OVT/write"; rm -rf "$OW"; cp -R "$OV" "$OW"
PF_OVERLAY_DIR="$OW" bash "$OC/skills/preflight/profile.sh" init "$OVT/backend" > "$T/ov.out" 2> "$T/ov.err"; _rc=$?
_o5=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["category"])' "$OW/profiles/acme/back.json" 2>>"$T/ov.err")
[ "$_rc" = 0 ] && [ "$_o5" = "Acme/Back fx-backend" ] && [ ! -e "$OC/skills/preflight/profiles" ] \
  && ok "O5: init → 오버레이 profiles/acme/back.json, 엔진 설치본의 profiles/ 는 생기지 않는다" \
  || ng "O5: 프로필 자리가 어긋난다 [rc=$_rc $_o5]$(_diag "$T/ov.err")" "exit 0 · 오버레이에 생성 · 엔진 쪽 없음"

# O6 — 환경변수가 없으면 설치본 config.json 의 overlayDir 를 쓴다($HOME 전개). 빈 환경변수는 "오버레이 없음" 이다
printf '{"overlayDir": "%s"}\n' "$OV" > "$OC/skills/preflight/config.json"
_o6=$( (unset PF_OVERLAY_DIR; "$OC/skills/preflight/category.sh" "$OVT/backend" 2>"$T/ov.err") | python3 -c 'import json,sys; print(json.load(sys.stdin)["category"])' 2>>"$T/ov.err")
_o6e=$(PF_OVERLAY_DIR="" "$OC/skills/preflight/category.sh" "$OVT/backend" 2>>"$T/ov.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["category"])' 2>>"$T/ov.err")
mkdir -p "$OVT/home/ovh"; cp -R "$OV/categories" "$OVT/home/ovh/categories"
printf '{"overlayDir": "$HOME/ovh"}\n' > "$OC/skills/preflight/config.json"
_o6h=$( (unset PF_OVERLAY_DIR; HOME="$OVT/home" "$OC/skills/preflight/category.sh" "$OVT/backend" 2>>"$T/ov.err") | python3 -c 'import json,sys; print(json.load(sys.stdin)["category"])' 2>>"$T/ov.err")
[ "$_o6" = fx-backend ] && [ "$_o6e" = generic ] && [ "$_o6h" = fx-backend ] \
  && ok "O6: config.json overlayDir 를 쓰고(\$HOME 전개), 빈 PF_OVERLAY_DIR 은 그것을 끈다" \
  || ng "O6: overlayDir 해석이 어긋난다 [$_o6 / 빈 env $_o6e / \$HOME $_o6h]$(_diag "$T/ov.err")" "fx-backend / generic / fx-backend"
rm -f "$OC/skills/preflight/config.json"

# O7 — 이름으로 카테고리 디렉터리를 찾는 자리(receipt.sh)의 루트 목록: 엔진 다음 오버레이, 오버레이에 categories/ 가 없으면 엔진만
_o7=$(PF_OVERLAY_DIR="$OV" bash -c '. "$1/lib.sh"; pf_category_roots' _ "$OC/skills/preflight")
_o7b=$(PF_OVERLAY_DIR="$OP" bash -c '. "$1/lib.sh"; pf_category_roots' _ "$OC/skills/preflight")
[ "$_o7" = "$OC/skills/preflight/categories:$OV/categories" ] && [ "$_o7b" = "$OC/skills/preflight/categories" ] \
  && ok "O7: pf_category_roots — 엔진:오버레이 순, 오버레이 카테고리가 없으면 엔진만" \
  || ng "O7: 카테고리 루트 목록이 어긋난다 [$_o7 | $_o7b]" "엔진:오버레이 / 엔진"
[ "$(nocc "$HOME/.claude/skills/preflight/receipt.sh" 'PF_CATS="$(pf_category_roots)"')" = 2 ] \
  && ! grep -qF "pwd)/categories\"" "$HOME/.claude/skills/preflight/receipt.sh" \
  && ok "O7: receipt.sh 는 카테고리 디렉터리를 pf_category_roots 로만 찾는다 (두 자리)" \
  || ng "O7: receipt.sh 에 엔진 categories/ 고정 경로가 남았다" "pf_category_roots 2곳 · 고정 경로 0"

if [ "$_ov_saved" = __unset__ ]; then unset PF_OVERLAY_DIR; else export PF_OVERLAY_DIR="$_ov_saved"; fi
