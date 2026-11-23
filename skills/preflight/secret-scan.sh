#!/bin/bash
# preflight secret-scan — 시크릿 검사의 1차 판정을 정규식으로 한다(결정론, LLM 호출 없음).
#
# 분류기(classify.sh)가 claimCheck 처럼 직접 부르고, 기록 단계(receipt.sh record)가 같은 대상으로 다시 부른다.
# 검사 단계(lane)가 아니다 — secret-scanner lane 을 부를지 정하는 근거다(DECISIONS.md 「시크릿 검사 결정론 우선」).
#
# usage: secret-scan.sh <dir> commit|pr [--from <rev>] [--files-from <NUL 구분 목록 파일>]
#                       [--category <이름>] [--extra <glob>]...
#   commit : HEAD 대 인덱스(커밋될 내용). HEAD 가 없으면 빈 트리 대 인덱스.
#   pr     : <from>..HEAD. --from 이 없으면 classify.sh 와 같은 규칙으로 base 를 해석한다
#            (origin/HEAD → origin/develop|master|main 의 merge-base, 못 구하면 빈 트리부터).
#   --files-from : 검사할 파일 목록(분류의 files.all). 없으면 범위의 변경 파일 전부다.
#            기록 단계는 이 값을 넘기지 않는다 — 분류 artifact 의 목록을 믿지 않고 범위에서 다시 구한다.
#   --category : 카테고리 rules.py 의 SECRET_SENSITIVE_EXTRA(민감 경로 glob 튜플)를 더한다. 루트는 lib.sh pf_category_roots.
#            같은 rules.py 의 SECRET_SCAN 으로 categoryMode('auto'|'always')를 낸다 — 기록 단계가 모드를 다시 구하는 근거다.
#   --extra : 민감 경로 glob 을 직접 더한다(여러 번).
#
# stdout: {status, patternsVersion, scannedLines, files, hits:[{file,line,pattern,grade}], sensitivePaths, ...}
#   status: CLEAN | HITS | SENSITIVE_PATH | SCAN_ERROR
#   categoryMode: 'auto' | 'always' — 카테고리를 읽었을 때만 낸다(없으면 'always'). mode=all 은 반영하지 않는다(호출자 몫).
#   **값은 어디에도 내지 않는다** — 패턴 이름·파일·줄 번호만. 이 출력은 분류 JSON 과 lane 프롬프트로 간다.
#   같은 입력이면 같은 출력이다(시각·난수 없음, 정렬).
# exit: 0 스캔 결과를 냈다(SCAN_ERROR 포함) · 2 사용법 오류
set -uo pipefail

dir="${1:-}"; mode="${2:-}"
[ -n "$dir" ] && [ -n "$mode" ] || { echo "usage: secret-scan.sh <dir> commit|pr [--from <rev>] [--files-from <file>] [--category <이름>] [--extra <glob>]..." >&2; exit 2; }
case "$mode" in commit|pr) ;; *) echo "mode 는 commit|pr 이다: $mode" >&2; exit 2 ;; esac
shift 2
from=''; files_from=''; category=''; extras=()
while [ $# -gt 0 ]; do
    case "$1" in
        --from) [ $# -ge 2 ] || { echo "--from 에 값이 없다" >&2; exit 2; }; from="$2"; shift 2 ;;
        --files-from) [ $# -ge 2 ] || { echo "--files-from 에 값이 없다" >&2; exit 2; }; files_from="$2"; shift 2 ;;
        --category) [ $# -ge 2 ] || { echo "--category 에 값이 없다" >&2; exit 2; }; category="$2"; shift 2 ;;
        --extra) [ $# -ge 2 ] || { echo "--extra 에 값이 없다" >&2; exit 2; }; extras+=("$2"); shift 2 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELFDIR/lib.sh"

# -I: 대상 레포의 파일이 import 경로에 끼지 않게 한다. 인자는 argv 로, 설정은 환경으로 넘긴다.
SS_DIR="$dir" SS_MODE="$mode" SS_FROM="$from" SS_FILES_FROM="$files_from" SS_CATEGORY="$category" \
SS_PATTERNS="$SELFDIR/secret-patterns.json" SS_CATROOTS="$(pf_category_roots)" \
python3 -I - "${extras[@]+"${extras[@]}"}" <<'PY'
import json, os, re, subprocess, sys

DIR = os.environ['SS_DIR']; MODE = os.environ['SS_MODE']
EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
HITS_CAP = 200
_DEC = {'encoding': 'utf-8', 'errors': 'surrogateescape'}

def out(obj):
    s = json.dumps(obj, ensure_ascii=False, sort_keys=True)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, sort_keys=True)
    print(s)

def fail(reason, **kw):
    """스캔을 끝내지 못했다 — 판단이 서지 않으면 도는 쪽이다(secret-scanner 를 부른다)."""
    if globals().get('CAT_MODE'):          # 카테고리를 읽은 뒤의 실패면 모드는 안다
        kw.setdefault('categoryMode', CAT_MODE)
    out({'status': 'SCAN_ERROR', 'reason': reason, 'patternsVersion': kw.pop('version', None),
         'scannedLines': 0, 'files': kw.pop('files', 0), 'hits': [], 'hitsTruncated': 0,
         'sensitivePaths': [], **kw})
    sys.exit(0)

def git(*a):
    # core.quotePath 는 대상 레포 설정을 그대로 둔다 — 헤더 파서가 두 표기(원문·C 인용)를 다 받는다.
    p = subprocess.run(['git', '-C', DIR, *a], capture_output=True, **_DEC)
    return p.returncode, p.stdout, p.stderr.strip()

# ── 패턴 정본
try:
    PJ = json.load(open(os.environ['SS_PATTERNS'], encoding='utf-8'))
    VERSION = str(PJ['version'])
    PATS = [(p['name'], p['grade'], re.compile(p['regex']), bool(p.get('scanRemoved'))) for p in PJ['patterns']]
    SENS = [g for g in PJ['sensitivePaths'] if isinstance(g, str) and g]
except Exception as e:
    fail(f'패턴 파일을 읽지 못했다 ({type(e).__name__}: {e})'[:200])

# ── 카테고리가 더하는 민감 경로
extras = [a for a in sys.argv[1:] if a]
cat = os.environ.get('SS_CATEGORY') or ''
# CONTRACT: secret-scan-mode-rule — classify.sh SECRET_SCAN_MODE 와 같은 규칙이다: 상수가 정확히 'auto' 일 때만 auto,
# 없거나 'always'·알 수 없는 값이면 always. 카테고리가 없으면 always(classify.sh 의 CAT 없음과 같다).
# 카테고리를 읽기 전의 실패(SCAN_ERROR)에는 categoryMode 가 없다 — 기록 단계는 그때 모드 대조를 하지 않고
# status 가 CLEAN 이 아니라는 이유로 secret-scanner 결과를 요구한다.
CAT_MODE = None
_cat_mode = 'always'
if cat:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', cat):
        fail(f'카테고리 이름이 아니다: {cat!r}', version=VERSION)
    _rp = next((os.path.join(r, cat, 'rules.py') for r in os.environ.get('SS_CATROOTS', '').split(':')
                if r and os.path.isfile(os.path.join(r, cat, 'rules.py'))), None)
    if not _rp:
        fail(f'카테고리 {cat} 의 rules.py 가 없다', version=VERSION)
    try:
        import importlib.util
        sys.dont_write_bytecode = True
        _spec = importlib.util.spec_from_file_location('pf_secret_scan_category', _rp)
        _mod = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_mod)
        _ex = getattr(_mod, 'SECRET_SENSITIVE_EXTRA', ()) or ()
        assert isinstance(_ex, (tuple, list)) and all(isinstance(g, str) and g for g in _ex), 'SECRET_SENSITIVE_EXTRA 는 glob 문자열 튜플이다'
        extras += list(_ex)
        _cat_mode = 'auto' if getattr(_mod, 'SECRET_SCAN', None) == 'auto' else 'always'
    except Exception as e:
        fail(f'카테고리 {cat} 의 rules.py 를 읽지 못했다 ({type(e).__name__}: {e})'[:200], version=VERSION)
extras = sorted(set(extras))
CAT_MODE = _cat_mode

def _seg(p):
    r = ''
    for ch in p:
        r += '[^/]*' if ch == '*' else '[^/]' if ch == '?' else re.escape(ch)
    return r

def glob_re(g):
    """secret-patterns.json 의 sensitivePathsSyntax 그대로."""
    if '/' not in g:
        return re.compile('^(?:.*/)?' + _seg(g) + '$')
    parts = g.strip('/').split('/')
    rx = ''
    for i, p in enumerate(parts):
        last = i == len(parts) - 1
        if p == '**':
            rx += '.*' if last else '(?:[^/]+/)*'
        else:
            rx += _seg(p) + ('' if last else '/')
    return re.compile('^' + rx + '$')

SENS_RE = [glob_re(g) for g in SENS + extras]

# ── 범위
rc, head, _ = git('rev-parse', '--verify', '-q', 'HEAD')
head = head.strip() if rc == 0 else ''
if MODE == 'commit':
    rng = ['--cached', head or EMPTY_TREE]
    rng_out = {'from': head or EMPTY_TREE, 'to': 'index'}
else:
    if not head:
        rng = None
        rng_out = {'from': None, 'to': None}
    else:
        frm = os.environ.get('SS_FROM') or ''
        if not frm:
            # classify.sh resolve_base 와 같은 규칙. 둘이 갈리면 기록 단계의 대조가 거부한다(도는 쪽).
            _rc, ref, _ = git('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD')
            ref = ref.strip()
            base = ref[len('refs/remotes/'):] if _rc == 0 and ref.startswith('refs/remotes/') else ''
            if not base:
                for cand in ('origin/develop', 'origin/master', 'origin/main'):
                    if git('rev-parse', '--verify', '--quiet', cand)[0] == 0:
                        base = cand; break
            if base:
                _rc, mb, _ = git('merge-base', base, 'HEAD')
                frm = mb.strip() if _rc == 0 else ''
            frm = frm or EMPTY_TREE
        rng = [frm, head]
        rng_out = {'from': frm, 'to': head}

# ── 파일 목록
ff = os.environ.get('SS_FILES_FROM') or ''
if ff:
    try:
        with open(ff, 'rb') as fh:
            files = sorted({x.decode('utf-8', 'surrogateescape') for x in fh.read().split(b'\0') if x})
    except Exception as e:
        fail(f'파일 목록을 읽지 못했다 ({type(e).__name__})', version=VERSION)
elif rng is None:
    files = []
else:
    rc, so, se = git('diff', '--no-renames', '--name-only', '-z', *rng)
    if rc != 0:
        fail(f'변경 목록을 구하지 못했다: {se[:160]}', version=VERSION)
    files = sorted({x for x in so.split('\0') if x})

fileset = set(files)

# ── 변경 수(numstat) — 스캔 결과를 대조할 기준. 바이너리(`-\t-`)는 내용 스캔이 안 되므로 민감 경로로 본다.
numstat = {}          # 경로 → (추가, 삭제) | None(바이너리)
if files and rng is not None:
    rc, so, se = git('diff', '--no-ext-diff', '--no-renames', '--no-textconv', '--numstat', '-z', *rng)
    if rc != 0:
        fail(f'변경 수(numstat)를 구하지 못했다: {se[:160]}', version=VERSION, files=len(files))
    for rec in so.split('\0'):
        if not rec:
            continue
        parts = rec.split('\t', 2)
        if len(parts) != 3:
            fail('numstat 출력 형식을 읽지 못했다', version=VERSION, files=len(files))
        ad, de, pth = parts
        numstat[pth] = None if (ad == '-' and de == '-') else (int(ad), int(de))
binary_files = sorted(f for f in files if f in numstat and numstat[f] is None)
sens_paths = sorted(set(f for f in files if any(r.match(f) for r in SENS_RE)) | set(binary_files))

# ── 헤더 경로 표기. git diff 의 `--- `/`+++ ` 뒤는 다음 중 하나다(전부 처리한다):
#   1. /dev/null                         — 추가·삭제의 반대편
#   2. a/<경로> · b/<경로>                — 접두(--src-prefix/--dst-prefix 로 고정)
#   3. 위 2 + 끝 TAB                      — 경로에 공백이 있으면 git 이 헤더 끝에 TAB 을 붙인다
#   4. "a/<경로>" · "b/<경로>" (C 인용)    — 큰따옴표 안에 \a \b \t \n \v \f \r \" \\ 와 \ooo(8진 바이트).
#      core.quotePath(기본 true)면 비ASCII 바이트도 \ooo 로 나온다. 인용 뒤에 TAB 이 붙는 경우도 받는다.
_CESC = {'a': 7, 'b': 8, 't': 9, 'n': 10, 'v': 11, 'f': 12, 'r': 13, '"': 34, '\\': 92}
def _unquote(q):
    out = bytearray(); i = 0
    while i < len(q):
        ch = q[i]
        if ch != '\\':
            out += ch.encode('utf-8', 'surrogateescape'); i += 1; continue
        nx = q[i + 1:i + 2]
        if nx in _CESC:
            out.append(_CESC[nx]); i += 2
        elif re.fullmatch(r'[0-7]{3}', q[i + 1:i + 4] or ''):
            out.append(int(q[i + 1:i + 4], 8)); i += 4
        else:
            raise ValueError('알 수 없는 이스케이프')
    return out.decode('utf-8', 'surrogateescape')

def _path(s, prefix):
    """헤더 경로를 원래 경로로. 표기를 모르면 ValueError — 파일이 빠지면 아래 대조가 SCAN_ERROR 로 낸다."""
    s = s.rstrip('\n')
    if s.endswith('\t'):
        s = s[:-1]
    if s == '/dev/null':
        return None
    if len(s) >= 2 and s.startswith('"') and s.endswith('"'):
        s = _unquote(s[1:-1])
    if not s.startswith(prefix):
        raise ValueError('접두 없음')
    return s[len(prefix):]

# 검증용: 파서가 파일을 놓친 경우를 흉내 낸다 — 더 엄격해지는 쪽(SCAN_ERROR)으로만 움직인다.
_TEST_DROP = os.environ.get('PF_SECRET_SCAN_TEST_DROP') or ''

# ── diff 스캔
hits, added, removed = [], 0, 0
scanned_files = set()
header_errors = 0
if files and rng is not None:
    rc, so, se = git('diff', '--no-ext-diff', '--no-color', '--no-renames', '--no-textconv', '-U0',
                     '--src-prefix=a/', '--dst-prefix=b/', *rng)
    if rc != 0:
        fail(f'diff 를 구하지 못했다: {se[:160]}', version=VERSION, files=len(files))

    minus = plus = cur = None
    oln = nln = 0
    HUNK = re.compile(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
    for line in so.split('\n'):
        if line.startswith('diff --git '):
            minus = plus = cur = None
            continue
        if cur is None and line.startswith('--- '):
            try:
                minus = _path(line[4:], 'a/')
            except ValueError:
                minus = None; header_errors += 1
            continue
        if cur is None and line.startswith('+++ '):
            try:
                plus = _path(line[4:], 'b/')
            except ValueError:
                plus = None; header_errors += 1
            cur = plus or minus
            if cur not in fileset or (_TEST_DROP and cur == _TEST_DROP):
                cur = ''          # 목록 밖 파일 — 건너뛴다
            continue
        m = HUNK.match(line)
        if m:
            oln, nln = int(m.group(1)), int(m.group(2))
            continue
        if not cur:
            continue
        if line.startswith('+'):
            added += 1; scanned_files.add(cur)
            body = line[1:]
            for name, grade, rx, _sr in PATS:
                if rx.search(body):
                    hits.append({'file': cur, 'line': nln, 'pattern': name, 'grade': grade})
            nln += 1
        elif line.startswith('-'):
            removed += 1; scanned_files.add(cur)
            body = line[1:]
            for name, grade, rx, sr in PATS:
                if sr and rx.search(body):
                    hits.append({'file': cur, 'line': oln, 'pattern': name, 'grade': 'removed'})
            oln += 1

# 안전망: numstat 이 줄 변경이 있다고 한 텍스트 파일은 전부 스캔에 들어갔어야 한다. 하나라도 빠지면 헤더 파서가
# 놓친 것이다 — CLEAN 으로 내면 거짓 음성이다. 목록에 있는데 범위에 없는 파일도 범위가 틀린 것이다.
_text_changed = {f for f in files if numstat.get(f) and sum(numstat[f]) > 0}
missed = sorted(_text_changed - scanned_files)
not_in_range = sorted(f for f in files if f not in numstat) if (files and rng is not None) else []
hits.sort(key=lambda h: (h['file'], h['line'], h['grade'], h['pattern']))
scanned = added + removed
if missed or not_in_range or header_errors:
    status = 'SCAN_ERROR'
    reason = (f'스캔이 변경 파일을 놓쳤다 — numstat 대조 누락 {len(missed)}개, 범위 밖 {len(not_in_range)}개, '
              f'읽지 못한 헤더 {header_errors}개')
elif files and scanned == 0 and not binary_files:
    # 지금 LLM 지침의 "빈 diff 를 PASS 로 결론내지 마라" 를 코드로 옮긴 것 — 범위가 틀린 것이지 변경이 없는 것이 아니다.
    status = 'SCAN_ERROR'
    reason = '파일 목록이 비지 않았는데 범위의 추가·삭제 라인이 0이다'
elif hits:
    status, reason = 'HITS', None
elif sens_paths:
    status, reason = 'SENSITIVE_PATH', None
else:
    status, reason = 'CLEAN', None
res = {'status': status, 'patternsVersion': VERSION, 'scannedLines': scanned,
       'addedLines': added, 'removedLines': removed, 'files': len(files), 'range': rng_out,
       'hits': hits[:HITS_CAP], 'hitsTruncated': max(0, len(hits) - HITS_CAP),
       'sensitivePaths': sens_paths, 'sensitiveExtra': extras, 'binaryFiles': binary_files,
       'missedFiles': (missed + not_in_range)[:50], 'categoryMode': CAT_MODE}
if reason:
    res['reason'] = reason
out(res)
PY
