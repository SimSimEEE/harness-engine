#!/bin/bash
# meta-test — 프로필 생성기의 결정론 부분(profile-measure.sh · profile.sh init --adjustments, #47 생성기 스킬 흐름)
# meta-test.sh 가 profile-init.sh 다음에 source 한다 — lib.sh 의 ok·ng·_diag·$T 만 쓴다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 프로필 생성기 — 현황 점검·이력 실측·승인 조정 기록 (#47) =="
# 근거는 DECISIONS.md 「프로필 생성기」. 설치본 사본에서 돈다 — profile.sh 는 자기 설치본의 profiles/ 에 쓴다.
PM="$T/pmeas"; rm -rf "$PM"; mkdir -p "$PM/root/skills"
cp -RL "$HOME/.claude/skills/preflight" "$PM/root/skills/preflight" 2>/dev/null
PMS="$PM/root/skills/preflight/profile-measure.sh"; PMP="$PM/root/skills/preflight/profile.sh"
PMC="$PM/root/skills/preflight/category.sh"; PMPROF="$PM/root/skills/preflight/profiles"
# 카테고리는 테스트 전용(fx-backend·fx-vault)을 이 사본에 넣어 쓰고, 오버레이·기본 카테고리는 끈다(profile-init.sh 와 같은 이유).
_pm_ov="${PF_OVERLAY_DIR-__unset__}"; export PF_OVERLAY_DIR=""
cp -R "$MT_DIR/meta-test/fixtures/overlay/categories/fx-backend" "$MT_DIR/meta-test/fixtures/overlay/categories/fx-vault" "$PM/root/skills/preflight/categories/"
python3 - "$PM/root/skills/preflight/categories/categories.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop('fallback', None); d['categories'] += ['fx-backend', 'fx-vault']
json.dump(d, open(sys.argv[1], 'w'))
PY
# 커밋 날짜를 하나씩 올린다 — 같은 초의 커밋은 rev-list 순서가 정해지지 않는다
_pmn=0
pmc(){ local d="$1" m="$2"; _pmn=$((_pmn+1)); git -C "$d" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:$(printf %02d $_pmn)Z" GIT_COMMITTER_DATE="2026-01-01T00:00:$(printf %02d $_pmn)Z" \
    git -C "$d" "com""mit" -qm "$m"; }
pminit(){ local d="$1"; rm -rf "$d"; mkdir -p "$d"; git init -q -b main "$d"; git -C "$d" config user.email t@t; git -C "$d" config user.name t; }

# 픽스처 이력(fx-vault 카테고리). 루트 커밋과 머지 커밋은 실측에서 빠진다 → 재분류 대상 6개:
#   c1 feat a.sh(셸 — test-runner 미선택) · c2 docs n.md(코드 없음) · c3 fix a.sh(c1 의 거리 2 수정, 2줄)
#   c4 feat b.js(test-runner 선택) · c5 fix(b) b.js(c4 의 거리 1 수정, 2줄) · side chore c.txt(코드 없음) · 머지
PMR="$PM/tool"; pminit "$PMR"
printf '# rules\n' > "$PMR/VAULT_RULES.md"; printf 'x\n' > "$PMR/README.txt"; pmc "$PMR" "base"
printf 'echo one\n' > "$PMR/a.sh"; pmc "$PMR" "feat: add a.sh"
printf 'note\n' > "$PMR/n.md"; pmc "$PMR" "docs: note"
printf 'echo two\n' > "$PMR/a.sh"; pmc "$PMR" "fix: a.sh bug"
printf 'let b = 1\n' > "$PMR/b.js"; pmc "$PMR" "feat: add b.js"
printf 'let b = 2\n' > "$PMR/b.js"; pmc "$PMR" "fix(b): typo"
git -C "$PMR" checkout -qb side; printf 'c\n' > "$PMR/c.txt"; pmc "$PMR" "chore: side"
git -C "$PMR" checkout -q main
GIT_COMMITTER_DATE="2026-01-01T00:00:59Z" GIT_AUTHOR_DATE="2026-01-01T00:00:59Z" git -C "$PMR" merge -q --no-ff -m "Merge side" side
git -C "$PMR" remote add origin git@github.com:Pm/Tool.git
PMPLAIN="$PM/plain"; pminit "$PMPLAIN"; printf 'x\n' > "$PMPLAIN/main.py"; pmc "$PMPLAIN" "base"
git -C "$PMPLAIN" remote add origin git@github.com:Pm/Plain.git
PMNOO="$PM/noorigin"; pminit "$PMNOO"; printf '# r\n' > "$PMNOO/VAULT_RULES.md"; pmc "$PMNOO" "base"
pmjq(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>"$T/py.err"; }

# PM1 — status: 다음 단계와 멈춤 사유를 스크립트가 정한다. 멈춤도 exit 0 이다
_pbad=''
bash "$PMS" status "$PMR" > "$T/pm.json" 2>"$T/pm.err"; _rc=$?
_pv=$(pmjq "$T/pm.json" 'd["next"], d["category"], d["origin"], d["profile"], d["stack"]["nonMergeCommits"], d["engineVersion"]')
[ "$_rc" = 0 ] && [ "$_pv" = "measure fx-vault Pm/Tool None 7 $(head -n1 "$PM/root/skills/preflight/ENGINE_VERSION" | tr -d '[:space:]')" ] \
  || _pbad="$_pbad [measure rc=$_rc $_pv]"
pmstop(){ local want="$1"; shift; bash "$PMS" status "$@" > "$T/pm.json" 2>"$T/pm.err"; local rc=$?
  local v; v=$(pmjq "$T/pm.json" 'd["next"] + "|" + d["reason"]')
  { [ "$rc" = 0 ] && [ "${v%%|*}" = stop ] && case "$v" in *"$want"*) true ;; *) false ;; esac; } || _pbad="$_pbad [$*](rc=$rc ${v:0:80})"; }
pmstop '새 카테고리는 여기서 만들지 않는다' "$PMPLAIN"
pmstop 'origin 리모트가 없어' "$PMNOO"
mkdir -p "$PMPROF/pm"; printf '{"repo":"Pm/Tool","category":"fx-vault","engineVersion":"%s","adjustments":[]}\n' \
  "$(head -n1 "$PM/root/skills/preflight/ENGINE_VERSION" | tr -d '[:space:]')" > "$PMPROF/pm/tool.json"
pmstop '이미 프로필이 있다: profiles/pm/tool.json' "$PMR"
rm -rf "$PMPROF/pm"
printf '{"name":"x","dependencies":{"acme-core":"^3"}}\n' > "$PMPLAIN/package.json"; printf '# r\n' > "$PMPLAIN/VAULT_RULES.md"
git -C "$PMPLAIN" add -A
pmstop '조회 실패(exit 3): 카테고리 판정이 겹친다' "$PMPLAIN"
git -C "$PMPLAIN" rm -q --cached package.json VAULT_RULES.md; rm -f "$PMPLAIN/package.json" "$PMPLAIN/VAULT_RULES.md"
[ -z "$_pbad" ] && ok "PM1: status → 다음 단계(measure)·카테고리·origin·커밋 수 / 카테고리 없음·origin 없음·프로필 있음·겹침은 stop(exit 0)" \
  || ng "PM1: status 가 어긋난다:$_pbad$(_diag "$T/py.err")" "next/reason 이 경우마다 맞다"

# PM2 — measure: 실제 분류기로 재분류한 값. 루트·머지 커밋은 빠지고, 수정 커밋은 제목+파일 겹침+창으로 센다
_pmlog="$T/pm.log"; rm -f "$_pmlog"
_pmstate(){ { git -C "$PMR" rev-parse HEAD; git -C "$PMR" ls-files -s; git -C "$PMR" status --porcelain; git -C "$PMR" for-each-ref;
  git -C "$PMR" worktree list --porcelain; git -C "$PMR" remote -v; ls -A "$(git -C "$PMR" rev-parse --absolute-git-dir)"; } | cksum; }
_pmbefore=$(_pmstate)
PF_LOG="$_pmlog" bash "$PMS" measure "$PMR" --window 5 > "$T/pm.m.json" 2>"$T/pm.err"; _rc=$?
_pv=$(pmjq "$T/pm.m.json" '"|".join(str(x) for x in [d["scanned"], len(d["unclassified"]), d["origin"], sorted(c["id"] for c in d["candidates"])] + [
  (lambda a: (a["violationRate"]["skipped"], a["violationRate"]["total"], a["impact"]["skippedFollowedByFix"], a["impact"]["selected"],
              a["impact"]["selectedFollowedByFix"], a["recoveryCost"]["fixLinesMedian"], a["recoveryCost"]["fixDistanceMedian"]))(c["axes"])
  for c in sorted(d["candidates"], key=lambda c: c["id"])] + [next(c for c in d["candidates"] if c["lane"]=="code-reviewer")["axes"]["violationRate"]["reasons"]])')
_pwant="6|0|Pm/Tool|['force-code-reviewer-commit', 'force-crossrepo-impact-commit', 'force-test-runner-commit']|(6, 6, 2, 0, 0, 2.0, 1.5)|(6, 6, 2, 0, 0, 2.0, 1.5)|(4, 6, 1, 2, 1, 2, 2)|{'no-review-flag': 4, 'no-code-change': 2}"
[ "$_rc" = 0 ] && [ "$_pv" = "$_pwant" ] \
  && ok "PM2: measure → 6커밋 재분류(루트·머지 제외, 미분류 0), test-runner 미선택 4/6·미선택 뒤 수정 1/4·선택 뒤 1/2·2줄·거리 2, 사유 집계" \
  || ng "PM2: 실측 수치가 어긋난다 [rc=$_rc] $_pv $(head -1 "$T/pm.err")$(_diag "$T/py.err")" "$_pwant"
# 창을 줄이면 거리 2 의 수정은 빠진다 — 창이 실제로 쓰인다
bash "$PMS" measure "$PMR" --window 1 > "$T/pm.w.json" 2>/dev/null
_pv=$(pmjq "$T/pm.w.json" 'next(c for c in d["candidates"] if c["lane"]=="test-runner")["axes"]["impact"]["skippedFollowedByFix"], d["window"]')
[ "$_pv" = "0 1" ] && ok "PM2: --window 1 → 거리 2 수정을 세지 않는다(0/4)" || ng "PM2: 창이 무시된다 [$_pv]" "0 1"
# --commits 는 최근 N 개만 — 머지 제외 뒤 마지막 3개(c4·c5·side)
bash "$PMS" measure "$PMR" --commits 3 > "$T/pm.n.json" 2>/dev/null
_pv=$(pmjq "$T/pm.n.json" 'd["scanned"], next(c for c in d["candidates"] if c["lane"]=="test-runner")["axes"]["violationRate"]["skipped"]')
[ "$_pv" = "3 1" ] && ok "PM2: --commits 3 → 최근 비머지 3개만 재분류(test-runner 미선택 1)" || ng "PM2: --commits 가 어긋난다 [$_pv]" "3 1"

# PM3 — 대상 레포를 건드리지 않는다: HEAD·인덱스·워킹트리·refs·워크트리·리모트·.git 최상위 항목 그대로, 관측 로그 없음
[ "$(_pmstate)" = "$_pmbefore" ] && [ ! -s "$_pmlog" ] \
  && ok "PM3: measure 뒤 대상 레포 상태 불변(분류 산출물·워크트리 없음), 관측 로그에 쓰지 않는다" \
  || ng "PM3: 대상 레포나 로그가 바뀌었다 [로그 $(wc -c < "$_pmlog" 2>/dev/null || echo 0)바이트] $(ls -A "$(git -C "$PMR" rev-parse --absolute-git-dir)" | tr '\n' ' ')" "불변 · 로그 없음"

# PM4 — 실측은 프로필을 끼우지 않는다 — 이미 test-runner 를 강제하는 프로필이 있어도 미선택 4 그대로.
# 공유 클론의 origin 은 원본 **경로**다(…/pmeas/tool) — 적재기는 그것도 슬러그 pmeas/tool 로 읽는다. 두 자리 모두에 둔다.
_pmver=$(head -n1 "$PM/root/skills/preflight/ENGINE_VERSION" | tr -d '[:space:]')
for _ps in Pm/Tool pmeas/tool; do _pl=$(printf '%s' "$_ps" | tr '[:upper:]' '[:lower:]'); mkdir -p "$PMPROF/${_pl%/*}"
  printf '{"repo":"%s","category":"fx-vault","engineVersion":"%s","adjustments":[{"id":"x","kind":"force-lane","lane":"test-runner","modes":["commit"],"approved":"2026-01-01","evidence":"e"}]}\n' \
    "$_ps" "$_pmver" > "$PMPROF/$_pl.json"; done
bash "$PMS" measure "$PMR" > "$T/pm.p.json" 2>/dev/null
_pv=$(pmjq "$T/pm.p.json" 'next(c for c in d["candidates"] if c["lane"]=="test-runner")["axes"]["violationRate"]["skipped"]')
rm -rf "$PMPROF/pm" "$PMPROF/pmeas"
[ "$_pv" = 4 ] && ok "PM4: 강제 프로필이 있어도 실측은 원래 미선택(4)을 센다" || ng "PM4: 프로필이 실측에 끼었다 [$_pv]" "4"

# PM5 — select: 승인 id 만, 적재기 키 그대로, approved=오늘. 모르는 id·중복은 exit 3, 인자 오류는 exit 2
bash "$PMS" select "$T/pm.m.json" force-test-runner-commit > "$T/pm.adj.json" 2>"$T/pm.err"; _rc=$?
_pv=$(pmjq "$T/pm.adj.json" 'len(d), sorted(d[0]), d[0]["kind"], d[0]["lane"], d[0]["modes"], d[0]["approved"] == __import__("datetime").date.today().isoformat(), "measure <repo>" in d[0]["evidence"] and "4/6" in d[0]["evidence"]')
[ "$_rc" = 0 ] && [ "$_pv" = "1 ['approved', 'evidence', 'id', 'kind', 'lane', 'modes'] force-lane test-runner ['commit'] True True" ] \
  && ok "PM5: select → 고른 항목 하나, 적재기 키 여섯, approved 오늘, evidence 에 재현 명령·미선택 비율" \
  || ng "PM5: select 출력이 어긋난다 [rc=$_rc] $_pv$(_diag "$T/py.err")" "한 항목 · 키 여섯 · 오늘 · 근거"
_pbad=''
bash "$PMS" select "$T/pm.m.json" nope >/dev/null 2>"$T/pm.err"; { [ $? = 3 ] && grep -qF '후보에 없는 id: nope' "$T/pm.err"; } || _pbad="$_pbad 모르는id"
bash "$PMS" select "$T/pm.m.json" force-test-runner-commit force-test-runner-commit >/dev/null 2>&1; [ $? = 3 ] || _pbad="$_pbad 중복"
for _a in "" "select" "measure" "bogus $PMR" "measure $PMR --commits 0" "measure $PMR --window x" "measure $PMR --bogus" "status $PMR extra"; do
  # shellcheck disable=SC2086
  bash "$PMS" $_a >/dev/null 2>&1; _rc=$?; [ "$_rc" = 2 ] || _pbad="$_pbad [$_a](rc=$_rc)"
done
bash "$PMS" measure "$PM/nowhere" >/dev/null 2>&1; [ $? = 2 ] || _pbad="$_pbad git아님"
[ -z "$_pbad" ] && ok "PM5: 모르는 id·중복 → exit 3 · 인자 오류·git 레포 아님 → exit 2" || ng "PM5: 거부가 어긋난다:$_pbad" "3 · 2"

# PM6 — table: 4축 열과 수치, 조정 파일을 주면 승인 열(날짜·미승인)
bash "$PMS" table "$T/pm.m.json" > "$T/pm.t" 2>&1; _rc=$?
_pbad=''
[ "$_rc" = 0 ] || _pbad="$_pbad rc=$_rc"
grep -qF '| 후보 | 위반율(강제 비용) | 영향도(미선택 / 선택 뒤 수정) | 복구 비용(줄·거리 중앙값) | 자동 수정 |' "$T/pm.t" || _pbad="$_pbad 머리"
grep -qF '| `force-test-runner-commit` | 4/6 (66.7%) | 1/4 (25.0%) / 1/2 (50.0%) | 2줄 · 2커밋 | 없음 |' "$T/pm.t" || _pbad="$_pbad 행"
grep -qF '재현: `bash skills/preflight/profile-measure.sh measure <repo> --commits 200 --window 5`' "$T/pm.t" || _pbad="$_pbad 재현"
bash "$PMS" table "$T/pm.m.json" "$T/pm.adj.json" > "$T/pm.t2" 2>&1
grep -qE "^\| \`force-test-runner-commit\` .* \| $(date +%F) \|$" "$T/pm.t2" && grep -qE '^\| `force-code-reviewer-commit` .* \| 미승인 \|$' "$T/pm.t2" || _pbad="$_pbad 승인열"
[ -z "$_pbad" ] && ok "PM6: table → 4축 행·재현 명령, 조정 파일을 주면 승인일/미승인 열" || ng "PM6: 표가 어긋난다:$_pbad $(sed -n 5,6p "$T/pm.t")" "머리·행·재현·승인열"

# PM7 — init --adjustments: 승인 항목이 프로필에 들어가고, 그 레포의 커밋 분류가 실제로 바뀐다(셸만 바뀐 커밋에 test-runner)
printf 'echo three\n' > "$PMR/a.sh"; git -C "$PMR" add a.sh
_pbefore=$(bash "$PM/root/skills/preflight/classify.sh" "$PMR" commit 2>"$T/py.err" | python3 -c 'import json,sys; print("test-runner" in json.load(sys.stdin)["selected"])' 2>>"$T/py.err")
bash "$PMP" init "$PMR" --category fx-vault --adjustments "$T/pm.adj.json" > "$T/pm.out" 2>"$T/pm.err"; _rc=$?
_pv=$(pmjq "$PMPROF/pm/tool.json" 'd["adjustments"] == json.load(open("'"$T/pm.adj.json"'"))')
_pafter=$(bash "$PM/root/skills/preflight/classify.sh" "$PMR" commit 2>"$T/py.err" | python3 -c '
import json,sys; d=json.load(sys.stdin); print("test-runner" in d["selected"], str(d["laneMeta"].get("test-runner",{}).get("forcedBy","")).startswith("profile profiles/pm/tool.json force-test-runner-commit"))' 2>>"$T/py.err")
git -C "$PMR" reset -q; git -C "$PMR" checkout -q -- a.sh
[ "$_rc" = 0 ] && [ "$_pv" = True ] && [ "$_pbefore" = False ] && [ "$_pafter" = "True True" ] && grep -qF 'adjustments force-test-runner-commit' "$T/pm.out" \
  && ok "PM7: init --adjustments → 프로필에 승인 항목 그대로, 셸만 바뀐 커밋에 test-runner 가 프로필 사유로 선택된다(전 False → 후 True)" \
  || ng "PM7: 조정 기록·반영이 어긋난다 [rc=$_rc 내용=$_pv 전=$_pbefore 후=$_pafter] $(head -1 "$T/pm.err")" "exit 0 · 항목 동일 · False → True True"
rm -rf "$PMPROF/pm"

# PM8 — 적재기가 받지 않는 조정·목록 아닌 파일 → exit 3, 프로필이 남지 않는다
_pbad=''
python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a[0]["lane"]="qa-runner"; json.dump(a, open(sys.argv[2],"w"))' "$T/pm.adj.json" "$T/pm.badlane.json"
bash "$PMP" init "$PMR" --adjustments "$T/pm.badlane.json" >/dev/null 2>"$T/pm.err"; _rc=$?
{ [ "$_rc" = 3 ] && grep -qF '적재기가 새 프로필을 받지 않아 지웠다' "$T/pm.err" && [ ! -e "$PMPROF/pm" ]; } || _pbad="$_pbad [lane rc=$_rc $(head -1 "$T/pm.err")]"
printf '{"id":"x"}\n' > "$T/pm.obj.json"
bash "$PMP" init "$PMR" --adjustments "$T/pm.obj.json" >/dev/null 2>"$T/pm.err"; _rc=$?
{ [ "$_rc" = 3 ] && grep -qF 'JSON 목록이어야 한다' "$T/pm.err" && [ ! -e "$PMPROF/pm" ]; } || _pbad="$_pbad [객체 rc=$_rc]"
bash "$PMP" init "$PMR" --adjustments "$T/pm.missing.json" >/dev/null 2>"$T/pm.err"; _rc=$?
{ [ "$_rc" = 3 ] && [ ! -e "$PMPROF/pm" ]; } || _pbad="$_pbad [없는파일 rc=$_rc]"
bash "$PMP" init "$PMR" --adjustments >/dev/null 2>&1; [ $? = 2 ] || _pbad="$_pbad [값없음]"
[ -z "$_pbad" ] && "$PMC" "$PMR" >/dev/null 2>&1 \
  && ok "PM8: 적재기가 거부하는 조정(lane qa-runner)·목록 아님·없는 파일 → exit 3, 프로필 없음, 조회는 그대로" \
  || ng "PM8: 거부·롤백이 어긋난다:$_pbad" "exit 3 · 프로필 없음"

# PM9 — 창·거리는 재생한 전체 비머지 커밋으로 센다. 분류에 실패한 커밋(겹침 → exit 3)이 사이에 있어도 실제 거리 2 다.
# c1 feat a.sh · c2 package.json(acme-core)을 더해 vault 와 겹친다(분류 실패) · c3 fix a.sh 와 package.json 제거
PMU="$PM/gap"; pminit "$PMU"
printf '# rules\n' > "$PMU/VAULT_RULES.md"; pmc "$PMU" "base"
printf 'echo one\n' > "$PMU/a.sh"; pmc "$PMU" "feat: add a.sh"
printf '{"name":"x","dependencies":{"acme-core":"^3"}}\n' > "$PMU/package.json"; pmc "$PMU" "chore: overlap"
rm -f "$PMU/package.json"; printf 'echo two\n' > "$PMU/a.sh"; pmc "$PMU" "fix: a.sh bug"
_pbad=''
for _w in 1 2; do
  bash "$PMS" measure "$PMU" --window "$_w" > "$T/pm.g$_w.json" 2>"$T/pm.err" || _pbad="$_pbad [w$_w rc=$? $(head -1 "$T/pm.err")]"
done
_pv=$(pmjq "$T/pm.g1.json" 'd["scanned"], len(d["unclassified"]), next(c for c in d["candidates"] if c["lane"]=="test-runner")["axes"]["impact"]["skippedFollowedByFix"]')
[ "$_pv" = "2 1 0" ] || _pbad="$_pbad [w1 $_pv]"
_pv=$(pmjq "$T/pm.g2.json" '(lambda a: (a["impact"]["skippedFollowedByFix"], a["recoveryCost"]["fixDistanceMedian"]))(next(c for c in d["candidates"] if c["lane"]=="test-runner")["axes"])')
[ "$_pv" = "(1, 2)" ] || _pbad="$_pbad [w2 $_pv]"
[ -z "$_pbad" ] && ok "PM9: 분류 실패 커밋이 사이에 있어도 창·거리는 실제 커밋 수 — 창 1 → 0, 창 2 → 1(거리 2), 미분류 1" \
  || ng "PM9: 창·거리가 분류된 커밋만으로 세진다:$_pbad" "w1: 2 1 0 · w2: (1, 2)"
if [ "$_pm_ov" = __unset__ ]; then unset PF_OVERLAY_DIR; else export PF_OVERLAY_DIR="$_pm_ov"; fi
