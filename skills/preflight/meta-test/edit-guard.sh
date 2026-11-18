#!/bin/bash
# meta-test — 메인 세션 레포 편집 차단 훅(hooks/main-edit-guard.sh)
# meta-test.sh 가 lib.sh 다음에 source 한다 — lib.sh 의 ok·ng·_diag·$T·$_mt_repo 만 쓴다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 메인 세션 레포 편집 차단 훅 =="
# 근거·판정 규칙은 DECISIONS.md 2026-11-18 (메인 세션의 레포 직접 편집 차단).
EG="$HOME/.claude/hooks/main-edit-guard.sh"
EGD="$T/editguard"; mkdir -p "$EGD/repo/sub" "$EGD/outside"; git init -q -b main "$EGD/repo"
printf 'a\nb\nc\n' > "$EGD/repo/sub/exists.txt"
printf '{}\n' > "$EGD/nocfg.json"
# egin <tool> <path> [tool_input 추가 JSON] [최상위 추가 JSON] — 훅 입력(PreToolUse JSON)을 이스케이프해 만든다
egin(){ python3 -c 'import json,sys
ti = {("notebook_path" if sys.argv[1] == "NotebookEdit" else "file_path"): sys.argv[2]}
ti.update(json.loads(sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "{}"))
d = {"hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": ti, "cwd": sys.argv[5], "session_id": "s1"}
d.update(json.loads(sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else "{}"))
print(json.dumps(d))' "$1" "$2" "${3:-}" "${4:-}" "$EGD/repo" 2>"$T/py.err"; }
# egrun <입력> [VAR=값 ...] — 모드 환경변수·오버레이는 지운 채 시작한다(호출자가 준 것만 쓴다).
# 로그는 $EGD/log.jsonl(매번 새로), stdout 은 $EGD/out, stderr 는 $EGD/err, 종료코드는 $_egrc.
egrun(){ local in="$1"; shift; rm -f "$EGD/log.jsonl"
  printf '%s' "$in" | env -u PF_MAIN_EDIT_GUARD -u PF_OVERLAY_DIR PF_CONFIG="$EGD/nocfg.json" PF_LOG="$EGD/log.jsonl" "$@" "$EG" > "$EGD/out" 2>"$EGD/err"; _egrc=$?; }
# egv — 판정 한 줄: "<응답> <로그 outcome> <로그 reason>". 출력 유무만으로 allow 를 판정하지 않는다 —
# allow 는 로그의 outcome=allow 로 확인한다(CONTRACT: hook-verdict-is-one-function 과 같은 이유).
# 응답: - (stdout 없음) | deny | warn | broken(<원인>). 로그 줄이 없으면 "0".
egv(){ local r
  if [ "$_egrc" != 0 ]; then r="broken(exit=$_egrc)"
  elif [ -s "$EGD/err" ]; then r="broken(stderr$(_diag "$EGD/err"))"
  elif [ ! -s "$EGD/out" ]; then r="-"
  else r=$(python3 -c 'import json,sys
h = json.load(open(sys.argv[1])).get("hookSpecificOutput") or {}
ok = h.get("hookEventName") == "PreToolUse"
if ok and h.get("permissionDecision") == "deny" and h.get("permissionDecisionReason"): print("deny")
elif ok and "permissionDecision" not in h and h.get("additionalContext"): print("warn")
else: print("broken(응답 모양)")' "$EGD/out" 2>"$T/py.err") || r="broken(응답 JSON$(_diag "$T/py.err"))"; fi
  printf '%s %s' "$r" "$(egfield outcome reason)"; }
# egfield <키...> — 로그 마지막 줄의 값들(앞에 줄 수). 로그가 없으면 0.
egfield(){ python3 -c 'import json,sys
try: r = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except FileNotFoundError: r = []
print(len(r), *[r[-1].get(k) for k in sys.argv[2:]]) if r else print(0)' "$EGD/log.jsonl" "$@" 2>"$T/py.err" || echo "?$(_diag "$T/py.err")"; }
E3='{"old_string":"a\nb\nc","new_string":"x\ny\nz"}'
ON=(PF_MAIN_EDIT_GUARD=enforce)

# EG1 — 서브에이전트(agent_id 있음)는 레포 안 큰 편집도 통과한다
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3" '{"agent_id":"a1","agent_type":"implementer"}')" "${ON[@]}"
_e="$(egv) $(egfield agentType)"
[ "$_e" = "- 1 allow subagent 1 implementer" ] && ok "EG1: 서브에이전트 3줄 Edit → 통과(allow subagent, agentType 기록)" \
  || ng "EG1: 서브에이전트 판정이 어긋난다: $_e" "- 1 allow subagent 1 implementer"

# EG2 — 메인 세션(agent_id 없음)의 레포 안 3줄 Edit 는 막힌다, 사유는 implementer 위임·끄는 법을 담는다
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" "${ON[@]}"
_e=$(egv)
_why=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["permissionDecisionReason"])' "$EGD/out" 2>"$T/py.err")
[ "$_e" = "deny 1 deny repo-edit" ] && case "$_why" in *'`implementer`'*'3줄 변경'*'2줄 이하 Edit'*'레포 밖'*mainEditGuard*) true ;; *) false ;; esac \
  && ok "EG2: 메인 3줄 Edit → deny(repo-edit), 사유에 implementer 위임·3줄·예외·mainEditGuard" \
  || ng "EG2: 메인 레포 편집 차단이 어긋난다: $_e / $_why" "deny 1 deny repo-edit + 사유 문구"

# EG3 — 레포 밖(임시 디렉터리)은 통과한다 — 큰 Edit·새 파일 Write 모두
_bad=''
egrun "$(egin Edit "$EGD/outside/x.txt" "$E3")" "${ON[@]}"; _e=$(egv); [ "$_e" = "- 1 allow outside-repo" ] || _bad="$_bad [Edit → $_e]"
egrun "$(egin Write "$EGD/outside/new/deep/y.txt" '{"content":"z"}')" "${ON[@]}"; _e=$(egv); [ "$_e" = "- 1 allow outside-repo" ] || _bad="$_bad [Write 없는 디렉터리 → $_e]"
[ -z "$_bad" ] && ok "EG3: 레포 밖 3줄 Edit·없는 디렉터리의 Write → 통과(outside-repo)" || ng "EG3: 레포 밖 판정이 어긋난다:$_bad" "- 1 allow outside-repo"

# EG4 — 홈 디렉터리 자체가 레포면 그 toplevel 은 레포 밖으로 본다(홈 레포 머신 실측)
HR="$EGD/homerepo"; mkdir -p "$HR/notes"; git init -q -b main "$HR"
egrun "$(egin Write "$HR/notes/n.md" '{"content":"z"}')" "${ON[@]}" HOME="$HR"; _e=$(egv)
egrun "$(egin Write "$HR/notes/n.md" '{"content":"z"}')" "${ON[@]}"; _e2=$(egv)
[ "$_e" = "- 1 allow outside-repo" ] && [ "$_e2" = "deny 1 deny new-file" ] \
  && ok "EG4: toplevel = \$HOME 이면 레포 밖(통과), 같은 레포라도 HOME 이 아니면 차단" \
  || ng "EG4: 홈 레포 예외가 어긋난다: HOME=레포 → $_e / HOME≠레포 → $_e2" "- 1 allow outside-repo / deny 1 deny new-file"

# EG5 — allowlist: 내장 기본(메모리·사이드 세션 노트), config.json mainEditGuardAllow, 오버레이 allow.
# HOME 을 레포 **하위**에 둔다 — 그래야 홈 예외가 아니라 allowlist 가 통과시킨다.
FH="$EGD/repo/fakehome"; mkdir -p "$FH"
ln -s "$EGD/repo" "$EGD/link"
_rr=$(cd "$EGD/repo" && pwd -P)
printf '{"mainEditGuardAllow":["$HOME/viacfg/**","%s/link/rawonly/**","%s/realonly/**"]}\n' "$EGD" "$_rr" > "$EGD/cfg-allow.json"
mkdir -p "$EGD/ovl"; printf '{"allow":["~/viaov/*.md"]}\n' > "$EGD/ovl/edit-guard.json"
_bad=''
for _c in "$FH/.claude/projects/-x-y/memory/m.md:allow allowlist" \
          "$FH/Library/Application Support/Claude/side-session-notes/s1/n.md:allow allowlist" \
          "$FH/viacfg/a/b.md:allow allowlist" "$FH/viaov/o.md:allow allowlist" "$FH/viaov/deep/o.md:deny new-file" \
          "$EGD/link/rawonly/r.md:allow allowlist" "$EGD/repo/realonly/r.md:allow allowlist" \
          "$FH/.claude/projects/-x-y/other.md:deny new-file"; do
  egrun "$(egin Write "${_c%:*}" '{"content":"z"}')" "${ON[@]}" HOME="$FH" PF_CONFIG="$EGD/cfg-allow.json" PF_OVERLAY_DIR="$EGD/ovl"
  _e=$(egfield outcome reason); [ "$_e" = "1 ${_c##*:}" ] || _bad="$_bad [${_c%:*} → $_e]"
done
[ -z "$_bad" ] && ok "EG5: allowlist 8종 — 내장 둘·config·오버레이 통과, glob 밖·* 는 한 단계, 경로 그대로/realpath 양쪽 대조" \
  || ng "EG5: allowlist 판정이 어긋난다:$_bad" "목록대로"

# EG6 — (케이스는 "입력|기대" — JSON 에 콜론이 있어 | 로 가른다) 바뀐 줄 수 = opcode 마다 max(삭제, 삽입) 의 합. 2줄 이하는 통과, 3줄부터 차단
_bad=''
for _c in '{"old_string":"a\nb\nc","new_string":"a\nX\nY"}|- 1 allow small-edit 2' \
          '{"old_string":"a\nb","new_string":"x"}|- 1 allow small-edit 2' \
          '{"old_string":"a","new_string":"a\nb\nc"}|- 1 allow small-edit 2' \
          '{"old_string":"a\nb","new_string":"x\ny\nz"}|deny 1 deny repo-edit 3' \
          '{"old_string":"a\nb\nc\nd","new_string":"a\nB\nc\nD\ne"}|deny 1 deny repo-edit 3'; do
  egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "${_c%%|*}")" "${ON[@]}"
  _e="$(egv) $(egfield changedLines | cut -d' ' -f2)"; [ "$_e" = "${_c#*|}" ] || _bad="$_bad [${_c%%|*} → $_e]"
done
[ -z "$_bad" ] && ok "EG6: 2줄 Edit 셋(교체·2→1·삽입) 통과, 3줄 Edit 둘(2→3·흩어진 3줄) 차단, changedLines 기록" \
  || ng "EG6: 줄 수 규칙이 어긋난다:$_bad" "≤2 allow small-edit · ≥3 deny repo-edit"

# EG7 — replace_all=true 는 바뀐 줄이 1이어도 막는다
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" '{"old_string":"a","new_string":"b","replace_all":true}')" "${ON[@]}"; _e=$(egv)
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" '{"old_string":"a","new_string":"b","replace_all":false}')" "${ON[@]}"; _e2=$(egv)
[ "$_e" = "deny 1 deny replace_all" ] && [ "$_e2" = "- 1 allow small-edit" ] \
  && ok "EG7: replace_all=true 1줄 Edit → deny(replace_all), false 면 small-edit 통과" \
  || ng "EG7: replace_all 판정이 어긋난다: true → $_e / false → $_e2" "deny 1 deny replace_all / - 1 allow small-edit"

# EG8 — Write: 없는 파일은 new-file, 있는 파일은 repo-edit. NotebookEdit 는 repo-edit. 상대경로는 cwd 기준
_bad=''
egrun "$(egin Write "$EGD/repo/sub/new.txt" '{"content":"1"}')" "${ON[@]}"; _e=$(egv); [ "$_e" = "deny 1 deny new-file" ] || _bad="$_bad [새 Write → $_e]"
egrun "$(egin Write "$EGD/repo/newdir/deep/new.txt" '{"content":"1"}')" "${ON[@]}"; _e=$(egv); [ "$_e" = "deny 1 deny new-file" ] || _bad="$_bad [레포 안 없는 디렉터리 Write → $_e]"
egrun "$(egin Write "$EGD/repo/sub/exists.txt" '{"content":"1"}')" "${ON[@]}"; _e=$(egv); [ "$_e" = "deny 1 deny repo-edit" ] || _bad="$_bad [기존 Write → $_e]"
egrun "$(egin NotebookEdit "$EGD/repo/nb.ipynb" '{"new_source":"x"}')" "${ON[@]}"; _e=$(egv); [ "$_e" = "deny 1 deny repo-edit" ] || _bad="$_bad [NotebookEdit → $_e]"
egrun "$(egin Write "sub/rel.txt" '{"content":"1"}')" "${ON[@]}"; _e="$(egv) $(egfield path | cut -d' ' -f2)"
[ "$_e" = "deny 1 deny new-file $EGD/repo/sub/rel.txt" ] || _bad="$_bad [상대경로 → $_e]"
[ -z "$_bad" ] && ok "EG8: 새 파일 Write(없는 디렉터리 포함 — 가장 가까운 존재하는 상위로 레포 판정) → new-file, 기존 Write·NotebookEdit → repo-edit, 상대경로는 cwd 기준" \
  || ng "EG8: Write·NotebookEdit 판정이 어긋난다:$_bad" "목록대로"

# EG9 — MultiEdit 는 edits 의 바뀐 줄을 합산한다. replace_all 이 하나라도 있으면 막는다
_bad=''
for _c in '{"edits":[{"old_string":"a","new_string":"x"},{"old_string":"c","new_string":"z"}]}|- 1 allow small-edit' \
          '{"edits":[{"old_string":"a\nb","new_string":"x\ny"},{"old_string":"c","new_string":"z"}]}|deny 1 deny repo-edit' \
          '{"edits":[{"old_string":"a","new_string":"x"},{"old_string":"c","new_string":"z","replace_all":true}]}|deny 1 deny replace_all'; do
  egrun "$(egin MultiEdit "$EGD/repo/sub/exists.txt" "${_c%%|*}")" "${ON[@]}"; _e=$(egv); [ "$_e" = "${_c#*|}" ] || _bad="$_bad [${_c%%|*} → $_e]"
done
[ -z "$_bad" ] && ok "EG9: MultiEdit 1+1줄 통과, 2+1줄 차단(합산), replace_all 섞이면 차단" || ng "EG9: MultiEdit 판정이 어긋난다:$_bad" "목록대로"

# EG10 — off 모드: 기본값(설정 없음)과 명시 off 모두 출력·로그 없음. 모르는 값도 off 다
_bad=''
for _m in default off bogus; do
  if [ "$_m" = default ]; then egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")"
  else egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" PF_MAIN_EDIT_GUARD="$_m"; fi
  _e=$(egv); [ "$_e" = "- 0" ] && [ ! -e "$EGD/log.jsonl" ] || _bad="$_bad [$_m → $_e]"
done
[ -z "$_bad" ] && ok "EG10: off(기본·명시·모르는 값) → 3줄 Edit 도 출력 없음·로그 없음" || ng "EG10: off 모드가 개입했다:$_bad" "- 0 · 로그 파일 없음"

# EG11 — warn 모드: 막지 않고 additionalContext 로 알린다(permissionDecision 없음), 로그는 warn
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" PF_MAIN_EDIT_GUARD=warn; _e="$(egv) $(egfield mode | cut -d' ' -f2)"
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" '{"old_string":"a","new_string":"b"}')" PF_MAIN_EDIT_GUARD=warn; _e2=$(egv)
[ "$_e" = "warn 1 warn repo-edit warn" ] && [ "$_e2" = "- 1 allow small-edit" ] \
  && ok "EG11: warn 모드 3줄 Edit → additionalContext 만(차단 없음), 로그 outcome=warn · 1줄은 그대로 통과" \
  || ng "EG11: warn 모드가 어긋난다: $_e / $_e2" "warn 1 warn repo-edit warn / - 1 allow small-edit"

# EG12 — 모드 우선순위: 환경변수 > 설치본 config.json > 오버레이 edit-guard.json > off
mkdir -p "$EGD/ov-enf" "$EGD/ov-warn"
printf '{"mainEditGuard":"enforce"}\n' > "$EGD/ov-enf/edit-guard.json"; printf '{"mainEditGuard":"warn"}\n' > "$EGD/ov-warn/edit-guard.json"
printf '{"mainEditGuard":"off"}\n' > "$EGD/cfg-off.json"; printf '{"mainEditGuard":"warn"}\n' > "$EGD/cfg-warn.json"
printf '{"mainEditGuard":""}\n' > "$EGD/cfg-empty.json"
printf '{"overlayDir":"%s"}\n' "$EGD/ov-enf" > "$EGD/cfg-ovdir.json"
_bad=''
_pri(){ egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" "${@:2}"; local e; e=$(egv); [ "$e" = "$1" ] || _bad="$_bad [${*:2} → $e]"; }
_pri "deny 1 deny repo-edit"   PF_OVERLAY_DIR="$EGD/ov-enf"
_pri "deny 1 deny repo-edit"   PF_CONFIG="$EGD/cfg-ovdir.json"
_pri "deny 1 deny repo-edit"   PF_CONFIG="$EGD/cfg-empty.json" PF_OVERLAY_DIR="$EGD/ov-enf"
_pri "- 0"                     PF_CONFIG="$EGD/cfg-ovdir.json" PF_OVERLAY_DIR=
_pri "- 0"                     PF_CONFIG="$EGD/cfg-off.json" PF_OVERLAY_DIR="$EGD/ov-enf"
_pri "warn 1 warn repo-edit"   PF_CONFIG="$EGD/cfg-warn.json" PF_OVERLAY_DIR="$EGD/ov-enf"
_pri "deny 1 deny repo-edit"   PF_MAIN_EDIT_GUARD=enforce PF_CONFIG="$EGD/cfg-off.json" PF_OVERLAY_DIR="$EGD/ov-warn"
_pri "- 0"                     PF_MAIN_EDIT_GUARD=off PF_CONFIG="$EGD/cfg-warn.json" PF_OVERLAY_DIR="$EGD/ov-enf"
[ -z "$_bad" ] && ok "EG12: 우선순위 8경우 — env > config(빈 값은 다음) > 오버레이(PF_OVERLAY_DIR·config overlayDir, 빈 PF_OVERLAY_DIR=없음) > off" \
  || ng "EG12: 모드 우선순위가 어긋난다:$_bad" "env > config > overlay > off"

# EG13 — fail-open: 깨진 입력·이상한 tool_input·로그 쓰기 실패 → exit 0, stderr 없음. 판정 불가면 stdout 없음
_bad=''
egrun 'not json' "${ON[@]}"; _e=$(egv); [ "$_e" = "- 1 error JSONDecodeError" ] || _bad="$_bad [깨진 입력 → $_e]"
egrun '{"tool_name":"Edit","tool_input":"oops"}' "${ON[@]}"; _e=$(egv); [ "$_e" = "- 1 error AttributeError" ] || _bad="$_bad [tool_input 문자열 → $_e]"
egrun '{"tool_name":"Edit","tool_input":{}}' "${ON[@]}"; _e=$(egv); [ "$_e" = "- 1 error ValueError" ] || _bad="$_bad [경로 없음 → $_e]"
egrun 'not json' PF_MAIN_EDIT_GUARD=off; _e=$(egv); [ "$_e" = "- 0" ] || _bad="$_bad [off 의 깨진 입력 → $_e]"
# python3 를 못 찾는 환경 — 셸 층도 조용해야 한다(stderr 없음·exit 0). PATH 에 cat 만 둔다
mkdir -p "$EGD/nopy"; ln -sf "$(command -v cat)" "$EGD/nopy/cat"
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" "${ON[@]}" PATH="$EGD/nopy"; _e=$(egv); [ "$_e" = "- 0" ] || _bad="$_bad [python3 없음 → $_e]"
egrun '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "${ON[@]}"; _e=$(egv); [ "$_e" = "- 0" ] || _bad="$_bad [Read → $_e]"
mkdir -p "$EGD/dirlog"
printf '%s' "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" | env -u PF_OVERLAY_DIR PF_MAIN_EDIT_GUARD=enforce PF_CONFIG="$EGD/nocfg.json" PF_LOG="$EGD/dirlog" "$EG" > "$EGD/out" 2>"$EGD/err"; _egrc=$?
_e=$(egv); [ "$_e" = "deny 0" ] || _bad="$_bad [로그 쓰기 실패 → $_e]"
[ -z "$_bad" ] && ok "EG13: 깨진 입력·tool_input 문자열·경로 없음 → 통과(stdout 없음, exit 0, error 기록) · python3 없음도 조용 · Read 무시 · 로그 실패해도 판정은 그대로" \
  || ng "EG13: fail-open 이 깨졌다:$_bad" "목록대로"

# EG14 — 로그 필드: 정해진 11개 키, 값은 결정 그대로
egrun "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" "${ON[@]}"
_e=$(python3 -c 'import json,sys,os
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
keys = sorted(r) == sorted(["ts","event","outcome","reason","mode","tool","agentType","sessionId","repo","path","changedLines"])
print(keys, isinstance(r["ts"], int), r["event"], r["outcome"], r["reason"], r["mode"], r["tool"], r["agentType"], r["sessionId"],
      os.path.realpath(r["repo"]) == os.path.realpath(sys.argv[2]), r["path"] == sys.argv[3], r["changedLines"])' \
  "$EGD/log.jsonl" "$EGD/repo" "$EGD/repo/sub/exists.txt" 2>"$T/py.err")
[ "$_e" = "True True edit-guard deny repo-edit enforce Edit None s1 True True 3" ] \
  && ok "EG14: 로그 한 줄 — ts·event=edit-guard·outcome·reason·mode·tool·agentType·sessionId·repo·path·changedLines" \
  || ng "EG14: 로그 필드가 어긋난다: $_e$(_diag "$T/py.err")" "True True edit-guard deny repo-edit enforce Edit None s1 True True 3"

# EG15 — 등록: settings.hooks.json 의 PreToolUse 에 하나(편집 도구 matcher, Bash 없음, timeout 5), PostToolUse 에는 없다.
# install.sh 병합은 코드 변경 없이 이 항목을 넣고 반복해도 하나다
_e=$(python3 - "$_mt_repo/settings.hooks.json" <<'ZEG' 2>"$T/py.err"
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
m = [(e.get("matcher"), k.get("timeout")) for e in h.get("PreToolUse", []) for k in e.get("hooks", [])
     if k["command"] == '"$HOME/.claude/hooks/main-edit-guard.sh"']
post = [k["command"] for e in h.get("PostToolUse", []) for k in e.get("hooks", []) if "main-edit-guard" in k["command"]]
print(len(m), *(m[0] if m else ("-", "-")), len(post))
ZEG
)
[ "$_e" = "1 Edit|Write|MultiEdit|NotebookEdit 5 0" ] \
  && ok "EG15: settings.hooks.json PreToolUse 에 main-edit-guard.sh 하나(Edit|Write|MultiEdit|NotebookEdit, 5s), PostToolUse 에 없다" \
  || ng "EG15: 정본 조각 등록이 어긋난다: $_e$(_diag "$T/py.err")" "1 Edit|Write|MultiEdit|NotebookEdit 5 0"
EGI="$EGD/inst"; mkdir -p "$EGI/.claude"
HOME="$EGI" CLAUDE_HOME="$EGI/.claude" bash "$_mt_repo/install.sh" --copy >/dev/null 2>&1
HOME="$EGI" CLAUDE_HOME="$EGI/.claude" bash "$_mt_repo/install.sh" --copy >/dev/null 2>&1
_e=$(python3 - "$EGI/.claude/settings.json" <<'ZEG' 2>"$T/py.err"
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
p = [x["command"] for e in h.get("PreToolUse", []) for x in e.get("hooks", [])]
print(sum("main-edit-guard.sh" in c for c in p), sum("preflight-gate.sh" in c for c in p))
ZEG
)
[ "$_e" = "1 1" ] && [ -x "$EGI/.claude/hooks/main-edit-guard.sh" ] \
  && ok "EG15: install.sh 두 번 → PreToolUse 에 main-edit-guard·preflight-gate 하나씩, 훅 파일 실행 가능" \
  || ng "EG15: install.sh 배치·병합이 어긋난다 [$_e]$(_diag "$T/py.err")" "1 1 · 실행 가능"
# 복사 설치는 오버레이를 ~/.claude/harness-overlay 로 옮긴다 — edit-guard.json 도 함께 가야 훅이 그 모드를 읽는다
EGO="$EGD/inst-ov"; mkdir -p "$EGO/.claude" "$EGD/ovsrc"; printf '{"mainEditGuard":"enforce"}\n' > "$EGD/ovsrc/edit-guard.json"
HOME="$EGO" CLAUDE_HOME="$EGO/.claude" bash "$_mt_repo/install.sh" --copy --overlay "$EGD/ovsrc" >/dev/null 2>&1
rm -f "$EGD/log.jsonl"
printf '%s' "$(egin Edit "$EGD/repo/sub/exists.txt" "$E3")" | env -u PF_MAIN_EDIT_GUARD -u PF_OVERLAY_DIR -u PF_CONFIG HOME="$EGO" PF_LOG="$EGD/log.jsonl" "$EGO/.claude/hooks/main-edit-guard.sh" > "$EGD/out" 2>"$EGD/err"; _egrc=$?
_e=$(egv)
[ -f "$EGO/.claude/harness-overlay/edit-guard.json" ] && [ "$_e" = "deny 1 deny repo-edit" ] \
  && ok "EG15: install.sh --copy --overlay → edit-guard.json 을 harness-overlay 로 옮기고, 설치본 훅이 config overlayDir 로 그 모드(enforce)를 읽는다" \
  || ng "EG15: 복사 설치의 오버레이 edit-guard.json 이 훅에 닿지 않는다 [$_e]" "harness-overlay/edit-guard.json · deny"
