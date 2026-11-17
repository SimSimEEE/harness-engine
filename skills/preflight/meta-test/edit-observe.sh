#!/bin/bash
# meta-test — 메인 편집 관측 훅(hooks/edit-observe.sh, #88)과 역할 분담 정본
# meta-test.sh 가 lib.sh 다음에 source 한다 — lib.sh 의 ok·ng·$T·$_mt_repo 만 쓴다. 순서의 정본은 meta-test.sh 머리말이다.

echo "== 메인 편집 관측 훅 (#88) =="
# 근거·입력 실측은 DECISIONS.md 2026-11-16 (메인 편집 관측).
EO="$HOME/.claude/hooks/edit-observe.sh"
EOD="$T/editobs"; mkdir -p "$EOD/repo"; git init -q -b main "$EOD/repo"
# 훅 입력은 Claude Code 가 주는 PostToolUse JSON 이다. 서브에이전트 호출에만 agent_id·agent_type 이 실린다.
# eorun <json> → 로그는 $EOD/log.jsonl(매번 새로), stdout 은 $EOD/out, 종료코드는 $_eorc
eorun(){ rm -f "$EOD/log.jsonl"; printf '%s' "$1" | PF_LOG="$EOD/log.jsonl" "$EO" > "$EOD/out" 2>/dev/null; _eorc=$?; }
eofield(){ python3 -c 'import json,sys
r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(len(r), *[r[-1].get(k) for k in sys.argv[2:]]) if r else print(0)' "$EOD/log.jsonl" "$@" 2>"$T/py.err" || echo 0; }
eobash(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"session_id":"s1"}))' "$1" "$EOD/repo"; }

# EO1 — 메인 호출(agent_id 없음)의 Edit 는 main 으로 남는다
eorun "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$EOD/repo/a.txt\"},\"cwd\":\"$EOD/repo\",\"session_id\":\"s1\"}"
_e=$(eofield event outcome tool path agentType)
[ "$_eorc" = 0 ] && [ "$_e" = "1 edit main Edit $EOD/repo/a.txt None" ] \
  && ok "EO1: 메인 Edit → event=edit outcome=main, path 와 함께" || ng "EO1: 메인 Edit 기록이 어긋난다 [rc=$_eorc] $_e" "1 edit main Edit <path> None"

# EO2 — 서브에이전트 호출(agent_id 있음)의 Write 는 subagent 와 그 종류로 남는다
eorun "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$EOD/repo/b.txt\"},\"cwd\":\"$EOD/repo\",\"agent_id\":\"a1\",\"agent_type\":\"implementer\"}"
_e=$(eofield outcome agentType tool)
[ "$_e" = "1 subagent implementer Write" ] \
  && ok "EO2: 서브에이전트 Write → outcome=subagent, agentType 을 남긴다" || ng "EO2: 서브에이전트 기록이 어긋난다: $_e" "1 subagent implementer Write"

# EO3 — Bash 는 편집 모양일 때만, 걸린 패턴과 함께 남는다
_bad=''
for _c in "sed -i '' s/a/b/ f:sed-i" "cat x > out.txt:redirect" "echo y | tee f:tee" "cd d && rm -f y:fileop" "git -C r apply p.diff:git-write"; do
  eorun "$(eobash "${_c%:*}")"; _e=$(eofield outcome bashPattern)
  [ "$_e" = "1 main ${_c##*:}" ] || _bad="$_bad [${_c%:*} → $_e]"
done
[ -z "$_bad" ] && ok "EO3: 편집 모양 Bash 5종 → main 과 bashPattern 으로 남는다" || ng "EO3: 편집 Bash 가 어긋났다:$_bad" "패턴마다 한 줄"
_bad=''
for _c in 'ls -la' 'echo x 2>/dev/null' 'make >/dev/null' 'echo e >&2' 'make 2>build.err' 'grep a b 2>&1 | head' 'grep rm file' '[ 1 -gt 0 ] && cmp a b'; do
  eorun "$(eobash "$_c")"; _e=$(eofield outcome)
  [ "$_e" = 0 ] || _bad="$_bad [$_c → $_e]"
done
[ -z "$_bad" ] && ok "EO3: 읽기 Bash 8종(2>&1·>&2·>/dev/null·stderr 파일·인자 rm 포함) → 남기지 않는다" || ng "EO3: 읽기 Bash 가 편집으로 남았다:$_bad" "0줄"

# EO4 — 편집 아닌 도구는 남기지 않는다
eorun "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$EOD/repo/a.txt\"},\"cwd\":\"$EOD/repo\"}"
[ "$(eofield outcome)" = 0 ] && ok "EO4: Read 는 남기지 않는다" || ng "EO4: Read 가 편집으로 남았다" "0줄"

# EO5 — 관측은 개입하지 않는다: 어떤 입력에서도 stdout 이 비고 exit 0 (로그를 못 써도)
_bad=''
eorun 'not json'; [ "$_eorc" = 0 ] && [ ! -s "$EOD/out" ] || _bad="$_bad 깨진입력[rc=$_eorc]"
mkdir -p "$EOD/dirlog"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/repo/a.txt"}}' "$EOD" | PF_LOG="$EOD/dirlog" "$EO" > "$EOD/out" 2>"$EOD/err"; _eorc=$?
[ "$_eorc" = 0 ] && [ ! -s "$EOD/out" ] && [ ! -s "$EOD/err" ] || _bad="$_bad 로그쓰기실패[rc=$_eorc]"
eorun "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$EOD/repo/a.txt\"},\"cwd\":\"$EOD/repo\"}"
[ "$_eorc" = 0 ] && [ ! -s "$EOD/out" ] || _bad="$_bad 정상기록[rc=$_eorc]"
[ -z "$_bad" ] && ok "EO5: 깨진 입력·로그 쓰기 실패·정상 기록 모두 stdout 없음·exit 0" || ng "EO5: 관측 훅이 출력하거나 실패했다:$_bad" "stdout 없음 · exit 0"

# EO6 — 등록: 레포 정본 조각과 플러그인 hooks.json 이 PostToolUse 에 같은 matcher 로 하나씩
_e=$(python3 - "$_mt_repo/settings.hooks.json" <<'ZE6' 2>"$T/py.err"
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
m = [e.get("matcher") for e in h.get("PostToolUse", []) for k in e.get("hooks", []) if k["command"].endswith('/hooks/edit-observe.sh"')]
pre = [k["command"] for e in h.get("PreToolUse", []) for k in e.get("hooks", []) if "edit-observe" in k["command"]]
print(len(m), m[0] if m else "-", len(pre))
ZE6
)
[ "$_e" = "1 Edit|Write|MultiEdit|NotebookEdit|Bash 0" ] \
  && ok "EO6: settings.hooks.json 의 PostToolUse 에 edit-observe.sh 가 하나(편집 도구 matcher), PreToolUse 에는 없다" \
  || ng "EO6: 정본 조각 등록이 어긋난다: $_e" "1 Edit|Write|MultiEdit|NotebookEdit|Bash 0"
# 게이트 훅은 관측 훅을 부르지 않는다 — 관측 코드가 죽어도 게이트 판정이 달라지지 않게 파일을 나눴다
grep -q 'edit-observe' "$HOME/.claude/hooks/preflight-gate.sh" \
  && ng "EO6: 게이트 훅이 관측 훅에 기댄다" "파일 분리" || ok "EO6: 게이트 훅은 관측 훅과 분리돼 있다"

echo "== 구현 위임 정의·역할 분담 정본 (#88) =="
IM="$HOME/.claude/agents/implementer.md"
# EO7 — implementer 는 쓰지만 커밋·푸시·머지·승인은 하지 않는다. 입력 셋과 보고 셋이 정의에 있다
if [ ! -f "$IM" ]; then ng "EO7: implementer 정의가 없다" "$IM"; else
  _fm=$(sed -n '2,/^---$/p' "$IM")
  printf '%s\n' "$_fm" | grep -q '^  writes: true' && printf '%s\n' "$_fm" | grep -q '^  network: none' \
    && ok "EO7: implementer 계약 — writes: true · network: none" || ng "EO7: implementer 계약이 어긋난다" "writes: true · network: none"
  grep -qF '**커밋·푸시·머지를 하지 마라. 승인을 대신하지 마라.**' "$IM" \
    && grep -qE '^MUST NOT .*커밋·푸시·머지' "$IM" \
    && ok "EO7: implementer 가 커밋·푸시·머지·승인 대행을 금지한다" || ng "EO7: 금지 선언이 빠졌다" "본문 선언 + MUST NOT"
  _miss=''
  for _k in '① 계획 claim' '② 대상 파일' '③ 작업 위치' '1. **스테이징된 diff 요약**' '2. **실행한 검증 명령과 결과**' '3. **검증하지 못한 것**'; do
    grep -qF -- "$_k" "$IM" || _miss="$_miss [$_k]"
  done
  [ -z "$_miss" ] && ok "EO7: 입력 셋(claim·대상 파일·작업 위치)과 보고 셋(diff·검증·미검증)이 있다" || ng "EO7: 빠진 항목:$_miss" "입력 3 · 보고 3"
fi
# EO8 — 역할 분담 절: 표의 네 행과 예외 둘
SK="$HOME/.claude/skills/preflight/SKILL.md"
_sec=$(sed -n '/^## 역할 분담 — 메인은 분해·승인·판정, 구현은 위임$/,/^## /p' "$SK")
_rows=$(printf '%s\n' "$_sec" | grep -c '^| [^-|]')
_exc=$(printf '%s\n' "$_sec" | grep -cE '^- \*\*(한두 줄 수정|메인이 방금 진단한 결함)\*\*')
[ "$_rows" = 5 ] && [ "$_exc" = 2 ] \
  && ok "EO8: SKILL.md 역할 분담 절 — 표(머리+4행)와 예외 둘" || ng "EO8: 역할 분담 절이 어긋난다 [표 ${_rows}줄 · 예외 $_exc]" "표 5줄 · 예외 2"
grep -qF '`event: edit` / `outcome: main|subagent`' "$SK" \
  && ok "EO8: 관측 로그 절에 event: edit 가 있다" || ng "EO8: 관측 로그 절에 edit 이벤트 설명이 없다" "event: edit"
