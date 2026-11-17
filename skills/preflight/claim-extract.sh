#!/usr/bin/env bash
# 사실 주장 추출 (claim-check ①) — 추가된 문서 줄·커밋 메시지·PR 본문에서 수치·부재 주장을 뽑고,
# 각 주장에 **붙어 있는 재현 명령**을 함께 낸다. 실행하지 않는다 — 실행은 claim-verify.sh(②) 몫이다.
#
# 대상은 산문이다(.md·커밋 메시지·PR 본문). 코드 파일은 보지 않는다.
# 재현 명령으로 인정하는 형식 둘 (형식 근거는 DECISIONS.md 2026-11-06):
#   · 주장 문단 바로 앞/뒤(빈 줄만 사이에 둠)의 코드 블록 안 `$ 명령` 줄 — 그 아래 줄들이 기록된 출력이다.
#     펜스 블록과, 모든 줄이 `$ ` 로 시작하는 줄에서 시작하는 문단(커밋 메시지용) 둘 다 블록이다.
#   · 같은 줄의 인라인 `` `명령` → 값 `` (→ · -> · => · = 뒤의 값)
#
# 사용: claim-extract.sh [--repo DIR] [--from REF] [--to REF | --cached] [--no-docs]
#                        [--commits RANGE] [--msg-file F]... [--body-file F]
#   --from    문서 diff 기준 (기본 HEAD). PR 게이트는 merge-base 를 준다.
#   --to      커밋끼리 비교한다(FROM..TO, 내용도 TO 에서). 이력 실측용이다.
#   --cached  스테이징된 내용만 본다(분류기의 커밋 모드). 없으면 워킹트리 + 미추적 파일.
#   --commits 범위의 커밋 메시지 전부 (PR 게이트: <merge-base>..HEAD)
# 출력: JSON {claims:[…], scanned:{…}}. 사용 오류만 exit 2, 나머지는 exit 0.
set -uo pipefail
REPO="."; FROM="HEAD"; TO=""; CACHED=0; DOCS=1; COMMITS=""; BODY=""; MSGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --to) TO="${2:-}"; shift 2 ;;
    --cached) CACHED=1; shift ;;
    --no-docs) DOCS=0; shift ;;
    --commits) COMMITS="${2:-}"; shift 2 ;;
    --msg-file) MSGS+=("${2:-}"); shift 2 ;;
    --body-file) BODY="${2:-}"; shift 2 ;;
    *) echo "알 수 없는 인자: $1" >&2; echo "usage: claim-extract.sh [--repo DIR] [--from REF] [--cached] [--no-docs] [--commits RANGE] [--msg-file F]... [--body-file F]" >&2; exit 2 ;;
  esac
done
# 루트로 정규화한다 — 하위 디렉터리를 받으면 파일별 diff·ls-files 의 pathspec 이 cwd 기준이 되어
# 루트 기준 경로(`diff --name-only`)와 어긋나고, 빈 diff 가 rc 0 으로 나와 주장이 조용히 0건이 된다.
REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo: $REPO" >&2; exit 2; }

REPO="$REPO" FROM="$FROM" TO="$TO" CACHED="$CACHED" DOCS="$DOCS" COMMITS="$COMMITS" BODY="$BODY" \
python3 - "${MSGS[@]+"${MSGS[@]}"}" <<'ZZEND'
import json, os, re, subprocess, sys

REPO = os.environ['REPO']; FROM = os.environ['FROM']; TO = os.environ['TO']
CACHED = os.environ['CACHED'] == '1'; DOCS = os.environ['DOCS'] == '1'
COMMITS = os.environ['COMMITS']; BODY = os.environ['BODY']
MSG_FILES = sys.argv[1:]
_DEC = {'encoding': 'utf-8', 'errors': 'surrogateescape'}

def git(*a):
    p = subprocess.run(['git', '-C', REPO, *a], capture_output=True, **_DEC)
    return p.returncode, p.stdout

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. 경로(argv·git -z)가 출력에 실린다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

# ── 주장 패턴. 코드 스팬·URL 은 지운 뒤 본다 — 경로·버전·명령 안의 숫자는 주장이 아니다.
# 앞자리 0 인 토큰(03/04·09 등)은 번호다 — 수가 아니다.
NUM = r'(?:\d{1,3}(?:,\d{3})+|[1-9]\d*(?:\.\d+)?|0(?:\.\d+)?)(?!\d)'
# 조건·문턱·단위당 표현은 관측값이 아니다 (`0건이면`·`3건 이상`·`1건씩`).
COND = r'(?!\s*(?:이면|면|이라면|이상|이하|미만|초과|까지|씩|마다|당|이어야|여야|이 되|가 되))'
UNIT = r'(?:개|건|곳|명|줄|회|파일|files?|cases?|items?)'
P_OF_KO = re.compile(rf'({NUM})\s*{UNIT}?\s*중(?:에서)?\s*({NUM})')
P_OF_EN = re.compile(rf'\b({NUM})\s+(?:out\s+)?of\s+({NUM})\b', re.I)
# 날짜(2026/11/06)·경로 조각을 빼려고 앞뒤에 `/숫자`·단어 문자가 붙은 것은 버린다
P_SLASH = re.compile(rf'(?<![\w./-])({NUM})\s*/\s*({NUM})(?![\w./%-]|\s*/\s*\d)')
P_PCT = re.compile(rf'(?<![\w.])({NUM})\s*%')
P_COUNT = re.compile(rf'(?<![\w.])({NUM})\s*(건|곳){COND}')
P_ABS = [re.compile(p) for p in (
    rf'(?<![\w.])0\s*(?:건|곳|개|명|줄|회){COND}',
    r'하나도\s*없',
    r'(?:아무것도|한\s*건도|한\s*곳도|단\s*하나도)\s*없',
    r'\b(?:zero|no)\s+(?:matches|occurrences|hits|results|files|cases)\b',
)]
# `없다` 단독은 부재 주장으로 세지 않는다 — 실측 근거는 DECISIONS.md 2026-11-06.

P_CODESPAN = re.compile(r'`[^`\n]*`')
P_URL = re.compile(r'https?://\S+')
P_INLINE_SRC = re.compile(r'`([^`\n]+)`\s*(?:→|->|=>|=)\s*`?([^`\s,;)]+)')
P_FENCE = re.compile(r'^\s{0,3}(```|~~~)')
P_PROMPT = re.compile(r'^\s*\$\s+(\S.*)$')

def num(s):
    return float(s.replace(',', ''))

def claim_of(line):
    """한 줄에서 주장을 뽑는다. 없으면 None. 한 줄 = 주장 하나 (종류·숫자는 여럿)."""
    # URL 은 같은 길이의 공백으로 지운다 — 패턴은 공백 길이를 가리지 않으므로 판정은 같고, 위치(spans)가 줄과 맞는다
    t = P_URL.sub(lambda m: ' ' * len(m.group(0)), P_CODESPAN.sub(lambda m: ' ' * len(m.group(0)), line))
    # spans: 숫자 자리의 위치 — 앞 공백을 걷은 줄(출력 text) 기준. 재측정(③)이 주장 숫자만 가리는 데 쓴다.
    off = len(line) - len(line.lstrip())
    at = lambda m, g: [m.start(g) - off, m.end(g) - off]
    kinds, ratios, nums, spans = [], [], [], []
    for p in (P_OF_KO, P_OF_EN):
        for m in p.finditer(t):
            a, b = num(m.group(1)), num(m.group(2))
            # 'N 중 M' 의 모집단이 앞이다. M>N 이면 두 숫자가 다른 것을 센다 — 비율로 묶지 않는다.
            if b <= a:
                ratios.append({'part': b, 'total': a})
                spans.append({'kind': 'ratio', 'part': at(m, 2), 'total': at(m, 1)})
            nums += [a, b]
    for m in P_SLASH.finditer(t):
        a, b = num(m.group(1)), num(m.group(2))
        if b > 0 and a <= b:
            ratios.append({'part': a, 'total': b})
            spans.append({'kind': 'ratio', 'part': at(m, 1), 'total': at(m, 2)})
        nums += [a, b]
    if ratios: kinds.append('ratio')
    pm = list(P_PCT.finditer(t))
    pcts = [num(m.group(1)) for m in pm]
    spans += [{'kind': 'percent', 'at': at(m, 1)} for m in pm]
    if pcts: kinds.append('percent'); nums += pcts
    cm = list(P_COUNT.finditer(t))
    cnt = [num(m.group(1)) for m in cm]
    spans += [{'kind': 'count', 'at': at(m, 1)} for m in cm]
    if cnt: kinds.append('count'); nums += cnt
    am = [m for m in (p.search(t) for p in P_ABS) if m]
    absence = bool(am)
    spans += [{'kind': 'absence', 'at': at(m, 0)} for m in am]
    if absence: kinds.append('absence')
    if not kinds: return None
    # 정수로 쓸 수 있는 값은 정수로 낸다 — 출력 대조가 토큰 비교다
    norm = lambda x: int(x) if float(x).is_integer() else x
    return {'kinds': kinds, 'numbers': sorted({norm(x) for x in nums}),
            'ratios': [{k: norm(v) for k, v in r.items()} for r in ratios],
            'percents': [norm(x) for x in pcts], 'spans': spans}

def blocks_of(lines):
    """코드 블록 목록 [(start, end, kind)] (1-based, 양끝 포함) 과 블록 안 줄 집합."""
    blocks, inside, i, n = [], set(), 0, len(lines)
    while i < n:
        m = P_FENCE.match(lines[i])
        if m:
            j = i + 1
            while j < n and not lines[j].lstrip().startswith(m.group(1)): j += 1
            blocks.append((i + 1, min(j, n - 1) + 1, 'fence'))
            inside.update(range(i + 1, min(j, n - 1) + 2))
            i = j + 1; continue
        if P_PROMPT.match(lines[i]) and (i == 0 or not lines[i - 1].strip()):
            j = i
            while j + 1 < n and lines[j + 1].strip(): j += 1
            blocks.append((i + 1, j + 1, 'prompt'))
            inside.update(range(i + 1, j + 2))
            i = j + 1; continue
        i += 1
    return blocks, inside

def commands_in(lines, start, end):
    """블록에서 `$ 명령` 과 그 아래 기록된 출력을 뽑는다. 펜스 줄은 뺀다."""
    out, cur = [], None
    for k in range(start, end + 1):
        l = lines[k - 1]
        if P_FENCE.match(l): continue
        m = P_PROMPT.match(l)
        if m:
            cur = {'cmd': m.group(1).strip(), 'line': k, 'recorded': []}; out.append(cur)
        elif cur is not None:
            cur['recorded'].append(l)
    for c in out:
        c['recorded'] = '\n'.join(c['recorded']).strip('\n')
    return out

def paragraph(lines, idx, inside):
    """idx(0-based) 를 포함하는 문단의 [시작, 끝] (0-based). 블록 줄·빈 줄에서 끊는다."""
    s = e = idx
    while s - 1 >= 0 and lines[s - 1].strip() and (s) not in inside and not lines[s - 1].lstrip().startswith('#'): s -= 1
    if lines[idx].lstrip().startswith('#'): return idx, idx   # 제목은 혼자 한 문단이다
    while e + 1 < len(lines) and lines[e + 1].strip() and (e + 2) not in inside and not lines[e + 1].lstrip().startswith('#'): e += 1
    return s, e

def claims_right_before(lines, b0):
    """블록 시작(0-based) 바로 앞 문단(빈 줄만 사이)에 주장이 있는가."""
    k = b0 - 1
    while k >= 0 and not lines[k].strip(): k -= 1
    while k >= 0 and lines[k].strip():
        if claim_of(lines[k]): return True
        if lines[k].lstrip().startswith('#'): break
        k -= 1
    return False

def attached(lines, blocks, s, e):
    """문단 [s,e] 바로 뒤(빈 줄만 사이) 블록. 없을 때만 바로 앞 블록을 본다.
    블록은 **바로 앞 주장 문단**의 것이다 — 그 문단에 주장이 있으면 뒤 문단에는 붙이지 않는다."""
    after, before = [], []
    for (bs, be, kind) in blocks:
        b0, b1 = bs - 1, be - 1
        if b0 > e and all(not lines[k].strip() for k in range(e + 1, b0)): after.append((bs, be, kind))
        elif b1 < s and all(not lines[k].strip() for k in range(b1 + 1, s)) \
                and not claims_right_before(lines, b0): before.append((bs, be, kind))
    return after or before

def frontmatter_end(lines):
    if lines and lines[0].strip() == '---':
        for k in range(1, len(lines)):
            if lines[k].strip() == '---': return k + 1
    return 0

def scan(text, source, file, added=None):
    """added: 주장으로 볼 줄 번호 집합(1-based). None 이면 전부."""
    lines = text.split('\n')
    blocks, inside = blocks_of(lines)
    fm = frontmatter_end(lines)
    res = []
    for i, l in enumerate(lines):
        ln = i + 1
        if ln <= fm or ln in inside: continue
        if added is not None and ln not in added: continue
        c = claim_of(l)
        if not c: continue
        srcs = []
        for m in P_INLINE_SRC.finditer(l):
            srcs.append({'form': 'inline', 'line': ln, 'commands': [{'cmd': m.group(1).strip(), 'line': ln,
                                                                     'recorded': m.group(2)}]})
        s, e = paragraph(lines, i, inside)
        for (bs, be, kind) in attached(lines, blocks, s, e):
            cmds = commands_in(lines, bs, be)
            if cmds: srcs.append({'form': kind, 'line': bs, 'commands': cmds})
        res.append({'source': source, 'file': file, 'line': ln, 'text': l.strip()[:240], **c, 'sources': srcs})
    return res

claims, scanned = [], {'docs': [], 'commits': [], 'msgFiles': [], 'bodyFile': None, 'errors': []}

def _range():
    return ['--cached', FROM] if CACHED else [FROM, TO] if TO else [FROM]

def added_lines(f):
    """추가된 줄 번호 집합. diff 가 실패하면 None — 빈 집합으로 두면 그 문서의 주장이 조용히 0건이 된다."""
    # --no-color: color.diff=always 면 @@ 머리에 ANSI 코드가 붙어 정규식이 안 맞고 주장이 조용히 0건이 된다.
    rc, d = git('diff', *_range(), '-U0', '--no-color', '--no-ext-diff', '--no-textconv', '--', f)
    if rc != 0: return None
    got, cur = set(), None
    for l in d.splitlines():
        m = re.match(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', l)
        if m:
            cur = int(m.group(1)); continue
        # 첫 @@ 앞의 `+++ b/…` 만 머리다 — 헌크 안에서 `++` 로 시작하는 추가 줄도 내용으로 센다.
        if cur is not None and l.startswith('+'):
            got.add(cur); cur += 1
    return got

if DOCS:
    # CONTRACT: git-paths-read-with-z (lib.sh)
    rc, out = git('diff', *_range(), '--name-only', '--no-color', '--diff-filter=AMR', '-z')
    if rc != 0:
        scanned['errors'].append(f'git diff {FROM} 실패 — 문서 주장을 뽑지 못했다')
    files = [x for x in out.split('\0') if x]
    untracked = []
    if not CACHED and not TO:
        rc, u = git('ls-files', '--others', '--exclude-standard', '-z')
        if rc != 0: scanned['errors'].append('git ls-files 실패 — 미추적 문서를 보지 못했다')
        untracked = [x for x in u.split('\0') if x]
    rc, root = git('rev-parse', '--show-toplevel'); root = root.strip()
    if rc != 0 or not root:
        scanned['errors'].append('레포 루트를 못 구했다 — 문서를 읽지 못했다'); files, untracked = [], []
    for f in sorted(set(files) | set(untracked)):
        if not f.lower().endswith('.md'): continue
        if CACHED or TO:
            rc, text = git('show', f'{TO}:{f}' if TO else f':{f}')
            if rc != 0: scanned['errors'].append(f'스테이징 내용을 못 읽었다: {f}'); continue
        else:
            try: text = open(os.path.join(root, f), encoding='utf-8', errors='surrogateescape').read()
            except OSError: scanned['errors'].append(f'못 읽었다: {f}'); continue
        added = None if f in untracked else added_lines(f)
        if added is None and f not in untracked:
            scanned['errors'].append(f'git diff 실패: {f} — 추가된 줄을 모른다'); continue
        scanned['docs'].append(f)
        claims += scan(text, 'doc', f, added)

if COMMITS:
    rc, out = git('log', '--no-merges', '--format=%H%x00%B%x01', COMMITS)
    if rc != 0: scanned['errors'].append(f'git log {COMMITS} 실패 — 커밋 메시지를 보지 못했다')
    for rec in out.split('\x01'):
        rec = rec.lstrip('\n')
        if '\0' not in rec: continue
        sha, msg = rec.split('\0', 1)
        scanned['commits'].append(sha[:12])
        claims += scan(msg, 'commit', f'commit:{sha[:12]}')

for mf in MSG_FILES:
    try:
        msg = open(mf, encoding='utf-8', errors='surrogateescape').read()
    except OSError:
        scanned['errors'].append(f'커밋 메시지 파일을 못 읽었다: {mf}'); continue
    # git 의 주석 줄(`#`)은 메시지가 아니다 — 남기면 제목처럼 보여 주장이 섞인다
    msg = '\n'.join('' if l.startswith('#') else l for l in msg.split('\n'))
    scanned['msgFiles'].append(mf)
    claims += scan(msg, 'commit-msg', mf)

if BODY:
    try:
        body = open(BODY, encoding='utf-8', errors='surrogateescape').read()
        scanned['bodyFile'] = BODY
        claims += scan(body, 'pr-body', 'pr-body')
    except OSError:
        scanned['errors'].append(f'PR 본문 파일을 못 읽었다: {BODY}')

print(_json_out({'claims': claims, 'scanned': scanned}, indent=2))
ZZEND
