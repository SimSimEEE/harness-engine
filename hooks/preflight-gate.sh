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
def commit_calls(line):
    lx = shlex.shlex(line, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    toks = list(lx)
    out, i = [], 0
    while i < len(toks):
        # 명령 치환·서브셸 안의 호출도 같은 호출이다 — 백틱은 shlex 가 단어에 붙여 둔다.
        if os.path.basename(toks[i].lstrip(BQ)) != "git":
            i += 1; continue
        j, mid = i + 1, []
        while j < len(toks) and toks[j].startswith("-"):
            mid.append(toks[j])
            if toks[j] in VALOPTS and j + 1 < len(toks):
                mid.append(toks[j + 1]); j += 1
            j += 1
        if j < len(toks) and toks[j].rstrip(BQ) == "commit":
            out.append(mid)
        i = max(j, i + 1)
    return out
def commit_verdict(cmd):
    # 판정과 함께 **첫 커밋 호출의 `-C` 값**을 돌려준다 — 대상 레포를 읽는 STRICT 매치의 `-C` 값과
    # 대조하는 데 쓴다(아래). 값이 다르면 메시지·주석 안의 `git commit` 글이 진짜 호출 대신 해석된
    # 것이다. **같은 호출인지는 보지 않는다** — 둘 다 `-C` 가 없으면 값이 같아 대조를 지나고, 그때
    # CD_DIR 은 가짜 매치 앞에서 잘린다(docs/backlog.md 「대상 레포 해석 재료가 아직 정규식이다」).
    first = None
    for line in cmd.split(chr(10)):
        try:
            calls = commit_calls(line)
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
                    if first is None:
                        first = unq(sm.group("cdir"))
                elif re.match(r"(\S*/)?git\s+-", rest) and not re.match(r"(\S*/)?git\s+-C\s", rest):
                    return "commit-global-option", first
                else:
                    # `-C` 로 시작하는데 못 읽은 것은 경로 형태 문제다 — 토큰 판정(`-C a\ b`)과 사유를 맞춘다.
                    return "commit-unparsed", first
            continue
        for mid in calls:
            if mid and not (len(mid) == 2 and mid[0] == "-C"):
                return "commit-global-option", first
            if first is None:
                first = mid[1] if mid else ""
    return ("commit-seen" if first is not None else ""), first
cv, cv_dir = commit_verdict(cmd)
PATS = (("commit", STRICT),
        ("pr",     r"(^|[;&|]|\s)gh\s+pr\s+create(\s|$)"))
sm = re.search(STRICT, cmd, re.S)
if cv in ("commit-global-option", "commit-unparsed") or (cv == "commit-seen" and (not sm or unq(sm.group("cdir")) != cv_dir)):
    PATS = ()
    emit("kind=" + ("commit-global-option" if cv == "commit-global-option" else "commit-unparsed"))
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
if printf '%s' "$CMD" | grep -q 'PREFLIGHT_SKIP='; then
    # CONTRACT: hook-emits-bytes-not-str — 사유도 명령 문자열에서 파생된다.
    skip_reason=$(CMD="$CMD" python3 -c '
import os, re, sys
q = chr(39)
m = re.search("PREFLIGHT_SKIP=(?:" + chr(34) + "([^" + chr(34) + "]*)" + chr(34)
              + "|" + q + "([^" + q + "]*)" + q + "|(\\S+))", os.environ.get("CMD", ""))
s = (next((g for g in m.groups() if g), "") if m else "").strip()
sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape") + b"\n")
' 2>/dev/null)
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
