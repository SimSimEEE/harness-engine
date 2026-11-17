#!/bin/bash
# meta-test — shell-tool 카테고리 규칙: 레포 자체 회귀 스위트를 분류기가 정하고 기록이 실행을 센다
# meta-test.sh 가 lib.sh·engine.sh 다음에 source 한다 — 앞 파일들의 헬퍼·상태를 쓰므로 단독 실행하지 않는다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 회귀 명령은 분류기가 정하고, 기록이 실행을 센다 =="
# 근거: classify.sh 의 CONTRACT: suites-decided-by-classifier · receipt.sh 의 suites-run-is-counted
SU="$T/suites"; mkdir -p "$SU/r/skills/preflight" "$SU/r/hooks" "$SU/r/docs" "$SU/plain/skills/preflight"
for d in "$SU/r" "$SU/plain"; do git init -q -b main "$d"; git -C "$d" config user.email t@t; git -C "$d" config user.name t; done
printf 'echo ok\n' > "$SU/r/skills/preflight/meta-test.sh"; printf 'echo ok\n' > "$SU/r/skills/preflight/lane-contract-check.sh"
printf 'exit 0\n' > "$SU/r/hooks/preflight-gate.sh"; printf 'x=1\n' > "$SU/r/skills/preflight/classify.sh"; printf '# d\n' > "$SU/r/docs/a.md"
git -C "$SU/r" add -A; git -C "$SU/r" "$G" -qm init
printf 'x=1\n' > "$SU/plain/skills/preflight/classify.sh"; git -C "$SU/plain" add -A; git -C "$SU/plain" "$G" -qm init
printf 'x=2\n' > "$SU/r/skills/preflight/classify.sh"; git -C "$SU/r" add -A
"$CL" "$SU/r" commit > "$SU/c.json" 2>/dev/null
printf 'x=2\n' > "$SU/plain/skills/preflight/classify.sh"; git -C "$SU/plain" add -A
"$CL" "$SU/plain" commit > "$SU/cp.json" 2>/dev/null
python3 - "$SU/c.json" "$SU/cp.json" <<'PY' && ok "게이트 레포에서 셸 파일만 바뀌어도 test-runner 가 골라지고 회귀 명령 둘이 확정된다 · 다른 레포는 없다" \
  || ng "회귀 명령이 분류에서 빠지거나 다른 레포에 붙는다" "selected test-runner + suites [meta-test, lane-contract-check] / plain: 없음"
import json, sys
c = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2]))
s = [x['name'] for x in ((c.get('laneMeta') or {}).get('test-runner') or {}).get('suites') or []]
ps = ((p.get('laneMeta') or {}).get('test-runner') or {}).get('suites')
sys.exit(0 if 'test-runner' in c['selected'] and s == ['meta-test', 'lane-contract-check'] and not ps else 1)
PY
git -C "$SU/r" "$G" -qm two; printf '# e\n' >> "$SU/r/docs/a.md"; git -C "$SU/r" add -A
"$CL" "$SU/r" commit > "$SU/cd.json" 2>/dev/null
python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
sys.exit(0 if not ((c.get("laneMeta") or {}).get("test-runner") or {}).get("suites") else 1)' "$SU/cd.json" \
  && ok "게이트 레포라도 문서만 바뀌면 회귀 명령을 붙이지 않는다" || ng "문서 변경에 회귀 명령이 붙는다" "suites 없음"
# 다시 셸 변경 상태로 되돌려 기록을 시험한다
git -C "$SU/r" reset -q --hard HEAD~1; printf 'x=3\n' > "$SU/r/skills/preflight/classify.sh"; git -C "$SU/r" add -A
"$CL" "$SU/r" commit > "$SU/c.json" 2>/dev/null
SULANES=$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(json.dumps({l:{"status":"PASS"} for l in c["selected"]}))' "$SU/c.json")
python3 - "$SU" <<'PY'
import json, os, sys
T = sys.argv[1]; c = json.load(open(os.path.join(T, 'c.json')))
def blk(i, cmd): return {"timestamp":"2026-10-27T10:00:00Z","message":{"content":[{"type":"tool_use","id":i,"name":"Bash","input":{"command":cmd}}]}}
def out(l): return {"timestamp":"2026-10-27T10:05:00Z","message":{"content":[{"type":"tool_use","id":"o_"+l,"name":"StructuredOutput","input":{"lane":l,"verdict":"PASS","findings":[]}}]}}
tr_cmds = {"none": ["node --check x.js"], "meta": ["bash /x/skills/preflight/meta-test.sh 2>&1 | tail -3"],
           "read": ["grep -n ok /x/skills/preflight/meta-test.sh", "grep bash /x/skills/preflight/lane-contract-check.sh"],
           "both": ["PF_LOG=/tmp/x timeout 600 bash /x/skills/preflight/meta-test.sh", "R=skills/preflight; (bash $R/lane-contract-check.sh 2>&1)"],
           # 2026-11-04 PR 게이트에서 실제로 거부된 형태 그대로
           "timed": ["cd /x && (time bash skills/preflight/meta-test.sh) 2>&1 | tail -25", "time -p bash /x/skills/preflight/lane-contract-check.sh"],
           "qpath": ['bash "$WT/skills/preflight/meta-test.sh" 2>&1 | tail -3', "bash '/x/skills/preflight/lane-contract-check.sh'"],
           # 따옴표 안의 `\|` 를 구분자로 보면 그 뒤 `PJ=` 가 대입 접두가 되어 실행으로 셌다
           "qread": ["grep -n '^PJ=\\|PJ=' /x/skills/preflight/meta-test.sh", 'grep -n "^G=\\|G=" /x/skills/preflight/lane-contract-check.sh',
                     "bash -n /x/skills/preflight/meta-test.sh", "echo hi # later; bash /x/skills/preflight/lane-contract-check.sh",
                     "grep 'bash -c \"bash /x/skills/preflight/meta-test.sh\"' notes.md",
                     "echo '$(bash /x/skills/preflight/meta-test.sh)'", "cat <<EOF > f\nbash /x/skills/preflight/lane-contract-check.sh\nEOF"],
           # 큰따옴표 안이라도 `$(…)`·백틱은 셸이 실행한다
           "subst": ['echo "$(bash /x/skills/preflight/meta-test.sh 2>&1 | tail -3)"', 'echo "`bash /x/skills/preflight/lane-contract-check.sh`"'],
           # `eval "…"` 인자 · `<<"EOF"` 본문의 `'` 뒤 줄 (전사 수집의 heredoc 제거는 `<<"EOF"` 를 안 지운다)
           "evalhd": ['eval "bash /x/skills/preflight/meta-test.sh"', "cat <<\"EOF\"\nit's\nEOF\nbash /x/skills/preflight/lane-contract-check.sh"],
           # `bash -c` 의 인자 · 주석 속 `'` 뒤 줄 — 따옴표 마스크가 가리면 안 되는 실행
           "nested": ['bash -c "cd /x && bash skills/preflight/meta-test.sh"', "# don't skip\nbash /x/skills/preflight/lane-contract-check.sh"]}
for mode, cmds in tr_cmds.items():
    d = os.path.join(T, "t_" + mode); os.makedirs(d, exist_ok=True)
    for lane in c["selected"]:
        cs = cmds if lane == "test-runner" else ["grep -n x ."]
        rows = [blk(f"{lane}{i}", x) for i, x in enumerate(cs)] + [out(lane)]
        open(os.path.join(d, f"agent-{lane}.jsonl"), "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
_sureason() { rm -f "$SU/log.jsonl"
  PF_LOG="$SU/log.jsonl" "$R" record commit "$SU/r" "$SULANES" "@$SU/c.json" "$SU/t_$1" >/dev/null 2>&1
  python3 -c "
import json, os, sys
p = sys.argv[1]
if not os.path.exists(p) or not open(p).read().strip(): print(''); raise SystemExit
d = json.loads(open(p).read().strip().split(chr(10))[-1])
print((d.get('outcome') or '') + ':' + (d.get('reason') or '') + ':' + ','.join(d.get('suites') or []))" "$SU/log.jsonl"; }
case "$(_sureason none)" in
  *suite-not-run:meta-test,lane-contract-check*) ok "회귀 명령을 하나도 안 부른 test-runner 통과는 기록하지 않는다";;
  *) ng "회귀 명령 없이 test-runner 통과가 기록된다" "reason=suite-not-run (둘 다)";; esac
case "$(_sureason meta)" in
  *suite-not-run:lane-contract-check) ok "하나만 돌렸으면 빠진 명령 이름으로 거부한다";;
  *) ng "일부만 돌린 회귀 명령이 통과한다" "suite-not-run:lane-contract-check";; esac
case "$(_sureason both)" in
  recorded:*) ok "회귀 명령을 전부 돌렸으면 기록된다 (환경변수·timeout 접두, 서브셸 안 실행도 센다)";;
  *) ng "회귀 명령을 다 돌렸는데 막힌다" "outcome=recorded";; esac
case "$(_sureason read)" in
  *suite-not-run:meta-test,lane-contract-check*) ok "스크립트를 인자로만 쓴 명령(grep … · grep bash …)은 실행으로 세지 않는다";;
  *) ng "회귀 스크립트를 읽기만 해도 실행으로 센다" "suite-not-run (둘 다)";; esac
case "$(_sureason timed)" in
  recorded:*) ok "time 을 앞에 붙여 돌린 회귀 명령도 실행으로 센다 (서브셸 안 · time -p)";;
  *) ng "time 으로 돌린 회귀 명령을 실행으로 안 센다" "outcome=recorded";; esac
case "$(_sureason qpath)" in
  recorded:*) ok "따옴표로 감싼 경로로 돌린 회귀 명령도 실행으로 센다";;
  *) ng "따옴표 경로로 돌린 회귀 명령을 실행으로 안 센다" "outcome=recorded";; esac
case "$(_sureason qread)" in
  *suite-not-run:meta-test,lane-contract-check*) ok "따옴표 안 패턴의 \\| 뒤를 명령 자리로 보지 않는다 · bash -n · 주석 · 따옴표 속 bash -c · 작은따옴표 속 \$(…) · heredoc 본문은 실행이 아니다";;
  *) ng "grep 패턴 안 구분자 뒤 스크립트 이름을 실행으로 센다" "suite-not-run (둘 다)";; esac
case "$(_sureason nested)" in
  recorded:*) ok "bash -c 인자 안의 실행과 주석 속 따옴표 뒤 줄의 실행도 센다";;
  *) ng "bash -c 안이나 주석 뒤 줄의 회귀 명령을 실행으로 안 센다" "outcome=recorded";; esac
case "$(_sureason subst)" in
  recorded:*) ok "큰따옴표 안 \$(…)·백틱 명령 치환으로 돌린 회귀 명령도 실행으로 센다";;
  *) ng "큰따옴표 안 명령 치환의 회귀 명령을 실행으로 안 센다" "outcome=recorded";; esac
case "$(_sureason evalhd)" in
  recorded:*) ok "eval 인자 안의 실행과 heredoc 본문 뒤 줄의 실행도 센다";;
  *) ng "eval 안이나 heredoc 뒤 줄의 회귀 명령을 실행으로 안 센다" "outcome=recorded";; esac
for _st in NOT_APPLICABLE SKIPPED; do
  _NL=$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["test-runner"]={"status":sys.argv[2]};print(json.dumps(d))' "$SULANES" "$_st")
  for _tx in "$SU/t_both" ""; do
    _txl=$([ -n "$_tx" ] && echo 있음 || echo 없음)
    rm -f "$SU/log.jsonl"; PF_LOG="$SU/log.jsonl" "$R" record commit "$SU/r" "$_NL" "@$SU/c.json" $_tx >/dev/null 2>&1
    grep -q '"reason": *"suite-not-run"' "$SU/log.jsonl" 2>/dev/null \
      && ok "회귀 명령이 정해졌는데 test-runner 가 $_st 면 거부한다 (전사 $_txl)" \
      || ng "test-runner 가 $_st 로 회귀 명령을 건너뛰어도 기록된다 (전사 $_txl)" "reason=suite-not-run"
  done
done
grep -qF '회귀 명령 (계산됨' "$PJ" && grep -qF 'm.suites' "$PJ" \
  && ok "워크플로가 회귀 명령을 test-runner 프롬프트로 넘긴다" || ng "회귀 명령 배관이 없다" "laneMetaBlock m.suites"

# 격리 래퍼가 있으면 회귀 명령은 래퍼다. 설치본이 다른 브랜치를 가리켜도 워크트리를 검사할 수 있어야
# 하고, 맨 meta-test.sh 를 돌린 것은 설치본을 검사한 것이라 실행으로 세면 안 된다.
printf 'echo ok\n' > "$SU/r/skills/preflight/meta-test-isolated.sh"; printf 'x=4\n' > "$SU/r/skills/preflight/classify.sh"
git -C "$SU/r" add -A; "$CL" "$SU/r" commit > "$SU/c.json" 2>/dev/null
python3 - "$SU/c.json" <<'PY' && ok "격리 래퍼가 있으면 meta-test 회귀 명령은 래퍼다" || ng "래퍼가 있는데 설치본 meta-test 를 돌린다" "marker=meta-test-isolated.sh"
import json, sys
c = json.load(open(sys.argv[1]))
s = {x['name']: x for x in ((c.get('laneMeta') or {}).get('test-runner') or {}).get('suites') or []}
m = s.get('meta-test') or {}
sys.exit(0 if m.get('marker') == 'meta-test-isolated.sh' and m.get('cmd', '').endswith('/skills/preflight/meta-test-isolated.sh') else 1)
PY
SULANES=$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(json.dumps({l:{"status":"PASS"} for l in c["selected"]}))' "$SU/c.json")
python3 - "$SU" <<'PY'
import json, os, sys
T = sys.argv[1]; c = json.load(open(os.path.join(T, 'c.json')))
def blk(i, cmd): return {"timestamp":"2026-10-27T10:00:00Z","message":{"content":[{"type":"tool_use","id":i,"name":"Bash","input":{"command":cmd}}]}}
def out(l): return {"timestamp":"2026-10-27T10:05:00Z","message":{"content":[{"type":"tool_use","id":"o_"+l,"name":"StructuredOutput","input":{"lane":l,"verdict":"PASS","findings":[]}}]}}
for mode, cmds in {"iso": ["bash /x/skills/preflight/meta-test-isolated.sh", "bash /x/skills/preflight/lane-contract-check.sh"],
                   "bare": ["bash /x/skills/preflight/meta-test.sh", "bash /x/skills/preflight/lane-contract-check.sh"]}.items():
    d = os.path.join(T, "t_" + mode); os.makedirs(d, exist_ok=True)
    for lane in c["selected"]:
        cs = cmds if lane == "test-runner" else ["grep -n x ."]
        rows = [blk(f"{lane}{i}", x) for i, x in enumerate(cs)] + [out(lane)]
        open(os.path.join(d, f"agent-{lane}.jsonl"), "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
case "$(_sureason iso)" in
  recorded:*) ok "래퍼를 돌렸으면 회귀 명령 실행으로 센다";;
  *) ng "래퍼를 돌렸는데 막힌다 ($(_sureason iso))" "outcome=recorded";; esac
case "$(_sureason bare)" in
  *suite-not-run:meta-test*) ok "래퍼 대신 설치본 meta-test.sh 를 돌린 것은 실행으로 세지 않는다";;
  *) ng "설치본 meta-test 실행이 워크트리 검사로 세진다 ($(_sureason bare))" "suite-not-run:meta-test";; esac

echo "== 하네스 뷰가 뒤처지면 기록을 막는다 =="
# 근거: receipt.sh 의 harness-view-stale.
# **양쪽 다 인덱스다** — 생성 입력도(`--stdout-from-index`), 대조 대상도(인덱스의 README blob).
# 워킹트리와 비교하면 재생성해 놓고 git add 를 잊은 커밋을 통과시킨다. 생성기가 옳게 세는지는
# 여기서 보지 않는다(category-layer.sh 의 R23 이 실제 생성기로 센다). 여기서는 스텁으로
# **출력과 종료코드를 고정해** 배선의 결정표만 확인한다 — 스텁은 실제 계약대로 마커 블록을 낸다.
HV="$T/hview"; mkdir -p "$HV/r/skills/preflight" "$HV/r/hooks" "$HV/r/docs"
git init -q -b main "$HV/r"; git -C "$HV/r" config user.email t@t; git -C "$HV/r" config user.name t
printf 'echo ok\n' > "$HV/r/skills/preflight/meta-test.sh"
printf 'exit 0\n' > "$HV/r/hooks/preflight-gate.sh"
printf '# d\n' > "$HV/r/docs/a.md"
_hvreadme() { printf '# r\n\n<!-- harness:begin -->\n%s\n<!-- harness:end -->\n\n꼬리\n' "$1" > "$HV/r/README.md"; }
_hvreadme OLD
git -C "$HV/r" add -A; git -C "$HV/r" "$G" -qm init
# $1 = 블록 본문, $2 = 종료코드. $2 가 비면 생성기를 두지 않는다.
# **스테이징까지 한다** — 기록은 생성기 스크립트도 인덱스와 같을 때만 판정한다.
_hvstub() { rm -f "$HV/r/make-harness-view.sh"
  if [ -z "${2:-}" ]; then git -C "$HV/r" rm -q --cached --ignore-unmatch make-harness-view.sh >/dev/null 2>&1; return 0; fi
  { printf '#!/bin/bash\n'; printf '[ "$1" = --stdout-from-index ] || exit 2\n'
    printf 'printf "<!-- harness:begin -->\\n%%s\\n<!-- harness:end -->\\n" %s\n' "$1"
    printf 'exit %s\n' "$2"; } > "$HV/r/make-harness-view.sh"
  git -C "$HV/r" add make-harness-view.sh >/dev/null 2>&1; }
# 문서 한 줄만 스테이징한다 — 회귀 명령이 붙지 않아 전사 없이도 기록까지 간다.
_hvrec() { rm -f "$HV/log.jsonl"
  printf '# %s\n' "$1" > "$HV/r/docs/a.md"; git -C "$HV/r" add docs/a.md
  "$CL" "$HV/r" commit > "$HV/c.json" 2>/dev/null
  local L; L=$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(json.dumps({l:{"status":"PASS"} for l in c["selected"]}))' "$HV/c.json")
  PF_LOG="$HV/log.jsonl" "$R" record commit "$HV/r" "$L" "@$HV/c.json" > "$HV/out.txt" 2>&1
  python3 -c "
import json, os, sys
p = sys.argv[1]
if not os.path.exists(p) or not open(p).read().strip(): print(''); raise SystemExit
d = json.loads(open(p).read().strip().split(chr(10))[-1])
print((d.get('outcome') or '') + ':' + (d.get('reason') or '') + ':' + str(len(d.get('detail') or [])))" "$HV/log.jsonl"; }
_hvstub OLD 0
case "$(_hvrec same)" in
  recorded:*) ok "생성 블록이 인덱스 README 의 블록과 같으면 기록된다";;
  *) ng "일치인데 기록이 막힌다 ($(_hvrec same2))" "outcome=recorded";; esac
_hvstub NEW 0
case "$(_hvrec drift)" in
  refused:harness-view-stale:0) ng "거부는 하지만 무엇이 어긋났는지 안 남긴다" "detail 있음";;
  refused:harness-view-stale:*) grep -q -- '--write-from-index' "$HV/out.txt" && grep -q -- 'add -p' "$HV/out.txt" \
      && ok "생성 블록이 인덱스와 다르면 거부하고, 어긋난 줄과 실제로 통하는 복구 수단을 낸다" \
      || ng "거부 안내가 인덱스 입력 모드나 마커 블록만 담는 방법을 가리키지 않는다" "--write-from-index · add -p 안내";;
  *) ng "하네스 뷰가 뒤처진 채 기록된다 ($(_hvrec drift2))" "refused:harness-view-stale";; esac
# 핵심 대조 — 워킹트리만 재생성하고 git add 를 잊은 경우. 워킹트리 README 는 생성 결과와
# 같아지므로, 생성기의 --check(워킹트리 비교)를 그대로 썼다면 여기서 통과한다.
_hvreadme NEW
case "$(_hvrec unstaged)" in
  refused:harness-view-stale:*) ok "워킹트리만 재생성하고 git add 를 잊으면 여전히 거부한다 (인덱스로 판정한다)";;
  *) ng "재생성을 git add 하지 않은 커밋이 통과한다 ($(_hvrec unstaged2))" "refused:harness-view-stale";; esac
git -C "$HV/r" checkout -q -- README.md
# 마커가 없으면 블록을 특정할 수 없다 — 통과도 거부도 아니다.
printf '# r\n\n마커 없음\n' > "$HV/r/README.md"; git -C "$HV/r" add README.md
case "$(_hvrec nomarker)" in
  recorded:*) grep -q '판정하지 않았다' "$HV/out.txt" \
      && ok "인덱스 README 에 마커가 없으면 판정하지 않고 사유를 낸다" \
      || ng "마커가 없는데 아무 흔적 없이 통과한다 (이 경로로 검사가 조용히 꺼진다)" "사유 출력";;
  *) ng "마커 없는 README 로 기록이 막힌다 ($(_hvrec nomarker2))" "outcome=recorded";; esac
_hvreadme OLD; git -C "$HV/r" add README.md
# 판단 불가를 거부로 쓰면 분류 산출물이 없는 레포에서 기록이 영원히 막힌다.
for _rc in 4 2; do
  _hvstub NEW "$_rc"
  case "$(_hvrec "rc$_rc")" in
    recorded:*) grep -q "생성기가 $_rc 로 끝났다" "$HV/out.txt" \
        && ok "생성기가 $_rc 로 끝나면 기록을 막지 않고 종료코드를 사유로 낸다" \
        || ng "생성기 rc=$_rc 를 아무 흔적 없이 넘긴다" "사유에 rc 포함";;
    *) ng "판단 불가를 거부로 쓴다 (rc=$_rc)" "outcome=recorded";; esac
done
# 생성기 스크립트도 입력이다 — 인덱스와 다르면 커밋되지 않을 코드가 만든 표가 된다.
_hvstub OLD 0
printf '#!/bin/bash\nprintf "<!-- harness:begin -->\\nNEW\\n<!-- harness:end -->\\n"\n' > "$HV/r/make-harness-view.sh"
case "$(_hvrec gendirty)" in
  recorded:*) grep -q '인덱스와 다르다' "$HV/out.txt" \
      && ok "생성기 스크립트가 인덱스와 다르면 판정하지 않고 사유를 낸다" \
      || ng "미스테이징 생성기를 아무 흔적 없이 넘긴다" "사유 출력";;
  *) ng "미스테이징 생성기로 기록이 막힌다 ($(_hvrec gendirty2))" "outcome=recorded";; esac
# 추적되지 않는 생성기도 같다 — 인덱스에 blob 이 없다.
_hvstub NEW 0; git -C "$HV/r" rm -q --cached --ignore-unmatch make-harness-view.sh >/dev/null 2>&1
case "$(_hvrec genuntracked)" in
  recorded:*) grep -q '인덱스에 없다' "$HV/out.txt" \
      && ok "생성기가 추적되지 않으면 판정하지 않고 사유를 낸다" \
      || ng "추적 안 되는 생성기를 아무 흔적 없이 넘긴다" "사유 출력";;
  *) ng "추적 안 되는 생성기로 기록이 막힌다 ($(_hvrec genuntracked2))" "outcome=recorded";; esac
_hvstub '' ''
case "$(_hvrec nogen)" in
  recorded:*) ok "생성기가 없는 레포는 대상이 아니다";;
  *) ng "생성기 없는 레포의 기록이 막힌다 ($(_hvrec nogen2))" "outcome=recorded";; esac
