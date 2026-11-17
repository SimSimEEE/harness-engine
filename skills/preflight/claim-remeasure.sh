#!/usr/bin/env bash
# 사실 주장 재측정 (claim-check ③) 의 결정론 부분 — 대상 선별·수치 가리기·등록 레포 스냅숏.
# 재측정 자체는 LLM(claim-remeasurer)이 하고, 대조는 preflight.js 의 remeasure-judge 구간이 한다.
# 이 스크립트는 무엇을 재측정할지, lane 에게 무엇을 보일지, 레포 밖 코퍼스를 어디서 읽게 할지만 정한다.
# 근거는 DECISIONS.md 2026-11-12.
#
# usage:
#   claim-remeasure.sh select [--claims FILE] [claim-extract.sh 인자…]
#       대상 선별. --claims 가 없으면 나머지 인자로 claim-extract.sh 를 부른다(분류기와 같은 인자).
#       stdout: {"ruleLines":[…], "targets":[…], "excludedCountOnly":n, "errors":[…]}
#   claim-remeasure.sh rule-line            stdin 의 줄마다 규칙 줄이면 1, 아니면 0 (판별식 시험용)
#   claim-remeasure.sh resolve [--registry JSON]    등록 레포 해석만 한다(스냅숏을 만들지 않는다)
#   claim-remeasure.sh snapshot [--registry JSON] [--into NAME]   해석 + 사용 가능한 레포를 git archive 로 임시 폴더에 푼다
#       --into 를 주면 $TMPDIR/NAME(pf-snap.*) 아래에 만든다 — remove --into NAME 으로 출력 없이도 지운다.
#       --registry 는 select 가 낸 registry([{name, path}]) 그대로다 — 워크플로가 분류 때 읽은 등록 목록을 넘긴다.
#       없으면 config.json·환경변수에서 다시 읽는다.
#   claim-remeasure.sh remove [--into NAME] <path>...   snapshot 이 만든 경로(pf-snap.*)만 지운다
#
# 등록 레포의 라이브 출처는 머신 로컬 config.json 의 remeasureRepos 와 PF_REMEASURE_REPOS 환경변수뿐이다
# (classify.sh 의 vaultExempt 와 같은 규칙 — 레포에 커밋되는 config.example.json 은 예시다).
#   PF_REMEASURE_REPOS="이름=경로,이름=경로" — 있으면 config.json 보다 우선하고, 빈 문자열은 "등록 없음" 이다.
# 등록 레포에는 네트워크 git 명령(fetch·pull 등)을 부르지 않고 .git 에 아무것도 쓰지 않는다.
# exit: 사용 오류 2, 그 외 0.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cmd="${1:-}"; shift || true
case "$cmd" in
  select|rule-line|resolve|snapshot|remove) ;;
  *) echo "usage: claim-remeasure.sh select [--claims FILE] [claim-extract.sh 인자…] | rule-line | resolve | snapshot | remove <path>..." >&2; exit 2 ;;
esac

# 실행 단위 상위 폴더 이름 — 워크플로가 정해 snapshot·remove 양쪽에 같은 값을 준다(TMPDIR 아래).
_into_ok(){ printf '%s' "$1" | grep -qE '^pf-snap\.[A-Za-z0-9_]+$'; }
if [ "$cmd" = remove ]; then
    [ $# -gt 0 ] || { echo "remove: 경로가 필요하다" >&2; exit 2; }
    rc=0
    # --into NAME: snapshot 의 출력을 받지 못했어도 그 실행이 만든 것을 전부 지운다
    if [ "${1:-}" = --into ]; then
        _into_ok "${2:-}" || { echo "remove: --into 이름 형식이 아니다: ${2:-}" >&2; exit 2; }
        set -- "${TMPDIR:-/tmp}/$2" "${@:3}"
    fi
    for p in "$@"; do
        case "$(basename -- "$p")" in pf-snap.*) ;; *) echo "remove: 이 스크립트가 만든 경로가 아니다: $p" >&2; rc=1; continue ;; esac
        [ -e "$p" ] && rm -rf -- "$p"
        [ ! -e "$p" ] || { echo "remove: 지우지 못했다: $p" >&2; rc=1; }
    done
    exit $rc
fi

CLAIMS=""; REGISTRY=""; HAS_REG=0; INTO=""; PASS=()
while [ $# -gt 0 ]; do
    case "$cmd:$1" in
        select:--claims) CLAIMS="${2:-}"; shift 2 ;;
        snapshot:--registry|resolve:--registry) REGISTRY="${2:-}"; HAS_REG=1; shift 2 ;;
        snapshot:--into) INTO="${2:-}"; _into_ok "$INTO" || { echo "snapshot: --into 이름 형식이 아니다: $INTO" >&2; exit 2; }; shift 2 ;;
        select:*) PASS+=("$1"); shift ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

# python 의 stdin 은 아래 히어독(스크립트)이다 — 판별할 줄은 환경변수로 넘긴다
RL_INPUT=""; [ "$cmd" = rule-line ] && RL_INPUT="$(cat)"
REGISTRY="$REGISTRY" HAS_REG="$HAS_REG" INTO="$INTO" RL_INPUT="$RL_INPUT" CMD="$cmd" SELFDIR="$SELF" CLAIMS="$CLAIMS" python3 - "${PASS[@]+"${PASS[@]}"}" <<'ZZEND'
import json, os, re, shutil, subprocess, sys, tempfile, time

CMD = os.environ['CMD']; SELFDIR = os.environ['SELFDIR']
_DEC = {'encoding': 'utf-8', 'errors': 'surrogateescape'}

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. 경로가 출력에 실린다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

# ── 규칙 줄 판별식. **이 함수 한 곳**이 정한다 — 선별·R2 측정·시험이 모두 이것을 부른다.
# 규칙 줄 = 체크리스트 항목(`- [ ] …`, `1. [x] …`) 이거나, 명령·금지 어미가 있는 줄이다.
# 체크리스트는 2026-09-09 사건 줄(`- [ ] Copyright 줄 존재 (…)`)의 형태이고, 리뷰 에이전트가 따르는 정본의
# 형식이다. 명령·금지 어미는 산문으로 적힌 규칙이다. 근거와 표본 빈도는 DECISIONS.md 2026-11-12.
# CONTRACT: rule-line-is-one-function
P_CHECK = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+\[[ xX]\]\s+\S')
P_NORM = re.compile(r'하지\s*마(?:라|십시오|세요)|(?:해|여|어|아)야\s*한다|금지|반드시|(?i:\b(?:must|shall|never)\b)')
def is_rule_line(s):
    return bool(P_CHECK.match(s) or P_NORM.search(s))

if CMD == 'rule-line':
    for l in os.environ.get('RL_INPUT', '').split('\n'):
        if l: print(1 if is_rule_line(l) else 0)
    sys.exit(0)

# ── 대상 선별 ────────────────────────────────────────────────────────────────
P_FENCE = re.compile(r'^\s{0,3}(```|~~~)')
# 주장 줄의 인라인 재현 명령(`명령` → 값) — claim-extract.sh 의 P_INLINE_SRC 와 같은 식이다
P_INLINE_SRC = re.compile(r'`([^`\n]+)`\s*(?:→|->|=>|=)\s*`?([^`\s,;)]+)')
KINDS = {'ratio', 'percent', 'absence'}

def _args(argv):
    a = {'repo': '.', 'from': 'HEAD', 'to': '', 'cached': False, 'docs': True}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in ('--repo', '--from', '--to', '--commits', '--msg-file', '--body-file'):
            if x in ('--repo', '--from', '--to'): a[x[2:]] = argv[i + 1] if i + 1 < len(argv) else ''
            i += 2; continue
        if x == '--cached': a['cached'] = True
        elif x == '--no-docs': a['docs'] = False
        i += 1
    return a

def fence_lines(lines):
    """코드 블록 안 줄 번호(1-based)와 frontmatter 줄 — 규칙 줄로 보지 않는다(예시 코드는 규칙이 아니다)."""
    inside, i, n = set(), 0, len(lines)
    if lines and lines[0].strip() == '---':
        for k in range(1, n):
            if lines[k].strip() == '---':
                inside.update(range(1, k + 2)); break
    while i < n:
        m = P_FENCE.match(lines[i])
        if m:
            j = i + 1
            while j < n and not lines[j].lstrip().startswith(m.group(1)): j += 1
            inside.update(range(i + 1, min(j, n - 1) + 2)); i = j + 1; continue
        i += 1
    return inside

def rule_lines(a, errors):
    """이 변경이 추적 중인 .md 에서 지우거나 바꾼 규칙 줄. 바뀐 줄은 diff 에서 지운 줄로 나온다."""
    if not a['docs']: return []
    rr = subprocess.run(['git', '-C', a['repo'], 'rev-parse', '--show-toplevel'], capture_output=True, **_DEC)
    repo = rr.stdout.strip()
    if rr.returncode != 0 or not repo:
        errors.append(f"git 레포가 아니다: {a['repo']}"); return []
    def git(*x):
        p = subprocess.run(['git', '-C', repo, '-c', 'core.quotePath=false', *x], capture_output=True, **_DEC)
        return p.returncode, p.stdout
    rng = ['--cached', a['from']] if a['cached'] else [a['from'], a['to']] if a['to'] else [a['from']]
    # 이름만 바뀐 문서는 지운 줄이 없다 — 옮긴 것을 규칙 삭제로 세지 않으려고 이름 바뀜을 찾는다
    rc, out = git('diff', *rng, '--name-status', '-z', '-M', '--no-color', '--diff-filter=DMR')
    if rc != 0:
        errors.append(f"git diff {a['from']} 실패 — 규칙 줄 변경을 보지 못했다"); return []
    tok = [x for x in out.split('\0') if x]
    pairs, i = [], 0
    while i < len(tok):
        st = tok[i]
        if st.startswith('R'): pairs.append((tok[i + 1], tok[i + 2])); i += 3
        else: pairs.append((tok[i + 1], tok[i + 1])); i += 2
    res = []
    for old, new in pairs:
        if not old.lower().endswith('.md'): continue
        rc, d = git('diff', *rng, '-M', '-U0', '--no-color', '--no-ext-diff', '--no-textconv', '--', *sorted({old, new}))
        if rc != 0:
            errors.append(f'git diff 실패: {old}'); continue
        rc, text = git('show', f"{a['from']}:{old}")
        skip = fence_lines(text.split('\n')) if rc == 0 else set()
        cur = None
        for l in d.split('\n'):
            if l.startswith('diff --git'): cur = None; continue
            m = re.match(r'^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@', l)
            if m: cur = int(m.group(1)); continue
            if cur is None: continue
            if l.startswith('-'):
                if cur not in skip and is_rule_line(l[1:]):
                    res.append({'file': old, 'line': cur, 'text': l[1:].strip()[:240]})
                cur += 1
    return res

def mask(c):
    """주장 문장에서 수치를 가린다. 주장 숫자 자리는 ⟨S1⟩·⟨A1⟩ 같은 자리표, 인라인 재현 명령은 통째로,
    나머지 숫자는 전부 ⟨#⟩ 다 — 주장 숫자·원래 명령·기록된 출력이 lane 에 닿지 않는다(앵커링·같은 오류 반복)."""
    text = c.get('text') or ''
    cuts = []    # (start, end, 바꿀 문자열 또는 None=명령)
    for m in P_INLINE_SRC.finditer(text):
        cuts.append((m.start(), m.end(), '‹명령 가림›'))
    def free(s, e):
        return all(e <= a or s >= b for a, b, _ in cuts)
    slots, ratios, n = [], [], {'S': 0, 'A': 0}
    def new(prefix, kind, s, e, value):
        if not (0 <= s < e <= len(text)) or not free(s, e): return None
        n[prefix] += 1
        sid = f'{prefix}{n[prefix]}'
        cuts.append((s, e, f'⟨{sid}⟩'))
        slots.append({'id': sid, 'kind': kind, 'value': value, **({'phrase': text[s:e]} if kind == 'absence' else {})})
        return sid
    val = lambda s, e: (lambda x: int(x) if float(x).is_integer() else x)(float(text[s:e].replace(',', '')))
    spans = c.get('spans') or []
    # 위치 순서로 자리표를 매긴다 — 같은 입력이면 같은 번호다
    order = sorted(spans, key=lambda x: (x.get('total') or x.get('part') or x.get('at') or [0])[0] if x['kind'] == 'ratio'
                   else x['at'][0])
    for sp in order:
        try:
            if sp['kind'] == 'ratio':
                ps, pe = sp['part']; ts, te = sp['total']
                if ts < ps:
                    t_id = new('S', 'ratio-total', ts, te, val(ts, te)); p_id = new('S', 'ratio-part', ps, pe, val(ps, pe))
                else:
                    p_id = new('S', 'ratio-part', ps, pe, val(ps, pe)); t_id = new('S', 'ratio-total', ts, te, val(ts, te))
                if p_id and t_id: ratios.append({'part': p_id, 'total': t_id})
            elif sp['kind'] == 'percent':
                s, e = sp['at']; new('S', 'percent', s, e, val(s, e))
            elif sp['kind'] == 'absence':
                s, e = sp['at']; new('A', 'absence', s, e, 0)
        except (ValueError, TypeError, KeyError):
            continue
    # 짝을 잃은 비율 자리는 비교할 수 없다 — 자리표는 남기되 대조에는 쓰지 않는다
    paired = {r['part'] for r in ratios} | {r['total'] for r in ratios}
    slots = [s for s in slots if not s['kind'].startswith('ratio') or s['id'] in paired]
    out, pos = [], 0
    digits = lambda seg: re.sub(r'\d+', '⟨#⟩', seg)
    for s, e, rep in sorted(cuts):
        out.append(digits(text[pos:s])); out.append(rep); pos = e
    out.append(digits(text[pos:]))
    return ''.join(out), slots, ratios

def select(argv):
    errors = []
    cf = os.environ.get('CLAIMS') or ''
    try:
        if cf:
            data = json.load(open(cf, encoding='utf-8'))
        else:
            p = subprocess.run([os.path.join(SELFDIR, 'claim-extract.sh'), *argv], capture_output=True, **_DEC)
            if p.returncode != 0:
                print(p.stderr, file=sys.stderr, end=''); sys.exit(p.returncode)
            data = json.loads(p.stdout)
    except (OSError, ValueError) as e:
        print(f'주장 목록을 읽지 못했다: {e}', file=sys.stderr); sys.exit(2)
    errors += (data.get('scanned') or {}).get('errors') or []
    a = _args(argv)
    rl = rule_lines(a, errors)
    targets, count_only = [], 0
    if rl:
        for c in data.get('claims') or []:
            kinds = set(c.get('kinds') or [])
            if not kinds & KINDS:
                if 'count' in kinds: count_only += 1
                continue
            masked, slots, ratios = mask(c)
            targets.append({
                'id': f'T{len(targets) + 1}', 'source': c.get('source'), 'file': c.get('file'), 'line': c.get('line'),
                'kinds': sorted(kinds & KINDS), 'text': c.get('text'), 'masked': masked,
                'slots': slots, 'ratios': ratios,
                # 원래 재현 명령 — 독립성 검사(같은 패턴인가)에만 쓴다. lane 프롬프트에는 싣지 않는다.
                'commands': [k.get('cmd') for s in c.get('sources') or [] for k in s.get('commands') or [] if k.get('cmd')],
            })
    # 등록 목록은 대상이 있을 때만 싣는다 — 분류 산출물에 쓰이지 않을 경로를 남기지 않는다
    reg = [{'name': n, 'path': p} for n, p in registry()] if targets else []
    print(_json_out({'ruleLines': rl, 'targets': targets, 'excludedCountOnly': count_only, 'registry': reg,
                     'errors': errors}, indent=2))

# ── 등록 레포 ────────────────────────────────────────────────────────────────
# 낡음 상한 T: 마지막 fetch(FETCH_HEAD mtime) 가 이보다 오래된 등록 레포는 쓰지 않는다. 근거는 DECISIONS.md 2026-11-12.
STALE_AFTER_SEC = 7 * 24 * 3600
P_ATTR = re.compile(r'(?<![\w-])export-(?:ignore|subst)\b')

def registry():
    """[(이름, 경로)] — 환경변수가 있으면 그쪽, 없으면 config.json 의 remeasureRepos({이름: 경로}). 없으면 빈 목록.
    --registry 로 받았으면 그것이다(분류 때 이 함수가 낸 목록)."""
    if os.environ.get('HAS_REG') == '1':
        try:
            got = json.loads(os.environ.get('REGISTRY') or '[]')
            return [(x['name'], x['path']) for x in got if isinstance(x, dict) and isinstance(x.get('name'), str) and isinstance(x.get('path'), str)]
        except (ValueError, TypeError, KeyError) as e:
            print(f'--registry 를 읽지 못했다: {e}', file=sys.stderr); return []
    env = os.environ.get('PF_REMEASURE_REPOS')
    if env is not None:                 # 빈 문자열 = 등록 없음 (키 부재와 구분한다)
        out = []
        for x in env.split(','):
            if '=' in x and x.split('=', 1)[0].strip():
                k, v = x.split('=', 1); out.append((k.strip(), v.strip()))
        return out
    try:
        raw = json.load(open(os.path.join(SELFDIR, 'config.json'), encoding='utf-8')).get('remeasureRepos')
    except FileNotFoundError:
        return []
    except Exception as e:
        print(f'config.json 파싱 실패: {e}', file=sys.stderr); return []
    if not isinstance(raw, dict):
        if raw is not None: print(f'remeasureRepos 는 {{이름: 경로}} 여야 한다 (받은 값: {type(raw).__name__})', file=sys.stderr)
        return []
    return [(k, v) for k, v in raw.items() if isinstance(k, str) and isinstance(v, str)]

def _g(repo, *a):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0')
    p = subprocess.run(['git', '-C', repo, *a], capture_output=True, env=env, **_DEC)
    return p.returncode, p.stdout

def resolve_one(name, path, now):
    """사용 가능하면 sha·ref·fetch 시각을, 아니면 사유를 낸다. 원 체크아웃 경로는 결과에 싣지 않는다 —
    이 결과가 lane 프롬프트로 가고, lane 은 스냅숏만 읽어야 한다."""
    r = {'name': name}
    p = os.path.expandvars(os.path.expanduser(path))   # 예시 설정처럼 $HOME 을 쓴 경로도 받는다
    if not p or not os.path.isdir(p):
        return {**r, 'status': 'unusable', 'reason': '경로가 없다'}
    rc, top = _g(p, 'rev-parse', '--show-toplevel')
    if rc != 0 or os.path.realpath(top.strip()) != os.path.realpath(p):
        return {**r, 'status': 'unusable', 'reason': 'git 레포 루트가 아니다'}
    # origin 기본 브랜치 — vault_source(classify.sh) 와 같은 순서: origin/HEAD, 없으면 origin/master
    rc, out = _g(p, 'symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
    ref = sha = ''
    for cand in ([out.strip()] if rc == 0 and out.strip() else []) + ['origin/master']:
        rc, s = _g(p, 'rev-parse', '--verify', '-q', f'{cand}^{{commit}}')
        if rc == 0 and s.strip():
            ref, sha = cand, s.strip(); break
    if not sha:
        return {**r, 'status': 'unusable', 'reason': 'origin 기본 브랜치(origin/HEAD·origin/master)를 찾지 못했다'}
    r.update({'ref': ref, 'sha': sha})
    # 낡음의 기준은 마지막 fetch 시각이다. 커밋 날짜는 레포가 조용하면 오래돼도 최신이고, reflog 는 끌 수 있다.
    rc, fh = _g(p, 'rev-parse', '--git-path', 'FETCH_HEAD')
    fh = fh.strip()
    fhp = fh if os.path.isabs(fh) else os.path.join(p, fh)
    if rc != 0 or not fh or not os.path.isfile(fhp):
        return {**r, 'status': 'unusable', 'reason': 'FETCH_HEAD 가 없다 — 마지막 fetch 시각을 모른다'}
    mt = os.path.getmtime(fhp)
    r['fetchedAt'] = time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(mt))
    if now - mt > STALE_AFTER_SEC:
        return {**r, 'status': 'unusable', 'reason': f'마지막 fetch 가 {int((now - mt) // 86400)}일 전이다 (상한 {STALE_AFTER_SEC // 86400}일)'}
    # export-ignore·export-subst 가 걸린 파일은 archive 에서 빠지거나 바뀐다 — 차이의 크기는 모르므로 표시만 한다
    marks = []
    rc, ls = _g(p, 'ls-tree', '-r', '-z', '--name-only', sha)
    for f in [x for x in ls.split('\0') if x and (x == '.gitattributes' or x.endswith('/.gitattributes'))]:
        rc, body = _g(p, 'show', f'{sha}:{f}')
        if rc == 0 and P_ATTR.search(body): marks.append(f)
    rc, ia = _g(p, 'rev-parse', '--git-path', 'info/attributes')
    ia = ia.strip(); iap = ia if os.path.isabs(ia) else os.path.join(p, ia)
    try:
        if ia and os.path.isfile(iap) and P_ATTR.search(open(iap, encoding='utf-8', errors='replace').read()):
            marks.append('info/attributes')
    except OSError:
        pass
    if marks:
        r['snapshotMayDiffer'] = f'스냅숏이 트리와 다를 수 있음 — export-ignore/export-subst ({", ".join(marks)})'
    return {**r, 'status': 'usable'}

def archive(name, path, sha):
    """`git archive <sha> | tar -x` 로 임시 폴더에 푼다. 실패하면 만든 폴더를 지우고 None."""
    p = os.path.expandvars(os.path.expanduser(path))
    tmp = os.environ.get('TMPDIR') or '/tmp'
    if os.environ.get('INTO'):
        # 워크플로가 이 출력을 못 받아도 상위 폴더 이름으로 지울 수 있게 그 아래에 만든다
        tmp = os.path.join(tmp, os.environ['INTO']); os.makedirs(tmp, exist_ok=True)
    d = tempfile.mkdtemp(prefix='pf-snap.', dir=tmp)
    try:
        env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0')
        ga = subprocess.Popen(['git', '-C', p, 'archive', '--format=tar', sha], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env)
        tx = subprocess.run(['tar', '-x', '-C', d], stdin=ga.stdout, capture_output=True)
        ga.stdout.close(); ga_err = ga.stderr.read(); ga.wait()
        if ga.returncode != 0 or tx.returncode != 0:
            raise RuntimeError((ga_err.decode('utf-8', 'replace') or tx.stderr.decode('utf-8', 'replace')).strip()[:160]
                               or f'rc={ga.returncode}/{tx.returncode}')
        return d, ''
    except Exception as e:
        shutil.rmtree(d, ignore_errors=True)
        return None, str(e)

def regs(snap):
    now = time.time()
    out, created = [], []
    for name, path in registry():
        r = resolve_one(name, path, now)
        if snap and r['status'] == 'usable':
            d, err = archive(name, path, r['sha'])
            if d:
                r['snapshot'] = d; created.append(d)
            else:
                # 원 체크아웃으로 대체하지 않는다 — 워킹트리는 커밋되지 않은 상태가 섞여 있다
                r = {k: v for k, v in r.items() if k not in ('snapshotMayDiffer',)}
                r.update({'status': 'unusable', 'reason': f'archive 풀기 실패 ({err})'})
        out.append(r)
    res = {'repos': out}
    if snap: res['created'] = created
    print(_json_out(res, indent=2))

if CMD == 'select':
    select(sys.argv[1:])
elif CMD == 'resolve':
    regs(False)
elif CMD == 'snapshot':
    regs(True)
ZZEND
