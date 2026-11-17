#!/usr/bin/env bash
# 사실 주장 검사 (claim-check ②) — claim-extract.sh 가 뽑은 주장마다 붙은 재현 명령을 **읽기 전용
# 허용 목록 안에서만** 대상 레포에서 다시 돌려, 출력에 주장 숫자가 있는지 대조한다.
#
# 판정은 막지 않는다(전부 blocking=false). 4축 실측 전이라 경고층이다 — DECISIONS.md 2026-11-06.
#   claim/no-source          비율·백분율·부재 주장인데 재현 명령이 붙어 있지 않다
#   claim/mismatch           다시 돌린 출력에 주장 숫자가 없다
#   claim/command-failed     명령이 실패했다(rc≥2 또는 stderr) — 0건으로 읽으면 안 된다
#   claim/absence-no-control 부재 주장인데 같은 블록에 무언가를 찾는 양성 대조가 없다
#   claim/percent-inconsistent 같은 줄의 비율과 백분율이 1%p 넘게 어긋난다
#   claim/unverifiable       (info) 허용 목록 밖 명령 — 실행하지 않았다
#   claim/count-no-source    (info) 건수만 있는 주장인데 재현 명령이 없다
#
# 사용: claim-verify.sh [--json] [--rules] [--sandbox-profile] [--claims FILE] [claim-extract.sh 인자…]
#   --sandbox-profile 은 실행에 쓰는 샌드박스 프로필을 낸다(없으면 빈 줄 + 사유를 stderr). 시험이 프로필을 직접 태운다.
#   --claims 가 없으면 나머지 인자로 claim-extract.sh 를 부른다.
# exit: 사용 오류 2, 그 외 0 (경고가 있어도 0 — 막지 않는다).
set -uo pipefail
JSON=0; RULES_ONLY=0; PROFILE_ONLY=0; CLAIMS=""; REPO="."; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --rules) RULES_ONLY=1; shift ;;
    --sandbox-profile) PROFILE_ONLY=1; shift ;;
    --claims) CLAIMS="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; PASS+=("$1" "${2:-}"); shift 2 ;;
    *) PASS+=("$1"); shift ;;
  esac
done
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$RULES_ONLY" = 0 ] && [ "$PROFILE_ONLY" = 0 ] && [ -z "$CLAIMS" ]; then
  CLAIMS_JSON="$("$SELF/claim-extract.sh" "${PASS[@]+"${PASS[@]}"}")"; rc=$?
  [ $rc -eq 0 ] || exit $rc
else
  CLAIMS_JSON=""
fi
CLAIMS_JSON="$CLAIMS_JSON" CLAIMS="$CLAIMS" REPO="$REPO" JSON="$JSON" RULES_ONLY="$RULES_ONLY" PROFILE_ONLY="$PROFILE_ONLY" python3 - <<'ZZEND'
import glob as _glob, json, os, re, shutil, subprocess, sys, tempfile

# CONTRACT: checker-rules-one-place — 이 목록 밖 rule 은 add() 가 거부한다.
RULES = ('claim/no-source', 'claim/mismatch', 'claim/command-failed', 'claim/absence-no-control',
         'claim/percent-inconsistent', 'claim/unverifiable', 'claim/count-no-source')
INFO = {'claim/unverifiable', 'claim/count-no-source'}

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. 문서 경로가 출력에 실린다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

if os.environ['RULES_ONLY'] == '1':
    print(_json_out(list(RULES))); sys.exit(0)

try:
    raw = open(os.environ['CLAIMS'], encoding='utf-8').read() if os.environ['CLAIMS'] else os.environ['CLAIMS_JSON']
    data = {} if os.environ.get('PROFILE_ONLY') == '1' else json.loads(raw)
except Exception as e:
    print(f'주장 목록을 읽지 못했다: {e}', file=sys.stderr); sys.exit(2)

root = subprocess.run(['git', '-C', os.environ['REPO'], 'rev-parse', '--show-toplevel'],
                      capture_output=True, text=True).stdout.strip() or os.environ['REPO']

# ── 허용 목록. **셸을 쓰지 않는다** — 문서 문자열을 직접 토큰화해 단계마다 argv 로 실행하고 파이프를
#    직접 잇는다. 셸 문법(연결·리다이렉트·치환·이스케이프 트릭)은 그래서 명령을 만들 수 없고, 남는
#    표면은 허용한 프로그램 자신의 실행·쓰기 옵션뿐이다 — 그것을 아래 DENY 에서 프로그램별로 막는다.
#    따옴표 밖 글롭(`src/*.ts`)만 직접 펼친다(매치가 없으면 bash 처럼 글자 그대로).
# awk 는 넣지 않는다 — 언어라서 프로그램 문자열을 정규식으로 거를 수 없다(gawk 의 `@f()` 간접 호출로
# `system` 을 글자 없이 부른다). 프로그램을 받는 도구는 옵션 열거로 닫히지 않는다.
ALLOW = {'grep', 'egrep', 'fgrep', 'wc', 'sort', 'uniq', 'head', 'tail', 'cut', 'find',
         'git', 'cat', 'tr', 'ls'}
GIT_SUB = {'log', 'diff', 'show', 'ls-files', 'grep', 'rev-parse', 'rev-list', 'cat-file', 'blame', 'shortlog'}
# 프로그램별 실행·쓰기 옵션 (짧은 글자, 긴 이름). BSD·GNU·gawk·ugrep 을 함께 본다 — 엔진은 특정 OS 를 가정하지 않는다.
#   grep : ugrep 의 --filter(명령 실행)·--pager/--view/-Q(외부 프로그램)·--save-config(쓰기), rg 류 --pre
#   sort : -o/--output(쓰기)·--compress-program(실행)
#   tail : -f/-F/--follow(끝나지 않는다)
#   git  : -O·--open-files-in-pager(pager 실행)·--output(쓰기)·--ext-diff·--textconv·--filters(설정된 외부 명령)
DENY = {
    'grep': ('Q', ('--filter', '--pager', '--view', '--query', '--save-config', '--pre', '--pre-glob')),
    'sort': ('o', ('--output', '--compress-program')),
    'tail': ('fF', ('--follow',)),
    'git': ('O', ('--output', '--open-files-in-pager', '--ext-diff', '--textconv', '--filters', '--exec-path', '--config-env')),
}
DENY['egrep'] = DENY['fgrep'] = DENY['grep']
FIND_BAD = {'-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprint', '-fprint0', '-fprintf', '-fls'}

def tokenize(cmd):
    """(단계별 [(토큰, 글롭 여부)], 거절 사유). bash 의 따옴표·역슬래시 규칙으로 글자를 모으되,
    따옴표 밖의 셸 연산자는 전부 거절한다 — 해석하지 않을 문법은 받지 않는다."""
    # stderr 를 버리는 리다이렉트는 걷어낸다 — 실패를 0건으로 읽지 않으려면 stderr 를 봐야 한다.
    w = re.sub(r'(?<!\S)2>\s*/dev/null(?!\S)', ' ', cmd)
    w = re.sub(r'(?<!\S)2>&1(?!\S)', ' ', w)
    stages, cur, tok, glob_, i, n = [], [], None, False, 0, len(w)
    def push():
        nonlocal tok, glob_
        if tok is not None: cur.append((''.join(tok), glob_))
        tok, glob_ = None, False
    while i < n:
        c = w[i]
        if c in ' \t':
            push(); i += 1; continue
        if c == "'":
            j = w.find("'", i + 1)
            if j < 0: return None, '닫히지 않은 작은따옴표'
            tok = (tok or []) + list(w[i + 1:j]); i = j + 1; continue
        if c == '"':
            tok = tok or []; i += 1
            while i < n and w[i] != '"':
                if w[i] == '\\' and i + 1 < n and w[i + 1] in '"\\$`\n':
                    tok.append(w[i + 1]); i += 2; continue
                if w[i] in '$`': return None, f'큰따옴표 안의 `{w[i]}` (치환)'
                tok.append(w[i]); i += 1
            if i >= n: return None, '닫히지 않은 큰따옴표'
            i += 1; continue
        if c == '\\':
            if i + 1 >= n or w[i + 1] == '\n': return None, '줄 끝 역슬래시'
            tok = (tok or []) + [w[i + 1]]; i += 2; continue
        if c == '|':
            if i + 1 < n and w[i + 1] == '|': return None, '`||` (연결)'
            push()
            if not cur: return None, '빈 파이프 단계'
            stages.append(cur); cur = []; i += 1; continue
        if c in ';&<>()$`\n{}':
            return None, f'허용하지 않는 문자 `{c}` (연결·리다이렉트·치환·확장)'
        if c == '~' and tok is None:
            return None, '`~` 확장은 하지 않는다'
        if c in '*?[': glob_ = True
        tok = (tok or []) + [c]; i += 1
    push()
    if not cur: return None, '빈 명령'
    stages.append(cur)
    return stages, ''

def _opt_hit(args, shorts, longs):
    """짧은 옵션 묶음(-nO)·붙은 값(-Otouch)·긴 옵션 접두 축약(--out)까지 본다."""
    for a in args:
        if a == '--': break
        if a.startswith('--') and len(a) > 2:
            name = a.split('=', 1)[0]
            # getopt_long·git 은 모호하지 않은 접두면 다 받는다(--o = --output) — 길이 문턱을 두지 않는다
            if any(l.startswith(name) for l in longs): return a
        elif a.startswith('-') and len(a) > 1:
            if any(ch in shorts for ch in a[1:]): return a
    return None

def git_sub_index(argv):
    """git 하위 명령의 위치. 전역 옵션은 `-C <dir>`·`--no-pager` 만 받는다 — 검사와 보호 플래그 삽입이
    같은 위치를 보도록 한 곳에서 정한다(`-C diff` 의 값을 하위 명령으로 읽으면 안 된다)."""
    i = 1
    while i < len(argv) and argv[i].startswith('-'):
        if argv[i] == '-C' and i + 1 < len(argv): i += 2; continue
        if argv[i] == '--no-pager': i += 1; continue
        return None, f'git 전역 옵션 `{argv[i]}`'
    if i >= len(argv) or argv[i] not in GIT_SUB:
        return None, f'git 하위 명령 `{argv[i] if i < len(argv) else ""}` 은 허용 목록 밖이다'
    return i, ''

def check_stage(argv):
    if not argv: return '빈 단계'
    name = argv[0]
    if '/' in name or '=' in name: return f'`{name}` — 경로·환경변수 지정은 허용하지 않는다'
    if name not in ALLOW: return f'`{name}` 은 허용 목록 밖이다'
    args = argv[1:]
    if name == 'find' and any(a in FIND_BAD for a in args): return 'find 의 실행·쓰기 동작'
    # 허용 목록에서 위치 인자가 출력 파일이 되는 것은 uniq 뿐이다(`uniq in out`, `uniq - out`).
    # 피연산자 개수를 세는 대신 피연산자를 아예 받지 않는다 — 파이프 입력만.
    if name == 'uniq' and any(a in ('-', '--') or not a.startswith('-') for a in args):
        return 'uniq 은 파이프 입력만 받는다 (파일 피연산자는 출력 파일이 될 수 있다)'
    if name == 'git':
        k, why = git_sub_index(argv)
        if why: return why
        args = argv[k + 1:]
    if name in DENY:
        hit = _opt_hit(args, *DENY[name])
        if hit: return f'{name} 의 실행·쓰기 옵션 `{hit}`'
    return ''

def expand(stage):
    out = []
    for t, g in stage:
        # root_dir= 는 3.10 부터다 — 시스템 python 3.9 에서도 돌도록 root 를 붙여 펼치고 상대경로로 되돌린다
        hits = [] if not g else sorted(_glob.glob(t)) if os.path.isabs(t) else \
            sorted(os.path.relpath(h, root) for h in _glob.glob(os.path.join(_glob.escape(root), t)))
        out += hits or [t]
    return out

def validate(cmd):
    """(실행할 argv 단계 목록, 거절 사유)."""
    stages, why = tokenize(cmd)
    if stages is None: return None, why
    argvs = []
    for st in stages:
        argv = expand(st)
        why = check_stage(argv)
        if why: return None, why
        # 저장소 설정의 외부 diff·textconv 를 끈다 — 실행 옵션을 막은 것과 같은 이유다
        if argv[0] == 'git':
            k, _ = git_sub_index(argv)
            if argv[k] in ('log', 'diff', 'show'): argv = argv[:k + 1] + ['--no-ext-diff', '--no-textconv'] + argv[k + 1:]
            elif argv[k] == 'blame': argv = argv[:k + 1] + ['--no-textconv'] + argv[k + 1:]
        argvs.append(argv)
    return argvs, ''

def patterns(cmd):
    """grep 계열 단계의 검색 패턴들. 양성 대조가 **같은 패턴**인지 보려고 쓴다."""
    pats = set()
    stages, _ = tokenize(cmd)
    for st in stages or []:
        a = [t for t, _g in st]
        if a and a[0] == 'git' and 'grep' in a: a = a[a.index('grep'):]
        if not a or a[0] not in ('grep', 'egrep', 'fgrep'): continue
        rest, i = a[1:], 0
        while i < len(rest):
            x = rest[i]
            if x in ('-e', '--regexp'):
                if i + 1 < len(rest): pats.add(rest[i + 1])
                i += 2; continue
            if x.startswith('--regexp='): pats.add(x.split('=', 1)[1])
            elif x == '--': pass
            elif not x.startswith('-'):
                pats.add(x); break
            i += 1
    return pats

_ENV = {k: v for k, v in os.environ.items() if k not in ('GIT_EXTERNAL_DIFF',)}
_ENV.update({'GIT_PAGER': 'cat', 'PAGER': 'cat', 'GIT_OPTIONAL_LOCKS': '0',
             # 저장소 설정이 부르는 외부 명령을 끈다 — 샌드박스가 막지만 이중으로 둔다
             'GIT_CONFIG_COUNT': '2', 'GIT_CONFIG_KEY_0': 'core.fsmonitor', 'GIT_CONFIG_VALUE_0': 'false',
             'GIT_CONFIG_KEY_1': 'core.hooksPath', 'GIT_CONFIG_VALUE_1': '/dev/null'})
_CACHE = {}

# ── OS 샌드박스. 허용 목록·옵션 거절만으로는 닫히지 않는다 — 허용한 프로그램이 레포 내용에서 실행 설정을
#    읽는다(레포에 커밋된 bare 저장소의 core.fsmonitor 를 `git -C` 가 실행했다). 그래서 실행은 커널이 막는
#    상자 안에서만 한다: 파일 쓰기·네트워크 금지, 프로세스 실행은 허용 목록 바이너리의 실제 경로만.
#    **검증된 샌드박스가 없는 플랫폼에서는 실행하지 않는다** — macOS sandbox-exec 만 실측했다.
#    CLAIM_VERIFY_NO_SANDBOX=1 은 실행을 끄는 쪽으로만 작동한다(시험용, 켜는 스위치는 없다).
_SBX = '/usr/bin/sandbox-exec'

def _resolve(name):
    p = shutil.which(name, path=_ENV.get('PATH'))
    return os.path.realpath(p) if p else None

def _sandbox():
    """(접두 argv 를 만드는 함수, 없음 사유)."""
    if os.environ.get('CLAIM_VERIFY_NO_SANDBOX') == '1':
        return None, '샌드박스를 끈 실행(CLAIM_VERIFY_NO_SANDBOX)이라 실행하지 않았다'
    if sys.platform == 'darwin' and os.access(_SBX, os.X_OK):
        bins = {b for b in (_resolve(n) for n in ALLOW) if b}
        # /usr/bin/git 같은 시스템 도구는 심링크가 아니라 xcrun shim 이라 개발자 디렉터리의 실제 바이너리를
        # 다시 exec 한다 — 그것도 허용해야 상자 안에서 돈다. `xcrun -f` 는 도구가 없으면 설치 창을 띄우므로
        # 창을 띄우지 않는 `xcode-select -p` 로 디렉터리만 얻는다.
        try:
            dev = subprocess.run(['/usr/bin/xcode-select', '-p'], capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            dev = ''
        if dev:
            bins |= {os.path.realpath(c) for c in (os.path.join(dev, 'usr', 'bin', n) for n in ALLOW) if os.access(c, os.X_OK)}
        bins = sorted(bins)
        q = lambda x: '"' + x.replace('\\', '\\\\').replace('"', '\\"') + '"'
        prof = ('(version 1)(allow default)(deny network*)'
                '(deny file-write*)(allow file-write* (literal "/dev/null"))'
                '(deny process-exec)(allow process-exec ' + ' '.join(f'(literal {q(b)})' for b in bins) + ')')
        _PROF[0] = prof
        return (lambda argv: [_SBX, '-p', prof, *argv]), ''
    return None, f'{sys.platform} 에는 검증된 샌드박스가 없어 실행하지 않았다'

_PROF = ['']
_BOX, _NOBOX = _sandbox()
if os.environ.get('PROFILE_ONLY') == '1':
    print(_PROF[0])
    if not _PROF[0]: print(_NOBOX, file=sys.stderr)
    sys.exit(0)

def run(argvs):
    key = tuple(tuple(a) for a in argvs)
    if key in _CACHE: return _CACHE[key]
    procs, errs, prev = [], [], None
    try:
        for argv in argvs:
            full = _resolve(argv[0])
            if not full: raise FileNotFoundError(argv[0])
            argv = _BOX([full, *argv[1:]])
            ef = tempfile.TemporaryFile()
            p = subprocess.Popen(argv, cwd=root, env=_ENV, stdin=prev.stdout if prev else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=ef)
            if prev: prev.stdout.close()
            procs.append(p); errs.append(ef); prev = p
        out, _ = procs[-1].communicate(timeout=15)
        for p in procs[:-1]: p.wait(timeout=5)
        err = b''.join((e.seek(0) or e.read()) for e in errs).decode('utf-8', 'replace').strip()
        r = {'rc': procs[-1].returncode, 'out': out.decode('utf-8', 'replace')[:200000], 'err': err[:300]}
    except FileNotFoundError as e:
        r = {'rc': 127, 'out': '', 'err': str(e)[:300]}
    except subprocess.TimeoutExpired:
        r = {'rc': 124, 'out': '', 'err': '15초 초과'}
    finally:
        for p in procs:
            if p.poll() is None: p.kill()
        for e in errs: e.close()
    _CACHE[key] = r
    return r

def fmt(n):
    return str(int(n)) if float(n).is_integer() else str(n)

def has_num(text, n):
    s = fmt(n)
    forms = {s}
    if float(n).is_integer() and abs(n) >= 1000: forms.add(f'{int(n):,}')
    return any(re.search(rf'(?<![\d.]){re.escape(f)}(?![\d])', text) for f in forms)

def zeroish(out):
    t = out.strip()
    return t == '' or all(tok == '0' for tok in re.findall(r'\d+', t)) and not re.search(r'[A-Za-z가-힣/]', t.replace(' ', ''))

def controlled(zero_cmds, pos_cmds):
    """0건 명령마다, 같은 검색 패턴으로 무언가를 찾은 명령이 있는가.
    패턴을 뽑을 수 없는 0건 명령(find 등)은 아무 양성 명령이나 대조로 인정한다."""
    for z in zero_cmds:
        zp = patterns(z)
        if not any((zp & patterns(p)) if zp else True for p in pos_cmds):
            return False
    return bool(pos_cmds)

findings = []
counts = {'claims': 0, 'verified': 0, 'warn': 0, 'info': 0}

def add(c, rule, msg, cmds=None):
    if rule not in RULES: raise ValueError(f'RULES 에 없는 rule: {rule}')
    findings.append({'rule': rule, 'severity': 'info' if rule in INFO else 'warn', 'blocking': False,
                     'source': c['source'], 'file': c['file'], 'line': c['line'], 'text': c['text'],
                     'message': msg, **({'commands': cmds} if cmds else {})})

for c in data.get('claims', []):
    counts['claims'] += 1
    before = len(findings)
    kinds = set(c.get('kinds', []))
    absence = 'absence' in kinds
    # 비율·백분율 정합은 실행 없이 판정한다 — 342/404 는 84.7% 다
    if c.get('ratios') and c.get('percents'):
        exp = [100.0 * r['part'] / r['total'] for r in c['ratios'] if r['total']]
        comp = exp + [100.0 - e for e in exp]   # 'N 중 M 이 없다' 와 '준수율' 은 서로의 여집합이다
        bad = [p for p in c['percents'] if not any(abs(p - e) <= 1.0 for e in comp)]
        if bad:
            add(c, 'claim/percent-inconsistent',
                f"백분율 {', '.join(fmt(p) + '%' for p in bad)} 가 같은 줄의 비율 "
                f"{', '.join(fmt(r['part']) + '/' + fmt(r['total']) for r in c['ratios'])} 과 맞지 않는다")
    srcs = c.get('sources') or []
    if not srcs:
        if kinds & {'ratio', 'percent', 'absence'}:
            add(c, 'claim/no-source',
                ('부재 주장인데' if absence else '수치 주장인데') +
                ' 재현 명령이 붙어 있지 않다 — 주장 바로 앞뒤 코드 블록에 `$ 명령` 과 출력을 적거나, '
                '명령을 적을 수 없으면 수치가 아니라 관찰로 써라')
        else:
            add(c, 'claim/count-no-source', '건수 주장에 재현 명령이 붙어 있지 않다')
        continue
    ran, unver, failed, outs, zero_cmds, pos_cmds, cmdlog = [], [], [], [], [], [], []
    for s in srcs:
        for k in s.get('commands', []):
            safe, why = validate(k['cmd'])
            if safe is not None and _BOX is None: safe, why = None, _NOBOX
            if safe is None:
                unver.append(k['cmd']); cmdlog.append({'cmd': k['cmd'], 'ran': False, 'reason': why}); continue
            r = run(safe)
            ok = r['rc'] in (0, 1) and not r['err']
            entry = {'cmd': k['cmd'], 'ran': True, 'rc': r['rc']}
            if not ok:
                entry['stderr'] = r['err']; failed.append(entry); cmdlog.append(entry); continue
            rec = (k.get('recorded') or '').strip()
            if rec and rec != r['out'].strip(): entry['recordedDiffers'] = True
            cmdlog.append(entry); ran.append(k['cmd']); outs.append(r['out'])
            (zero_cmds if zeroish(r['out']) else pos_cmds).append(k['cmd'])
    if failed:
        add(c, 'claim/command-failed',
            f"재현 명령 {len(failed)}개가 실패했다 — 실패한 명령의 빈 출력을 0건으로 읽으면 안 된다: " +
            '; '.join(f"`{e['cmd']}` rc={e['rc']} {e.get('stderr', '')[:120]}" for e in failed), cmdlog)
    if unver and not ran:
        add(c, 'claim/unverifiable', '재현 명령이 허용 목록 밖이라 실행하지 않았다: ' +
            '; '.join(f"`{e['cmd']}` ({e['reason']})" for e in cmdlog if not e['ran']), cmdlog)
    if ran:
        combined = '\n'.join(outs)
        need = [n for n in c.get('numbers', []) if not (absence and n == 0)]
        # 비율과 맞는 백분율은 출력에 없어도 된다 — 파생값이다
        derived = {p for p in c.get('percents', [])
                   if any(abs(p - 100.0 * r['part'] / r['total']) <= 1.0 or abs(p - (100.0 - 100.0 * r['part'] / r['total'])) <= 1.0
                          for r in c.get('ratios', []) if r['total'])}
        missing = [n for n in need if n not in derived and not has_num(combined, n)]
        if missing:
            add(c, 'claim/mismatch',
                f"다시 돌린 출력에 주장 숫자 {', '.join(fmt(n) for n in missing)} 이 없다", cmdlog)
        if absence:
            if not zero_cmds:
                add(c, 'claim/mismatch', '부재 주장인데 다시 돌린 명령이 모두 무언가를 찾았다', cmdlog)
            elif not controlled(zero_cmds, pos_cmds):
                add(c, 'claim/absence-no-control',
                    '부재 주장인데 같은 블록에 무언가를 찾는 양성 대조가 없다 — 같은 패턴이 알려진 대상에서 '
                    '1건 이상 나오는 명령을 함께 적어라 (패턴·경로가 틀려도 0건이 나온다)', cmdlog)
    if not any(f['severity'] == 'warn' for f in findings[before:]) and ran:
        counts['verified'] += 1

counts['warn'] = sum(1 for f in findings if f['severity'] == 'warn')
counts['info'] = sum(1 for f in findings if f['severity'] == 'info')
# 읽지 못한 입력이 있으면 CLEAN 이라 말하지 않는다 — 빈 결과는 "주장 없음" 의 증거가 아니다
scan_errors = (data.get('scanned') or {}).get('errors') or []
out = {'status': 'PARTIAL' if scan_errors else 'WARN' if counts['warn'] else 'CLEAN', 'counts': counts, 'findings': findings,
       'scanned': data.get('scanned', {}),
       'limits': '주장은 정규식으로 뽑는다(한 줄 = 주장 하나). 재현 명령은 주장 문단 바로 앞뒤 블록의 `$ 명령` 과 '
                 '같은 줄 인라인 `명령` → 값 만 인정한다. 출력 대조는 숫자 토큰 존재만 본다 — 같은 숫자가 다른 뜻으로 '
                 '나와도 일치로 센다. 주장이 맞는지가 아니라 출처가 주장을 떠받치는지를 본다.'}
def _disp(s):
    return s.encode('utf-8', 'backslashreplace').decode('utf-8')
if os.environ['JSON'] == '1':
    print(_json_out(out, indent=2))
else:
    for f in findings:
        print(f"{_disp(f['file'])}:{f['line']}  {f['severity']:4}  {f['message']}  [{f['rule']}]\n      {_disp(f['text'][:120])}")
    for e in scan_errors: print(f"읽지 못함: {_disp(e)}")
    print(f"\n주장 {counts['claims']} · 출처 확인 {counts['verified']} · 경고 {counts['warn']} · 참고 {counts['info']} (막지 않는다)")
ZZEND
