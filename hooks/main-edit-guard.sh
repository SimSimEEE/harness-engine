#!/bin/bash
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit) — 메인 세션의 레포 직접 편집을 막는다.
#
# 결론: 메인 세션(훅 입력에 `agent_id` 없음)은 레포 파일을 고치지 않고 `implementer` 서브에이전트에
# 위임한다. 근거는 관측 훅(edit-observe.sh)의 로그 — 위임 정의(#88)를 둔 뒤에도 메인 직접 편집이
# 서브에이전트 편집보다 많았다(수치·필터는 skills/preflight/DECISIONS.md 2026-11-18 「메인 세션의 레포 직접 편집 차단」).
#
# 판정(순서대로, 처음 걸린 것이 답):
#   모드 off → 아무것도 하지 않는다(출력·로그 없음)
#   agent_id 있음 → allow(subagent)
#   경로가 allowlist → allow(allowlist)
#   레포 밖 → allow(outside-repo). **toplevel 이 $HOME 이면 레포 밖이다** — 홈 디렉터리 자체를 git 레포로
#     쓰는 머신이 있고(실측), 그대로 두면 메모리·세션 노트 편집까지 막힌다.
#   Edit replace_all=true → deny(replace_all) — 바뀐 줄 수를 old/new 로 셀 수 없다(일치마다 바뀐다)
#   Edit 바뀐 줄 ≤ 2 → allow(small-edit), 그보다 많으면 deny(repo-edit). MultiEdit 는 합계로 같다
#   Write — 없는 파일 deny(new-file), 있는 파일 deny(repo-edit). NotebookEdit → deny(repo-edit)
# 바뀐 줄 수 = difflib(old_string 줄, new_string 줄) opcode 마다 max(삭제 줄, 삽입 줄) 의 합.
#
# 모드(off|warn|enforce, 그 밖의 값은 off): 환경변수 `PF_MAIN_EDIT_GUARD`(설정돼 있으면) >
# 설치본 config.json 의 `mainEditGuard`(머신 로컬 탈출구, 비었으면 다음) > 오버레이 루트의
# `edit-guard.json` 의 `mainEditGuard` > 기본 off. 엔진은 공개라 기본은 끈다 — 켜는 것은 오버레이·머신 몫이다.
# warn 은 deny 자리에서 막지 않고 additionalContext 로 알린다.
# config.json 위치는 `PF_CONFIG`(테스트 주입점)가 있으면 그것, 아니면 ~/.claude/skills/preflight/config.json.
#
# **fail-open**: 입력 파싱 실패·예외·git 실행 불가·git 시간 초과(3초)는 출력 없이 exit 0 이다(로그에 outcome=error 를
# 남기려 한다). git rev-parse 가 0 아닌 코드로 끝나면(레포 아님 포함) 오류가 아니라 allow(outside-repo) 다.
# 이 훅이 고장 나서 모든 편집이 막히면 고칠 수단(편집)까지 막힌다.
#
# 한계: 사이드 세션은 자기 프로세스에서 최상위라 agent_id 가 없어 메인으로 판정된다(사이드 세션도 위임해야 한다).
# Bash 편집(sed -i·리다이렉트)은 막지 않는다 — 우회할 수 있다. 그쪽은 edit-observe.sh 가 관측만 한다.
input=$(cat 2>/dev/null) || exit 0

PF_HOOK_INPUT="$input" python3 - 2>/dev/null <<'PY' || true
import json, os, re, subprocess, sys, time

HOME = os.environ.get("HOME") or os.path.expanduser("~")
LOG = os.path.expanduser(os.environ.get("PF_LOG") or "~/.claude/preflight-log.jsonl")
CFG = os.environ.get("PF_CONFIG") or os.path.join(HOME, ".claude/skills/preflight/config.json")
MODES = ("off", "warn", "enforce")

def expand(p):
    p = str(p)
    if p.startswith("$HOME"):
        return HOME + p[len("$HOME"):]
    if p.startswith("~"):
        return HOME + p[1:]
    return p

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

cfg = load(CFG)
# 오버레이 루트 — lib.sh pf_overlay_dir 와 같은 해석(훅은 lib.sh 를 source 하지 않아 옮겨 적는다):
# PF_OVERLAY_DIR 가 설정돼 있으면 그 값(빈 값 = 없음), 아니면 config.json 의 overlayDir. 앞 $HOME·~ 전개.
ovroot = os.environ["PF_OVERLAY_DIR"] if "PF_OVERLAY_DIR" in os.environ else (cfg.get("overlayDir") or "")
ov = load(os.path.join(expand(ovroot), "edit-guard.json")) if ovroot else {}

def resolve_mode():
    if "PF_MAIN_EDIT_GUARD" in os.environ:
        v, src = os.environ["PF_MAIN_EDIT_GUARD"], "env"
    elif cfg.get("mainEditGuard"):
        v, src = cfg["mainEditGuard"], "config"
    elif ov.get("mainEditGuard"):
        v, src = ov["mainEditGuard"], "overlay"
    else:
        v, src = "off", "default"
    return (v if v in MODES else "off"), src

rec = {"ts": int(time.time()), "event": "edit-guard", "outcome": None, "reason": None,
       "mode": None, "tool": None, "agentType": None, "sessionId": None,
       "repo": None, "path": None, "changedLines": None}

def jdump(o):
    # CONTRACT: json-out-is-one-function (정본은 skills/preflight/lib.sh) — 비UTF-8 경로는 ASCII 이스케이프로
    s = json.dumps(o, ensure_ascii=False)
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        s = json.dumps(o, ensure_ascii=True)
    return s

def log():
    try:
        with open(LOG, "a") as f:
            f.write(jdump(rec) + "\n")
    except Exception:
        pass

def glob_rx(pat):
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**", i):
            out.append(".*"); i += 2
        elif pat[i] == "*":
            out.append("[^/]*"); i += 1
        elif pat[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pat[i])); i += 1
    return re.compile("".join(out) + r"\Z")

def changed(old, new):
    import difflib
    a, b = str(old or "").splitlines(), str(new or "").splitlines()
    return sum(max(i2 - i1, j2 - j1)
               for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
               if tag != "equal")

mode = None
try:
    d = json.loads(os.environ.get("PF_HOOK_INPUT") or "")
    if not isinstance(d, dict):
        raise ValueError("input is not an object")
    mode, src = resolve_mode()
    if mode == "off":
        raise SystemExit(0)
    rec["mode"] = mode
    tool = d.get("tool_name") or ""
    ti = d.get("tool_input") or {}
    rec.update(tool=tool, sessionId=d.get("session_id") or None)

    def done(outcome, reason):
        rec.update(outcome=outcome, reason=reason)
        log()
        raise SystemExit(0)

    if d.get("agent_id"):
        rec["agentType"] = d.get("agent_type")
        done("allow", "subagent")

    if tool in ("Edit", "Write", "MultiEdit"):
        raw = ti.get("file_path")
    elif tool == "NotebookEdit":
        raw = ti.get("notebook_path")
    else:
        raise SystemExit(0)
    if not raw:
        raise ValueError("no path in tool_input")
    raw = expand(raw)
    if not os.path.isabs(raw):
        raw = os.path.join(d.get("cwd") or os.getcwd(), raw)
    path = os.path.normpath(raw)
    real = os.path.realpath(path)
    rec["path"] = path

    # allowlist — 내장 기본 + config.json mainEditGuardAllow + 오버레이 edit-guard.json allow.
    # 경로 그대로와 realpath 둘 다, $HOME 그대로와 그 realpath 둘 다로 대조한다(/tmp → /private/tmp 류).
    allow = ["~/.claude/projects/*/memory/**",
             "~/Library/Application Support/Claude/side-session-notes/**"]
    for extra in (cfg.get("mainEditGuardAllow"), ov.get("allow")):
        if isinstance(extra, list):
            allow += [str(x) for x in extra if x]
    rhome = os.path.realpath(HOME)
    pats = []
    for a in allow:
        e = expand(a)
        pats.append(glob_rx(e))
        if e.startswith(HOME) and rhome != HOME:
            pats.append(glob_rx(rhome + e[len(HOME):]))
    if any(p.match(x) for p in pats for x in (path, real)):
        done("allow", "allowlist")

    # 레포 판정 — 가장 가까운 **존재하는** 상위 디렉터리에서 git 에 묻는다.
    where = os.path.dirname(path)
    while where and not os.path.isdir(where):
        parent = os.path.dirname(where)
        if parent == where:
            break
        where = parent
    r = subprocess.run(["git", "-C", where, "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True, timeout=3)
    top = r.stdout.strip() if r.returncode == 0 else ""
    # 홈 디렉터리 자체가 레포인 머신 — 그 toplevel 은 레포로 보지 않는다(머리말).
    if not top or os.path.realpath(top) == rhome:
        done("allow", "outside-repo")
    rec["repo"] = top

    why = None
    if tool == "Edit":
        if ti.get("replace_all") is True:
            why = ("replace_all", "replace_all 편집(일치마다 바뀌어 줄 수를 셀 수 없다)")
        else:
            n = changed(ti.get("old_string"), ti.get("new_string"))
            rec["changedLines"] = n
            if n <= 2:
                done("allow", "small-edit")
            why = ("repo-edit", f"{n}줄 변경")
    elif tool == "MultiEdit":
        edits = ti.get("edits") or []
        if any(isinstance(e, dict) and e.get("replace_all") is True for e in edits):
            why = ("replace_all", "replace_all 이 든 MultiEdit")
        else:
            n = sum(changed(e.get("old_string"), e.get("new_string")) for e in edits if isinstance(e, dict))
            rec["changedLines"] = n
            if n <= 2:
                done("allow", "small-edit")
            why = ("repo-edit", f"{n}줄 변경(MultiEdit 합계)")
    elif tool == "Write":
        why = ("repo-edit", "Write 로 기존 파일 덮어쓰기") if os.path.exists(path) else ("new-file", "새 파일 생성")
    else:
        why = ("repo-edit", "노트북 편집")

    reason, what = why
    msg = (f"메인 세션은 레포 파일을 직접 편집하지 않는다 — `implementer` 서브에이전트에 위임하라. "
           f"판정: {what} ({path.encode('utf-8', 'backslashreplace').decode('utf-8')}). "
           "2줄 이하 Edit(replace_all 없이)와 레포 밖 파일은 통과한다. "
           "끄려면 mainEditGuard 를 off 로 둔다(PF_MAIN_EDIT_GUARD 환경변수 > ~/.claude/skills/preflight/config.json > 오버레이 edit-guard.json).")
    if mode == "enforce":
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                      "permissionDecisionReason": msg}}
        outcome = "deny"
    else:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "additionalContext": "[main-edit-guard warn — 차단하지 않았다] " + msg}}
        outcome = "warn"
    s = jdump(out)
    rec.update(outcome=outcome, reason=reason)
    log()
    sys.stdout.buffer.write((s + "\n").encode("utf-8", "backslashreplace"))
    sys.stdout.flush()
except SystemExit:
    pass
except Exception as e:
    # fail-open — 출력 없이 끝낸다. 모드를 아는 경우에만(off 가 아니면) 기록한다.
    try:
        if mode is None:
            mode, _ = resolve_mode()
        if mode != "off":
            rec.update(outcome="error", reason=type(e).__name__, mode=mode)
            log()
    except Exception:
        pass
PY
exit 0
