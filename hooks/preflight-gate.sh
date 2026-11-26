#!/bin/bash
# PreToolUse(Bash) — git commit / gh pr create 전에 preflight 게이트 통과 여부를 확인한다.
# 게이트를 안 돌렸거나 통과 후 내용이 바뀌었으면 deny.
# 우회: 명령 앞에 PREFLIGHT_SKIP="<사유>" 를 붙인다. 형식적 값(1/y/true, 4자 미만)은 거부된다.
# 검사 결과 FAIL/ERROR 는 막는다. **receipt 를 쓰는 검증만** fail-open 이다 — receipt.sh 가
# 없거나 못 돌면 평범한 단독 commit 은 통과시키고 `hook-unavailable` 로 기록한다(하드 차단하면
# 그 훅을 고치는 커밋조차 막힌다). 형태 차단과 우회 사유 요구는 receipt 없이도 그대로 유효하다.
# 빈도를 재고 나서 조일지 정한다.
set -uo pipefail

# 설치 루트는 이 스크립트의 부모 디렉터리다 — ~/.claude 설치본(hooks/·skills/ 형제)과 플러그인 설치본
# (${CLAUDE_PLUGIN_ROOT}/hooks/) 모두 같은 배치라 $HOME 을 가정하지 않는다. PF_ROOT 는 메타테스트가
# 설치 고장(receipt 없음·권한 없음·죽음)을 흉내 낼 때 쓰는 override 다.
PF_ROOT="${PF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECEIPT="$PF_ROOT/skills/preflight/receipt.sh"
input=$(cat 2>/dev/null) || exit 0

# CONTRACT: hook-emits-bytes-not-str
# **`print` 를 쓰지 않는다.** 여기서 내는 것은 전부 명령 문자열에서 파생되고, 명령에는 경로가
# 들어 있다. 비UTF-8 경로는 JSON 입력에 `\udcff` 로 실려 와 strict stdout 에서 `print` 를
# 죽인다 — 그러면 eval 이 빈 값을 받고 `[ -z "$CMD" ]` 로 떨어져 **훅이 게이팅을 멈춘다**
# (그 커밋은 그냥 통과한다). 실측: LANG=…UTF-8 에서 UnicodeEncodeError, 훅 출력 없음.
# stdout 의 errors 는 로케일에 달려 있으므로 기대지 않고 바이트로 직접 쓴다.
eval "$(printf '%s' "$input" | python3 -c '
import sys, json, shlex
def emit(s):
    sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape") + b"\n")
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input") or {}
    emit("CMD=" + shlex.quote(str(ti.get("command") or "")))
    emit("CWD=" + shlex.quote(str(d.get("cwd") or "")))
except Exception:
    emit("CMD=\"\""); emit("CWD=\"\"")
' 2>/dev/null)" 2>/dev/null || exit 0

[ -z "${CMD:-}" ] && exit 0

# CONTRACT: gate-token-is-one-pattern
# 게이트 대상을 정하는 패턴은 **하나뿐이고, 여기서 경로 해석 재료까지 같이 낸다.**
#   GATE_CALL — 매치된 호출 그 자체 (여기 있는 `-C` 만 그 커밋의 것이다)
#   CD_DIR    — 그 호출 **앞**의 마지막 `cd` (커밋 시점의 cwd 를 정하는 것은 이것뿐)
#   SUFFIX    — 그 호출 **뒤** (형태 차단이 쓴다)
# 판정과 해석이 두 벌이 되면 "무엇이 게이트 대상인가" 와 "어디서 나는가" 가 갈린다.
# 줄 단위 도구(grep -o·sed)로는 자를 수 없다 — 여러 줄 명령에서 토큰 뒤 줄이 PREFIX 에 남아
# **다른 레포의 영수증으로 통과**한다. 그래서 문자열 오프셋으로 자른다(re.S).
# CONTRACT: hook-emits-bytes-not-str — 위와 같은 이유다 (GATE_CALL·CD_DIR 이 경로를 담는다).
eval "$(CMD="$CMD" python3 -c '
import os, re, shlex, sys
def emit(s):
    sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape") + b"\n")
cmd = os.environ["CMD"]
# `-C` 값은 **이름 있는 그룹**으로 잡는다. 번호로 집으면 그 그룹이 없는 `pr` 패턴에서
# IndexError 가 나고, 그러면 이 python 이 죽어 `kind` 가 비어 훅이 그대로 exit 0 한다
# — PR 게이트가 통째로 침묵한다. meta-test 의 `gh pr create → deny` 가 이 갈래를 지킨다.
# `git` 과 `commit` 사이에는 `-C <경로>` 하나만 받는다. 다른 전역 옵션(`-c k=v`, `--git-dir`,
# `--work-tree` …)은 판정을 빠져나가거나(완전 우회), 판정은 돼도 대상 레포를 바꿔 **다른 레포의
# 영수증으로** 통과한다. 그 밖의 옵션은 거부한다(`commit-global-option`).
# 판정은 **정규식이 아니라 shlex 토큰**으로 한다. 정규식으로 값 모양(따옴표·공백·이스케이프)을
# 열거하면 매번 다음 모양이 빠져나갔다 — 2026-09-14 에 7라운드, 2026-11-12 에 3라운드(docs/backlog.md).
# 토큰으로 본 `git … commit` 호출이 있는데 아래 `commit` 패턴(경로 해석 재료)이 읽지 못하면
# 그것도 거부한다(`commit-unparsed`) — 두 판정이 갈리는 틈이 검사 없는 통과가 되지 않게.
# 줄 단위로 나눈다: 히어독 본문의 짝 없는 따옴표가 명령 전체의 토큰화를 망치지 않게 한다.
# 토큰화에 실패한 줄(여러 줄에 걸친 따옴표 등)은 그 줄의 텍스트로 판정하고, 모르면 거부한다.
# `/usr/bin/git` 처럼 경로를 붙인 호출도 같은 git 이다.
# CONTRACT: one-C-value-form — `-C` 값의 정규식 형태(맨값·"…"·'…')는 아래 Q 한 벌이다.
Q = "(?:\"[^\"]+\"|" + chr(39) + "[^" + chr(39) + "]+" + chr(39) + "|\\S+)"
VALOPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path"}
STRICT = r"(^|[;&|]|\s)(\S*/)?git\s+(-C\s+(?P<cdir>" + Q + r")\s+)?commit(\s|$)"
STRICT_CALL = r"(\S*/)?git\s+(-C\s+(?P<cdir>" + Q + r")\s+)?commit(\s|$)"
BQ = chr(96)
LOOSE = r"(^|[;&|\s({" + BQ + r"])(\S*/)?git\s+([^;&|]*\s)?commit(\s|\)|" + BQ + r"|$)"
# 토큰화에 실패한 줄에서 git 이 시작하는 자리마다 — 탐욕 매치 하나가 뒤쪽 호출까지 삼키지 않게.
GITPOS = r"(^|(?<=[;&|\s({" + BQ + r"]))(\S*/)?git\s"
CALL_AT = r"(\S*/)?git\s+([^;&|]*?\s)?commit(\s|\)|" + BQ + r"|$)"
def unq(v):
    return (v or "").strip(chr(34) + chr(39))
# 한 Bash 호출 안의 커밋 호출은 하나만 받는다(`commit-multiple`). 경로 해석 재료는 한 호출에서만
# 나오므로, 둘째 호출부터는 영수증 검증·형태 차단 없이 다른 레포에 커밋된다.
# 커밋 호출 앞의 `GIT_*=` 할당도 거부한다(`commit-git-env`) — `GIT_DIR`·`GIT_WORK_TREE`·`GIT_CONFIG_*` 는
# 전역 옵션과 같은 일(대상 레포·설정 변경)을 한다. 대상 레포를 바꾸지 않는 작성자·날짜 변수만 받는다(화이트리스트).
# 셸 단어(`sh|bash|zsh|dash|ksh|fish|csh|tcsh`) 뒤 같은 단순 명령에 c 든 짧은 옵션(`-c`·`-lc`)이 있으면 그 뒤 인자 **전부**를,
# `eval` 은 인자를 이은 글을 다시 토큰화해, 안에 커밋이 있으면 거부한다(`commit-nested-shell`). 옵션을 하나씩 해석하지 않는다 —
# `--` 나 값 받는 긴 옵션(`--rcfile X`)마다 명령 문자열 자리가 달라져, 고르는 쪽은 매번 한 갈래를 놓친다.
# 그 밖의 명령 인자 글(`echo "git commit"`)은 판정하지 않는다.
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"}
GIT_ENV_OK = {"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE",
              "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE"}
# 중첩 깊이 상한. 상한에 닿은 글은 다시 풀지 않고 `git … commit` 글이 있으면 중첩 커밋으로 본다(모르면 거부).
MAXDEPTH = 3
QC = "[" + chr(34) + chr(39) + "]?"
WB = r"(?:^|(?<=[\s;&|(" + BQ + r"]))"
ENV_RX = WB + r"(GIT_[A-Za-z0-9_]*)="
SHELL_ALT = "sh|bash|zsh|dash|ksh|fish|csh|tcsh"
NEST_RX = WB + r"(?:(?:\S*/)?(?:" + SHELL_ALT + r")(?=\s)[^;&|()" + chr(10) + r"]*?\s-[A-Za-z]*c[A-Za-z]*(?=\s|$)|eval(?=\s))"
LOOSE_CALL = r"git" + QC + r"\s+(?:[^;&|]*?\s)?" + QC + r"commit(?![A-Za-z0-9_-])"
# 따옴표 구분자 히어독(`<<'X'`·`<<"X"`·`<<\X`, `<<-` 포함)의 본문은 확장되지 않는 글이다 — 그 줄의 커밋 호출은
# **개수(n)에만** 넣지 않고 중첩 셸 판정도 하지 않는다 — 메시지 안의 `git commit`·`bash -c '…'` 글이 둘째 호출·중첩 커밋으로
# 읽히지 않게. 그 본문은 소비자가 셸이 아니라 실행되지 않는다. 전역 옵션·해석 불가·`GIT_` 환경변수 판정은 그대로 건다.
# 같은 줄에 셸 단어가 있으면(`cat <<'X' | bash`) 본문이 명령으로 실행되므로 센다.
HD_RX = (r"(?<!<)<<(?!<)(-?)\s*(?:" + chr(39) + r"([^" + chr(39) + r"]+)" + chr(39) + r"|" + chr(34) + r"([^" + chr(34) + r"]+)" + chr(34)
         + r"|\\([A-Za-z0-9_.-]+)|([A-Za-z0-9_.-]+))")
SHELLWORD_RX = WB + r"(?:\S*/)?(?:" + SHELL_ALT + r"|eval|source|\.)(?=\s|$)"
def tokens(line):
    lx = shlex.shlex(line, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    return list(lx)
def is_sep(t):
    return t != "" and all(ch in "();<>|&" for ch in t) and any(ch in ";|&()" for ch in t)
def bad_env(name):
    return name.startswith("GIT_") and name not in GIT_ENV_OK
def new_state():
    # n: 커밋 호출 수, first: 첫 호출의 `-C` 값, verdict: 첫 형태 거부 사유,
    # env: 지금까지 허용 밖 `GIT_*=` 를 봤는가, gitenv: 그 뒤에 커밋 호출이 왔는가, nested: 중첩 셸 안 커밋
    return {"n": 0, "first": None, "verdict": None, "env": False, "gitenv": False, "nested": False}
def nested_has_commit(arg, depth):
    if depth + 1 > MAXDEPTH:
        return bool(re.search(LOOSE_CALL, arg, re.S))
    sub = new_state()
    scan(arg, depth + 1, sub)
    return bool(sub["first"] is not None or sub["nested"] or sub["verdict"])
def nested_arg_text(tail):
    # 토큰화가 안 되는 줄에서 옵션 뒤 인자 글을 단순 명령 끝까지 모은다 — 따옴표 인자는 짝 따옴표까지(줄을 넘어도),
    # 맨 인자는 공백까지. 따옴표 밖 `;&|()`·줄바꿈에서 멈춘다(뒤 명령의 진짜 커밋을 중첩으로 오인하지 않게).
    out, k = [], 0
    while k < len(tail) and len(out) < 32:
        while k < len(tail) and tail[k] in " " + chr(9):
            k += 1
        if k >= len(tail) or tail[k] in ";&|()" + chr(10):
            break
        if tail[k] in chr(34) + chr(39):
            body = tail[k + 1:]
            e = re.search((chr(39) if tail[k] == chr(39) else r"(?<!\\)" + chr(34)), body)
            if not e:
                out.append(body); break
            out.append(body[:e.start()]); k += 1 + e.end()
        else:
            w = re.match(r"[^\s;&|()" + chr(34) + chr(39) + r"]+", tail[k:])
            out.append(w.group(0)); k += w.end()
    return chr(10).join(out)
def commit_calls(toks, depth, st, nest=True):
    # 토큰 한 줄에서 커밋 호출의 git…commit 사이 옵션 목록을 낸다. 환경변수·중첩 셸 판정은 st 에 쌓는다.
    # nest=False 면 중첩 셸 판정을 하지 않는다(따옴표 히어독 본문 — 아래 scan).
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        # 명령 치환·서브셸 안의 호출도 같은 호출이다 — 백틱은 shlex 가 단어에 붙여 둔다.
        b = os.path.basename(t.lstrip(BQ))
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", t.lstrip(BQ))
        if m and bad_env(m.group(1)):
            st["env"] = True
        arg = None
        if not nest:
            pass
        elif b == "eval":
            j, parts = i + 1, []
            while j < len(toks) and not is_sep(toks[j]):
                parts.append(toks[j]); j += 1
            arg = " ".join(parts)
        elif b in SHELLS:
            j, rest = i + 1, []
            while j < len(toks) and not is_sep(toks[j]):
                rest.append(toks[j]); j += 1
            k = next((x for x, a in enumerate(rest) if a[:1] == "-" and a[1:2] != "-" and "c" in a[1:]), None)
            if k is not None and any(nested_has_commit(a, depth) for a in rest[k + 1:]):
                st["nested"] = True
        if arg and nested_has_commit(arg, depth):
            st["nested"] = True
        if b != "git":
            i += 1; continue
        j, mid = i + 1, []
        while j < len(toks) and toks[j].startswith("-"):
            mid.append(toks[j])
            if toks[j] in VALOPTS and j + 1 < len(toks):
                mid.append(toks[j + 1]); j += 1
            j += 1
        if j < len(toks) and toks[j].rstrip(BQ) == "commit":
            out.append(mid)
            if st["env"]:
                st["gitenv"] = True
        i = max(j, i + 1)
    return out
def uncounted_lines(lines):
    # 따옴표 구분자 히어독 본문의 줄 번호. 구분자 판정은 줄 글의 정규식 근사다 — 인자 글 안의 `<<'X'` 에 속으면
    # 그 사이 줄의 커밋이 개수에서 빠질 뿐이고(옛 훅과 같은 첫 호출 판정), 형태·환경변수·중첩 판정은 빠지지 않는다.
    skip, i = set(), 0
    while i < len(lines):
        nxt = i + 1
        shell = bool(re.search(SHELLWORD_RX, lines[i]))
        for m in re.finditer(HD_RX, lines[i]):
            dash = m.group(1) == "-"
            delim = next(g for g in m.groups()[1:] if g is not None)
            end = next((k for k in range(nxt, len(lines))
                        if (lines[k].lstrip(chr(9)) if dash else lines[k]) == delim), None)
            if end is None:
                break
            if m.group(5) is None and not shell:
                skip.update(range(nxt, end))
            nxt = end + 1
        i = nxt
    return skip
def scan(text, depth, st):
    lines = text.split(chr(10))
    skip = uncounted_lines(lines)
    for i, line in enumerate(lines):
        cnt = 0 if i in skip else 1
        try:
            toks = tokens(line)
        except ValueError:
            # git 이 시작하는 자리마다 판정한다. 줄 전체에 한 번 걸면 앞쪽의 정상 커밋 하나가 STRICT 를
            # 채워 뒤쪽의 `--git-dir`·`-c` 커밋을 가린다 — 그러면 앞 호출의 레포 영수증으로 통과한다.
            for g in re.finditer(GITPOS, line):
                rest = line[g.start():]
                if not re.match(CALL_AT, rest):
                    continue
                pre = line[g.start() - 1] if g.start() else ""
                sm = re.match(STRICT_CALL, rest)
                if (pre == "" or pre in ";&|" or pre.isspace()) and sm:
                    st["n"] += cnt
                    if st["first"] is None:
                        st["first"] = unq(sm.group("cdir"))
                    if st["env"] or any(bad_env(e) for e in re.findall(ENV_RX, line[:g.start()])):
                        st["gitenv"] = True
                elif re.match(r"(\S*/)?git\s+-", rest) and not re.match(r"(\S*/)?git\s+-C\s", rest):
                    st["verdict"] = st["verdict"] or "commit-global-option"
                else:
                    # `-C` 로 시작하는데 못 읽은 것은 경로 형태 문제다 — 토큰 판정(`-C a\ b`)과 사유를 맞춘다.
                    st["verdict"] = st["verdict"] or "commit-unparsed"
            if any(bad_env(e) for e in re.findall(ENV_RX, line)):
                st["env"] = True
            # 여러 줄에 걸친 `-c` 인자는 줄 단위로 다시 풀 수 없다 — 옵션 뒤 인자 글(nested_arg_text)에 커밋 글이 있으면 중첩 커밋으로 본다.
            for m in (re.finditer(NEST_RX, line) if cnt else ()):
                if re.search(LOOSE_CALL, nested_arg_text(line[m.end():] + chr(10) + chr(10).join(lines[i + 1:])), re.S):
                    st["nested"] = True
        else:
            for mid in commit_calls(toks, depth, st, nest=bool(cnt)):
                st["n"] += cnt
                if mid and not (len(mid) == 2 and mid[0] == "-C"):
                    st["verdict"] = st["verdict"] or "commit-global-option"
                elif st["first"] is None:
                    st["first"] = mid[1] if mid else ""
def commit_verdict(cmd):
    # 판정과 함께 **첫 커밋 호출의 `-C` 값**을 돌려준다 — 대상 레포를 읽는 STRICT 매치의 `-C` 값과
    # 대조하는 데 쓴다(아래). 값이 다르면 메시지·주석 안의 `git commit` 글이 진짜 호출 대신 해석된
    # 것이다. **같은 호출인지는 보지 않는다** — 둘 다 `-C` 가 없으면 값이 같아 대조를 지나고, 그때
    # CD_DIR 은 가짜 매치 앞에서 잘린다(docs/backlog.md 「대상 레포 해석 재료가 아직 정규식이다」).
    # 사유가 겹치면 형태(전역 옵션·해석 불가) → 여러 커밋 → 중첩 셸 → GIT_ 환경변수 순으로 하나를 낸다.
    st = new_state()
    try:
        scan(cmd, 0, st)
    except Exception:
        # 판정기가 죽으면 훅이 exit 0 으로 침묵한다 — 커밋 글이 있으면 거부 쪽으로 닫는다.
        return ("commit-unparsed" if re.search(LOOSE_CALL, cmd, re.S) else ""), None
    if st["verdict"]:
        return st["verdict"], st["first"]
    if st["n"] >= 2:
        return "commit-multiple", st["first"]
    if st["nested"]:
        return "commit-nested-shell", st["first"]
    if st["gitenv"]:
        return "commit-git-env", st["first"]
    # 개수에서 뺀 따옴표 히어독 본문의 호출도 판정 대상이다(first 가 그 호출에서 설 수 있다) — 빼면 커밋이 없는 명령이 된다.
    return ("commit-seen" if st["first"] is not None else ""), st["first"]
cv, cv_dir = commit_verdict(cmd)
REJECTS = ("commit-global-option", "commit-unparsed", "commit-multiple", "commit-nested-shell", "commit-git-env")
PATS = (("commit", STRICT),
        ("pr",     r"(^|[;&|]|\s)gh\s+pr\s+create(\s|$)"))
sm = re.search(STRICT, cmd, re.S)
if cv in REJECTS or (cv == "commit-seen" and (not sm or unq(sm.group("cdir")) != cv_dir)):
    PATS = ()
    emit("kind=" + (cv if cv in REJECTS else "commit-unparsed"))
for kind, rx in PATS:
    m = re.search(rx, cmd, re.S)
    if m:
        pre = cmd[:m.start()]
        cds = re.findall(r"(?:^|[;&|\n])\s*cd\s+(\"[^\"]+\"|\S+)", pre)
        emit("kind=" + shlex.quote(kind))
        emit("GATE_CALL=" + shlex.quote(m.group(0)))
        # `-C` 값도 **여기서만** 낸다. 해석기가 두 벌이면 하나가 죽어 `dir` 이 cwd 로
        # 조용히 떨어지고 **엉뚱한 레포의 영수증으로 통과**한다. 패턴이 이미 그 값을
        # 이름 있는 그룹 `cdir` 로 잡고 있다.
        emit("C_DIR=" + shlex.quote(unq(m.groupdict().get("cdir"))))
        emit("CD_DIR=" + shlex.quote(cds[-1].strip(chr(34)) if cds else ""))
        emit("SUFFIX=" + shlex.quote(cmd[m.end():]))
        break
else:
    if not PATS == ():
        emit("kind=\"\"")
' 2>/dev/null)" 2>/dev/null || exit 0
[ -z "${kind:-}" ] && exit 0

# 게이트가 무력화되거나 차단된 순간이 안 보이면 관측의 의미가 없다. 그래서 **결정을 내리는
# 자리는 전부** 여기를 거친다. outcome 값의 진실원은 이 함수의 **호출부**다 —
# 여기에 목록을 적으면 갈래가 늘 때마다 갈린다 (실제로 두 번 갈렸다).
# 기록은 판정에 개입하지 않는다: 실패해도 조용히 넘어간다.
# CONTRACT: branch-is-one-function — PF_BRANCH 식의 정본은 skills/preflight/lib.sh 의 pf_branch 다.
#  훅은 그 파일을 source 하지 않으므로 같은 식을 옮겨 적는다.
pf_hook_log() {
    PF_OUTCOME="$1" PF_REASON="${2:-}" PF_KIND="$kind" \
    PF_DIR="$(git -C "${dir:-${CWD:-$PWD}}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${dir:-${CWD:-$PWD}}")" \
    PF_BRANCH="$(git -C "${dir:-${CWD:-$PWD}}" symbolic-ref --short -q HEAD 2>/dev/null || git -C "${dir:-${CWD:-$PWD}}" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    python3 -c '
import json, os, time
try:
    path = os.path.expanduser(os.environ.get("PF_LOG") or "~/.claude/preflight-log.jsonl")
    with open(path, "a") as f:
        rec = {"ts": int(time.time()), "event": "hook",
               "outcome": os.environ["PF_OUTCOME"],
               "kind": os.environ.get("PF_KIND") or None,
               "repo": os.environ.get("PF_DIR") or None,
               "branch": os.environ.get("PF_BRANCH") or None,
               "reason": os.environ.get("PF_REASON") or None}
        # CONTRACT: json-out-is-one-function (정본은 skills/preflight/lib.sh)
        # `repo`·`reason` 에는 경로가 실린다. 비UTF-8 경로는 os.environ 이 surrogateescape 로
        # 주므로 strict 인 **파일 write** 에서 죽고, 바깥 except 가 삼켜 사건이 통째로 사라진다.
        s = json.dumps(rec, ensure_ascii=False)
        try:
            s.encode("utf-8")
        except UnicodeEncodeError:
            s = json.dumps(rec, ensure_ascii=True)
        f.write(s + "\n")
except Exception:
    pass' 2>/dev/null || true
    return 0
}

# deny 응답을 내는 **유일한 자리**. 갈라지면 폴백이 붙은 자리와 안 붙은 자리가 생긴다.
#
# CONTRACT: hook-deny-must-reach-stdout — 인코딩 규칙의 정본은 skills/preflight/lib.sh.
# 여기서만 다른 사실: **이 출력이 사라지면 deny 도 사라진다.** 훅은 뒤이어 exit 0 하므로
# 그 커밋이 그냥 통과한다.
pf_deny() {
    PF_DENY_REASON="$1" python3 -c '
import json, os, sys
d = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                            "permissionDecision": "deny",
                            "permissionDecisionReason": os.environ["PF_DENY_REASON"]}}
s = json.dumps(d, ensure_ascii=False)
try:
    s.encode("utf-8")
except UnicodeEncodeError:
    s = json.dumps(d, ensure_ascii=True)   # \uXXXX 이스케이프 — JSON 으로 유효하고 소비자가 되돌린다
sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape") + b"\n")
'
}

# **`--dry-run` 예외는 두지 않는다.** 명령 문자열로 무해함을 증명하려는 시도가 여섯 번 다 뚫렸다 —
# 모양을 좁힐수록 새 표현이 나왔고, 실사용 근거도 0건이었다. 되살리려면 meta-test.sh 의
# `--dry-run` 절(실행되는 형태 표)을 먼저 읽어라. `git commit --dry-run` 도 게이트를 거친다.


# 전역 옵션이 낀 커밋은 경로 해석 전에 거부한다 — 해석 재료(C_DIR·CD_DIR)가 그 옵션을 모른다.
if [ "$kind" = "commit-unparsed" ]; then
    kind=commit
    pf_hook_log denied "commit-unparsed"
    REASON="커밋 호출을 찾았지만 대상 레포를 읽을 수 있는 형태가 아니다. \`git -C <절대경로> commit …\` 형태(경로는 맨값이나 따옴표 하나로 감싼 값)로 다시 실행해라. 대상 레포를 모른 채 통과시키면 다른 레포의 게이트 기록으로 판정될 수 있어 거부한다."
    pf_deny "$REASON"
    exit 0
fi
if [ "$kind" = "commit-global-option" ]; then
    kind=commit
    pf_hook_log denied "commit-global-option"
    REASON="\`git\` 과 \`commit\` 사이에 \`-C <절대경로>\` 말고 다른 전역 옵션이 있다(\`-c k=v\`·\`--git-dir\`·\`--work-tree\` 등). 이런 옵션은 게이트 판정을 빠져나가거나 대상 레포를 바꿀 수 있어 거부한다 — \`git -C <절대경로> commit …\` 형태로 다시 실행해라. 커밋 설정이 필요하면 레포 설정(\`git config\`)으로 미리 바꿔라."
    pf_deny "$REASON"
    exit 0
fi
# 둘째 커밋 호출부터는 대상 레포를 읽지 않으므로 경로 해석 전에 거부한다.
if [ "$kind" = "commit-multiple" ]; then
    kind=commit
    pf_hook_log denied "commit-multiple"
    REASON="한 Bash 호출에 커밋은 하나만. 이 명령에는 \`git commit\` 호출이 둘 이상 있다 — 게이트는 한 호출의 대상 레포만 검증하므로 나머지는 검사 없이 다른 레포에 커밋될 수 있어 거부한다. 커밋마다 별도 Bash 호출로 실행해라. 픽스처 레포를 여러 번 커밋하는 스크립트는 파일로 써서 돌려라. 메시지 본문에 \`git commit\` 글이 있어 걸렸다면 메시지를 \`-F - <<'EOF'\` 히어독으로 넘겨라."
    pf_deny "$REASON"
    exit 0
fi
if [ "$kind" = "commit-nested-shell" ]; then
    kind=commit
    pf_hook_log denied "commit-nested-shell"
    REASON="셸 \`-c\` 인자(\`sh|bash|zsh|fish … -c '…'\`)나 \`eval\` 안에 커밋 호출이 있다. 메시지 글 때문에 걸렸다면 메시지를 \`-F <파일>\` 로 넘겨라. 따옴표 안 명령은 게이트가 대상 레포를 읽지 못해 거부한다 — 셸로 감싸지 말고 \`git -C <절대경로> commit …\` 을 직접 실행해라. 여러 커밋을 도는 스크립트는 파일로 써서 돌려라."
    pf_deny "$REASON"
    exit 0
fi
if [ "$kind" = "commit-git-env" ]; then
    kind=commit
    pf_hook_log denied "commit-git-env"
    REASON="커밋 호출 앞에 \`GIT_\` 환경변수 할당이 있다(\`GIT_DIR\`·\`GIT_WORK_TREE\`·\`GIT_INDEX_FILE\`·\`GIT_CONFIG_*\` 등). 이런 변수는 대상 레포·인덱스·설정을 바꿔 다른 레포의 게이트 기록으로 판정될 수 있어 거부한다. 받는 것은 작성자·날짜 변수(\`GIT_AUTHOR_NAME\`·\`GIT_AUTHOR_EMAIL\`·\`GIT_AUTHOR_DATE\`·\`GIT_COMMITTER_NAME\`·\`GIT_COMMITTER_EMAIL\`·\`GIT_COMMITTER_DATE\`)뿐이다 — 그 밖의 변수 없이 \`git -C <절대경로> commit …\` 으로 다시 실행해라."
    pf_deny "$REASON"
    exit 0
fi

# 작업 디렉터리 해석 우선순위:
#   1) GATE_CALL 안의 `git -C <path>`  2) CD_DIR  3) hook 의 cwd
# 재료는 위 CONTRACT 가 만든다 — **명령 전체를 다시 보지 마라.**
# **여기서 못 찾는 cd 가 여럿 있다**(서브셸 `(cd X && …)`, 실행되지 않는 `false && cd X`).
# 찾지 못하면 cwd 로 떨어져 다른 레포 영수증으로 통과한다 — docs/backlog.md 에 목록이 있다.
dir="${C_DIR:-}"
if [ -z "$dir" ]; then
    dir="$CD_DIR"
    case "$dir" in "~"|"~/"*) dir="$HOME${dir#\~}" ;; esac
fi
# 명령이 대상 디렉터리를 명시했는데 해석에 실패하면 **막는다**. 조용히 CWD 로 떨어지면
# 엉뚱한 레포의 영수증을 검증하게 된다 — 확장되지 않은 `$VAR` 가 든 경로가 원인이다.
if [ -n "$dir" ] && [ ! -d "$dir" ]; then
    pf_hook_log denied "unresolvable-dir: $dir"
    REASON="명령이 지정한 대상 디렉터리를 해석하지 못했다: [$dir]. 셸 변수(\`\$VAR\`)가 든 경로는 훅이 확장할 수 없다 — \`git -C <절대경로>\` 를 쓰거나 해당 디렉터리에서 직접 실행해라. 다른 레포의 게이트 기록으로 검증되는 것을 막기 위해 거부한다."
    pf_deny "$REASON"
    exit 0
fi
dir_explicit=1
[ -z "$dir" ] && { dir="${CWD:-$PWD}"; dir_explicit=0; }
[ -d "$dir" ] || { dir="${CWD:-$PWD}"; dir_explicit=0; }

# 명시가 없어 CWD 로 떨어졌는데 그것이 **홈**이면 막는다. 이 맥은 $HOME 자체가 git 레포라
# (branch develop) 조용히 잡히고, 그러면 엉뚱한 레포의 영수증으로 판정한다 —
# 실측 3건이 그렇게 기록됐다. 홈에서 진짜로 커밋하려면 `git -C "$HOME"` 로 명시하면 된다.
if [ "$dir_explicit" = "0" ] && [ "$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" = "$HOME" ]; then
    pf_hook_log denied "cwd-fallback-to-home"
    REASON="대상 레포를 특정하지 못했다: 명령에 \`git -C <경로>\` 나 \`cd\` 가 없어 현재 디렉터리로 떨어졌는데 그것이 홈(\`$HOME\`)이고, 홈이 git 레포다. 다른 레포의 게이트 기록으로 판정되는 것을 막기 위해 거부한다 — 대상을 \`git -C <절대경로>\` 로 명시해라. 홈 레포에 정말 커밋하려는 것이면 그때도 명시하면 통과한다."
    pf_deny "$REASON"
    exit 0
fi

# 우회에는 사유가 필요하다. 흔적만 남고 이유가 안 남으면 나중에 "왜 건너뛰었나" 를 못 센다 —
# 사유가 없으면 우회 기록만 남고 왜 우회했는지는 사람에게 물어야 한다.
# 우회로 인정하는 자리는 **명령 전체의 맨 앞**, 커밋·PR 생성 호출 바로 앞의 환경변수 할당뿐이다. 허용하는 앞머리는
# `cd <경로> &&` 하나와 `env` 접두, 다른 할당들이다: `PREFLIGHT_SKIP=… git [-C 경로] commit …`, `cd X && PREFLIGHT_SKIP=… git commit …`,
# `env PREFLIGHT_SKIP=… gh pr create …`. 맨 앞만 보므로 뒤의 커밋 메시지·히어독 본문·주석의 같은 글자는 판정에 들어오지 않는다 —
# 문자열 전체를 훑거나 따옴표를 추적하는 방식으로 넓히지 마라(명령 치환 안 히어독의 짝 없는 따옴표가 따옴표 상태를 뒤집는다,
# DECISIONS.md 2026-11-25). 그 밖의 자리의 글자는 우회가 아니라 평소 판정(영수증 검증)으로 간다.
# CONTRACT: hook-emits-bytes-not-str — 사유도 명령 문자열에서 파생된다. 출력은 한 줄 `F:<사유>`(찾음) 또는 `N`(없음)이다.
skip_out=$(CMD="$CMD" python3 -c '
import os, re, sys
cmd = os.environ.get("CMD", "")
SQ, DQ, BS = chr(39), chr(34), chr(92)
VAL = "(?:" + DQ + "((?:[^" + DQ + BS + BS + "]|" + BS + BS + ".)*)" + DQ + "|" + SQ + "([^" + SQ + "]*)" + SQ + "|([^\\s;&|()" + SQ + DQ + "]*))"
PATH = "(?:" + DQ + "[^" + DQ + "]+" + DQ + "|" + SQ + "[^" + SQ + "]+" + SQ + "|[^\\s;&|()]+)"
rest = cmd.lstrip(" \t")
m = re.match("cd\\s+" + PATH + "\\s*&&\\s*", rest)
if m: rest = rest[m.end():]
rest = re.sub("^env\\s+", "", rest)
found = None
while True:
    m = re.match("([A-Za-z_][A-Za-z0-9_]*)=" + VAL + "\\s+", rest)
    if not m: break
    if m.group(1) == "PREFLIGHT_SKIP":
        found = next((g for g in m.groups()[1:4] if g is not None), "")
    rest = rest[m.end():]
# 할당 바로 뒤가 게이트가 지키는 호출 자체여야 한다 — 다른 git·gh 호출 앞의 할당은 그 호출의 환경일 뿐이다.
CALL = "(?:\\S*/)?(?:git\\s+(?:-C\\s+" + PATH + "\\s+)?commit|gh\\s+pr\\s+create)(?:\\s|$)"
if found is not None and re.match(CALL, rest):
    sys.stdout.buffer.write(b"F:" + found.strip().encode("utf-8", "surrogateescape") + b"\n")
else:
    sys.stdout.buffer.write(b"N\n")
' 2>/dev/null)
if [ "${skip_out:0:2}" = "F:" ]; then
    skip_reason=${skip_out#F:}
    case "$skip_reason" in
        ''|1|0|y|Y|yes|YES|true|TRUE|skip|SKIP) skip_reason="" ;;
    esac
    if [ -z "$skip_reason" ] || [ ${#skip_reason} -lt 4 ]; then
        pf_hook_log denied "bypass-without-reason"
        REASON="우회에는 사유가 필요하다. \`PREFLIGHT_SKIP=1\` 은 더 이상 통하지 않는다 — 무엇 때문에 게이트를 건너뛰는지 4자 이상으로 적어라. 예: \`PREFLIGHT_SKIP=\"revert commit\" git commit …\` / \`PREFLIGHT_SKIP=\"충돌 해결\" …\`. **사용자 승인 없이 우회하지 마라.** 사유는 관측 로그에 남는다."
        pf_deny "$REASON"
        exit 0
    fi
    pf_hook_log bypassed "$skip_reason"
    exit 0
fi

# -- 신뢰 경계: 훅은 명령이 **실행되기 전**에 판정한다.
# 같은 명령 안에서 인덱스를 바꾸고 commit 하면 verify 가 본 인덱스와 실제 commit 될 인덱스가 갈린다.
#   git add secret.txt && git commit -m x   ->  verify 는 add 이전 트리를 본다
#   git commit -am x                        ->  commit 시점에 스테이징된다
# 실행 후 트리를 예측하려 들지 말고 거부한다. 스테이징을 별도 호출로 분리하면 그만이다.
split_reason=""
if [ "$kind" = "commit" ]; then
    if printf '%s' "$CMD" | grep -Eq '(^|[;&|]|[[:space:]])git[[:space:]]+(-C[[:space:]]+("[^"]+"|[^[:space:]]+)[[:space:]]+)?(add|rm|mv|restore|reset|stash|apply)([[:space:]]|$)'; then
        split_reason="같은 명령 안에서 인덱스를 바꾼 뒤 commit 한다"
    else
        # 토큰 위치를 다시 유도하지 않는다 — 앞에 같은 단어가 있으면 조각이 어긋난다.
        tail=${SUFFIX%%[;&|]*}
        if printf '%s' "$tail" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|(^|[[:space:]])--all([[:space:]]|$)'; then
            split_reason="commit -a/--all 은 commit 시점에 스테이징한다"
        fi
    fi
fi

if [ -n "$split_reason" ]; then
    pf_hook_log denied "unsafe-command-shape: $split_reason"
    REASON="preflight 게이트를 우회할 수 있는 형태다: $split_reason. 게이트는 명령 실행 전의 인덱스를 검증하므로 검사되지 않은 내용이 commit 된다. git add 를 **별도 Bash 호출**로 분리하고, /preflight 를 통과시킨 뒤 git commit 만 단독으로 실행해라."
    pf_deny "$REASON"
    exit 0
fi

# 여기까지의 통제(dry-run·dir 해석·우회·형태 차단)는 receipt.sh 를 쓰지 않는다.
# 가용성 검사를 앞에 두면 그 통제들이 함께 꺼져, 사유 있는 우회가 기록되지 않고
# `add && commit` 같은 형태가 검사 없이 통과한다 — 실측으로 네 형태가 그랬다.
# 그래서 **receipt 를 실제로 쓰는 자리 직전**에 둔다. 그래야 hook-unavailable 이
# 진짜 '검사 불가'만 센다. 막지는 않는다 — 훅 자신을 고치는 커밋을 막지 않기 위해서다.
if [ ! -e "$RECEIPT" ]; then
    pf_hook_log hook-unavailable "receipt-missing: $RECEIPT"
    exit 0
elif [ ! -x "$RECEIPT" ]; then
    pf_hook_log hook-unavailable "receipt-not-executable: $RECEIPT"
    exit 0
fi

reason=$("$RECEIPT" verify "$kind" "$dir" 2>/dev/null)
status=$?
[ "$status" -eq 0 ] && exit 0
# 종료코드 1 은 "검증 실패"(막아야 함)이고, 그 밖은 스크립트 자체가 죽은 것이다.
# 둘을 뭉뚱그리면 하네스 고장이 정상 차단으로 보이고 원인을 못 센다.
if [ "$status" -ne 1 ]; then
    pf_hook_log hook-unavailable "receipt-error: verify exit=$status"
    exit 0
fi

if [ "$kind" = "commit" ]; then
    hint="/preflight 를 먼저 실행해서 게이트를 통과시켜라. 사소한 변경이라 게이트가 불필요하다고 판단되면 사용자에게 확인받고 \`PREFLIGHT_SKIP=\"<사유>\"\` 를 명령 앞에 붙여 다시 시도한다 (4자 이상. \`=1\` 은 거부된다)."
    # 단축 경로 안내 — 스킬 문서를 읽지 않아도 부를 수 있게 설치 경로·레포를 채운 명령을 준다(DECISIONS.md 「빈 게이트 단축 경로」).
    hint="$hint 선택된 검사가 없는 변경이면 \`'$PF_ROOT/skills/preflight/preflight-fast.sh' '$dir' commit\` 한 번으로 기록된다(선택된 검사가 있으면 기록하지 않고 exit 10 으로 알려 준다)."
else
    hint="/preflight pr 을 먼저 실행해서 게이트를 통과시켜라. 우회가 필요하면 사용자 확인 후 \`PREFLIGHT_SKIP=\"<사유>\"\` 를 붙인다 (4자 이상. \`=1\` 은 거부된다)."
fi

REASON="preflight $kind 게이트 미통과: ${reason:-확인 실패}. $hint"
pf_deny "$REASON"
exit 0
