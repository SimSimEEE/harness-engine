#!/bin/bash
# PostToolUse(Edit|Write|NotebookEdit|Bash) — 파일 편집을 관측 로그에 남긴다 (#88).
#
# 세려는 값: **메인 에이전트가 직접 편집한 횟수**와 위임(서브에이전트)한 편집 횟수.
# 구분은 훅 입력의 `agent_id` 다 — 서브에이전트의 도구 호출에만 실리고 메인 호출에는 없다
# (실측 2026-11-16, 캡처 명령은 skills/preflight/DECISIONS.md 「메인 편집 관측」).
#
# **관측만 한다.** 출력(stdout)을 내지 않고 늘 exit 0 이다 — PostToolUse 는 출력 JSON 으로만
# 개입할 수 있으므로 아무것도 내지 않으면 도구 결과·다음 판정에 닿지 않는다. 로그를 못 써도 같다.
# 게이트 훅(preflight-gate.sh)과 파일을 나눈 이유도 DECISIONS 에 있다.
#
# Bash 는 명령 문자열이 편집 모양일 때만 남긴다(`bashPattern` 에 걸린 패턴). 모양 판정이라
# 빠지는 것과 잘못 걸리는 것이 있다 — 정확도가 아니라 추세를 보는 값이다.
#
# 한계: 사이드 세션(다른 세션이 띄운 세션)은 자기 프로세스에서 최상위라 `main` 으로 남는다.
# `sessionId` 로 세션을 가를 수는 있지만 어느 세션이 최상위인지는 훅 입력에 없다.
input=$(cat 2>/dev/null) || exit 0

PF_HOOK_INPUT="$input" python3 - >/dev/null 2>&1 <<'PY' || true
import json, os, re, subprocess, time
try:
    d = json.loads(os.environ.get("PF_HOOK_INPUT") or "")
    tool = d.get("tool_name") or ""
    ti = d.get("tool_input") or {}
    path, pattern = None, None
    if tool in ("Edit", "Write", "MultiEdit"):
        path = ti.get("file_path")
    elif tool == "NotebookEdit":
        path = ti.get("notebook_path")
    elif tool == "Bash":
        cmd = str(ti.get("command") or "")
        # 명령 단어는 명령 위치(줄 머리·`;`·`&`·`|`·`(` 뒤)에서만 본다 — `grep rm` 같은 인자는 편집이 아니다.
        HEAD = r"(?:^|[;&|(\n])\s*(?:sudo\s+)?"
        PATS = (
            ("sed-i",    r"\bsed\s+(?:-[a-zA-Z]*\s+)*-[a-zA-Z]*i"),
            ("perl-i",   r"\bperl\s+(?:-[a-zA-Z]*\s+)*-[a-zA-Z]*i"),
            # `2>&1`·`>&2`·`>/dev/null` 은 편집이 아니다. `2>err.log` 같은 stderr 파일도 소스 편집이 아니라 뺀다. 따옴표 안의 `>` 는 걸린다(알고 둔다).
            ("redirect", r"(?<![0-9&<>=-])>>?\s*(?!/dev/null\b)[^\s&|;)]"),
            ("tee",      r"\|\s*tee\b"),
            ("fileop",   HEAD + r"(?:cp|mv|rm|mkdir|touch|ln|truncate|patch)\b"),
            ("git-write", r"\bgit\s+(?:-C\s+\S+\s+)?(?:apply|restore|checkout\s+--|rm|mv)\b"),
        )
        for name, rx in PATS:
            if re.search(rx, cmd):
                pattern = name
                break
        if not pattern:
            raise SystemExit(0)
    else:
        raise SystemExit(0)

    where = os.path.dirname(path) if path else (d.get("cwd") or os.getcwd())
    def git(*a):
        try:
            return subprocess.run(["git", "-C", where, *a], capture_output=True, text=True,
                                  timeout=3).stdout.strip() or None
        except Exception:
            return None
    agent = d.get("agent_id")
    rec = {"ts": int(time.time()), "event": "edit",
           "outcome": "subagent" if agent else "main",
           "tool": tool,
           "agentType": d.get("agent_type") if agent else None,
           "sessionId": d.get("session_id") or None,
           "repo": git("rev-parse", "--show-toplevel"),
           "branch": git("symbolic-ref", "--short", "-q", "HEAD"),
           "path": path,
           "bashPattern": pattern}
    # CONTRACT: json-out-is-one-function (정본은 skills/preflight/lib.sh) — 비UTF-8 경로는 ASCII 이스케이프로
    s = json.dumps(rec, ensure_ascii=False)
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        s = json.dumps(rec, ensure_ascii=True)
    with open(os.path.expanduser(os.environ.get("PF_LOG") or "~/.claude/preflight-log.jsonl"), "a") as f:
        f.write(s + "\n")
except SystemExit:
    pass
except Exception:
    pass
PY
exit 0
