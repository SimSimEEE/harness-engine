#!/bin/bash
# flip eval — 같은 입력에 lane 판정이 실행마다 갈리는지 잰다.
#
# 왜 필요한가: lane 판정은 LLM 이 내린다. 같은 변경을 다시 돌렸을 때 FAIL 이 PASS 로 바뀌면
# 그 lane 은 그만큼 결함을 흘린다. 에이전트 정의를 고친 뒤 이 수치가 나아졌는지는 같은 입력을
# 같은 횟수로 다시 돌려 비교하는 것 말고는 알 방법이 없다.
#
# usage:
#   flip.sh prepare <out> [--lane-model=<lane>=<model>]... [--lane-effort=<lane>=<effort>]... [fixture...]
#       입력을 만들고 분류해 실행 인자를 남긴다 (<out> 은 비어 있어야 한다).
#       --lane-model·--lane-effort 는 그 lane 의 모델·effort 를 이 측정에서만 바꾼다(preflight.js 의
#       args.laneModel·laneEffort). 그 lane 을 재는 입력의 args.json 에만 들어간다. 이 override 가 실린
#       실행의 결과는 영수증에 쓸 수 없는 꼴(MEASUREMENT_ONLY)로 나온다 — 측정 전용이다.
#       모델끼리 비교하려면 override 마다 <out> 을 따로 만든다(예: haiku 한 번, sonnet 한 번).
#   flip.sh score <out> [--min-agree=R] [--json] <fixture>=<result> ... | @<runs-file>
#       result 는 워크플로 결과 JSON 이거나 그것이 든 작업 출력 파일이다.
#       runs-file 은 줄마다 "<fixture> <result>" 다.
#   flip.sh remeasure-prepare <out> [fixture...]
#       사실 주장 재측정(③) 입력을 만든다 — eval/claims/remeasure-*.sh. lane 은 전부 빼고 ③ 만 돌게 좁힌다.
#   flip.sh remeasure-score <out> [--min-agree=R] [--json] <fixture>=<result> ... | @<runs-file>
#       결과의 claimRemeasure 를 픽스처 기대(mismatch · no-mismatch · unmeasurable)와 대조해 일치율을 낸다.
#
# 실행은 이 스크립트가 하지 않는다 — lane 은 워크플로로만 돈다. prepare 가 남긴
# <out>/<fixture>/args.json 을 그대로 preflight.js 의 args 로 넘겨 k 번 돌리고, 결과 파일을 score 에 준다.
# 영수증은 남기지 마라 — 측정이지 게이트 통과가 아니다.
#
# 판정: 기대 판정과 일치한 비율이 --min-agree(기본 1.0) 미만인 lane 이 하나라도 있으면 exit 1.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PF="$(dirname "$SELF")"
cmd="${1:-}"; shift || true
case "$cmd" in
  prepare|score|remeasure-prepare|remeasure-score) ;;
  *) echo "usage: flip.sh prepare|remeasure-prepare <out> [fixture...] | score|remeasure-score <out> [--min-agree=R] [--json] <fixture>=<result>... | @<runs-file>" >&2; exit 2 ;;
esac
out="${1:-}"; [ -n "$out" ] || { echo "<out> 이 필요하다" >&2; exit 2; }
shift

if [ "$cmd" = prepare ]; then
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
        echo "<out> 이 비어 있지 않다: $out — 다른 측정의 결과와 섞이지 않게 새 디렉터리를 써라" >&2; exit 2
    fi
    ovr=(); names=()
    for a in "$@"; do
        case "$a" in
            --lane-model=*=*|--lane-effort=*=*) ovr+=("$a") ;;
            --*) echo "알 수 없는 옵션: $a" >&2; exit 2 ;;
            *) names+=("$a") ;;
        esac
    done
    mkdir -p "$out/_logs"; out="$(cd "$out" && pwd -P)"
    if [ ${#names[@]} -eq 0 ]; then
        for f in "$SELF"/fixtures/[!_]*.sh; do names+=("$(basename "$f" .sh)"); done
    fi
    printf '%s\n' ${ovr[@]+"${ovr[@]}"} > "$out/_logs/overrides.txt"
    for n in "${names[@]}"; do
        fx="$SELF/fixtures/$n.sh"
        [ -f "$fx" ] || { echo "없는 입력: $n" >&2; exit 2; }
        bash "$fx" "$out/$n" >/dev/null 2>"$out/_logs/$n.build.err" || { echo "입력 생성 실패: $n ($out/_logs/$n.build.err)" >&2; exit 1; }
        # 입력이 자기 카테고리를 들고 오면(<입력>/overlay) 그것만 오버레이로 쓴다 — 이 머신의 오버레이를
        # 섞지 않아야 입력이 고르는 lane 이 머신마다 같다. 없으면 종전대로 설치본 설정을 따른다.
        if [ -d "$out/$n/overlay" ]; then _ov=(env PF_OVERLAY_DIR="$out/$n/overlay"); else _ov=(env); fi
        # 관측 로그를 실 로그와 섞지 않는다 — 측정 라운드가 라운드 집계에 들어가면 그 숫자를 못 믿는다.
        "${_ov[@]}" PF_LOG="$out/pf.jsonl" VAULT_EXEMPT="$n/origin" "$PF/classify.sh" "$out/$n/r" pr \
            --body-file="$out/$n/body.md" > "$out/$n/classify.json" 2>"$out/_logs/$n.classify.err" \
            || { echo "분류 실패: $n ($out/_logs/$n.classify.err)" >&2; exit 1; }
    done
fi

# ── 재측정(③) 측정 — 기대는 lane 판정이 아니라 ③ 의 결과 상태다. 판정 흔들림 측정과 섞지 않는다.
if [ "$cmd" = remeasure-prepare ]; then
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
        echo "<out> 이 비어 있지 않다: $out — 다른 측정의 결과와 섞이지 않게 새 디렉터리를 써라" >&2; exit 2
    fi
    mkdir -p "$out/_logs"; out="$(cd "$out" && pwd -P)"
    if [ $# -gt 0 ]; then names=("$@")
    else names=(); for f in "$SELF"/claims/remeasure-*.sh; do names+=("$(basename "$f" .sh)"); done
    fi
    for n in "${names[@]}"; do
        fx="$SELF/claims/$n.sh"
        [ -f "$fx" ] || { echo "없는 입력: $n" >&2; exit 2; }
        bash "$fx" "$out/$n" >/dev/null 2>"$out/_logs/$n.build.err" || { echo "입력 생성 실패: $n ($out/_logs/$n.build.err)" >&2; exit 1; }
        # 등록 레포는 픽스처가 정한다 — 이 머신의 config.json 등록을 섞지 않는다(없으면 빈 등록)
        _reg=""; [ -f "$out/$n/registry" ] && _reg="$(cat "$out/$n/registry")"
        PF_LOG="$out/pf.jsonl" VAULT_EXEMPT="$n/origin" PF_REMEASURE_REPOS="$_reg" "$PF/classify.sh" "$out/$n/r" pr \
            > "$out/$n/classify.json" 2>"$out/_logs/$n.classify.err" \
            || { echo "분류 실패: $n ($out/_logs/$n.classify.err)" >&2; exit 1; }
    done
fi
if [ "$cmd" = remeasure-prepare ] || [ "$cmd" = remeasure-score ]; then
OUT="$out" PF="$PF" CMD="$cmd" python3 - "$@" <<'PY'
import hashlib, json, os, subprocess, sys, collections, time
OUT, PF, CMD = (os.environ[k] for k in ('OUT', 'PF', 'CMD'))
REPO = os.path.dirname(os.path.dirname(PF))
# lane 측정과 같다 — 워크플로가 해석하는 것은 설치본 정의다(PF_AGENTS_DIR 로 바꾼다)
AGENT = os.path.realpath(os.path.join(os.path.expanduser(os.environ.get('PF_AGENTS_DIR') or '~/.claude/agents'),
                                      'claim-remeasurer.md'))
def sha(p):
    try: return hashlib.sha1(open(p, 'rb').read()).hexdigest()
    except OSError: return None

if CMD == 'remeasure-prepare':
    fixtures = {}
    for n in sorted(d for d in os.listdir(OUT) if not d.startswith('_') and os.path.isdir(os.path.join(OUT, d))):
        base = os.path.join(OUT, n)
        cls = json.load(open(os.path.join(base, 'classify.json')))
        exp = json.load(open(os.path.join(base, 'expect.json')))['remeasure']
        rm = (cls.get('claimCheck') or {}).get('remeasure') or {}
        if not rm.get('targets'):
            sys.exit(f'{n}: 재측정 대상이 0건이다 — 입력이 ③ 을 재지 못한다 ({rm.get("status")})')
        # ③ 만 잰다. lane 은 비용만 들고 측정 대상이 아니다.
        cls['notSelected'] = {**cls.get('notSelected', {}), **{l: 'eval-narrowed — ③ 측정' for l in cls['selected']}}
        cls['selected'] = {}; cls['sequential'] = []
        args = {'repo': cls['repo'], 'mode': 'pr', 'round': 1, 'priorFindings': [], 'classification': cls}
        json.dump(args, open(os.path.join(base, 'args.json'), 'w'), ensure_ascii=False, indent=1)
        fixtures[n] = {'repo': cls['repo'], 'expect': exp, 'targets': len(rm['targets']), 'args': os.path.join(base, 'args.json')}
    head = subprocess.run(['git', '-C', REPO, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    man = {'created': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'harness': head, 'agent': sha(AGENT),
           'workflow': os.path.join(PF, 'preflight.js'), 'fixtures': fixtures}
    json.dump(man, open(os.path.join(OUT, 'manifest.json'), 'w'), ensure_ascii=False, indent=1)
    print(f'준비됨: {OUT}')
    for n, f in fixtures.items():
        print(f'  {n:<28} 기대 {f["expect"]:<13} 대상 {f["targets"]}  args: {f["args"]}')
    print(f'각 args.json 을 {man["workflow"]} 의 args 로 k(≥5) 번 돌리고 결과를 remeasure-score 에 넘겨라 (영수증은 남기지 마라). 실행마다 서로 다른 runId 를 args 에 더해라 — 없으면 꼬리가 args.json 에 담긴 분류의 runNonce 로 고정돼 겹친 실행이 스냅숏 폴더를 공유한다.')
    sys.exit(0)

try:
    man = json.load(open(os.path.join(OUT, 'manifest.json')))
except Exception as e:
    sys.exit(f'manifest.json 을 못 읽는다 — remeasure-prepare 를 먼저 돌려라 ({e})')
min_agree, as_json, specs = 1.0, False, []
for a in sys.argv[1:]:
    if a.startswith('--min-agree='): min_agree = float(a.split('=', 1)[1])
    elif a == '--json': as_json = True
    elif a.startswith('@'):
        for line in open(a[1:]):
            if not line.strip(): continue
            parts = line.strip().split(None, 1)
            if len(parts) != 2: sys.exit(f'runs-file 형식 오류 ("<입력> <결과 파일>"): {line!r}')
            specs.append(tuple(parts))
    elif '=' in a: specs.append(tuple(a.split('=', 1)))
    else: sys.exit(f'알 수 없는 인자: {a}')
if not specs: sys.exit('결과가 없다 — <fixture>=<result> 또는 @<runs-file> 을 넘겨라')

def load_result(p):
    t = open(p).read()
    try:
        d = json.loads(t)
    except ValueError:
        i = t.find('"result"')
        if i < 0: raise ValueError('워크플로 결과를 찾지 못했다')
        d, _ = json.JSONDecoder().raw_decode(t[t.index('{', i):])
    if 'result' in d and 'lanes' not in d: d = d['result']
    if 'claimRemeasure' not in d: raise ValueError('claimRemeasure 가 없다 — ③ 이 실린 워크플로 결과가 아니다')
    return d

# 실행 하나의 결과: failed(③ 이 결과를 못 냄) 또는 대상별 state 목록
def outcome(d):
    rm = d.get('claimRemeasure') or {}
    if not rm or rm.get('failed'): return 'failed', []
    return 'ran', [r.get('state') for r in rm.get('results') or []]
def agrees(want, kind, st):
    if kind == 'failed': return False
    if want == 'mismatch': return 'mismatch' in st
    if want == 'no-mismatch': return bool(st) and 'mismatch' not in st
    if want == 'unmeasurable': return bool(st) and all(s == 'unmeasurable' for s in st)
    return False

runs = collections.defaultdict(list)
for n, p in specs:
    fx = man['fixtures'].get(n)
    if not fx: sys.exit(f'manifest 에 없는 입력: {n}')
    try: d = load_result(p)
    except Exception as e: sys.exit(f'{n}: 결과를 못 읽는다 {p} ({e})')
    if d.get('repo') != fx['repo']: sys.exit(f'{n}: 결과의 대상 레포가 다르다 ({d.get("repo")} ≠ {fx["repo"]}) — {p}')
    runs[n].append(d)
rows, failed = [], []
for n, fx in man['fixtures'].items():
    rs = runs.get(n, [])
    oc = [outcome(r) for r in rs]
    ag = [agrees(fx['expect'], k, st) for k, st in oc]
    row = {'fixture': n, 'expect': fx['expect'], 'k': len(rs), 'agree': sum(ag),
           'agreeRate': round(sum(ag) / len(rs), 3) if rs else None,
           'failedRuns': sum(k == 'failed' for k, _ in oc),
           # 불일치를 기대했는데 못 낸 실행 수 — 사건 형태를 놓친 횟수다
           'missedMismatch': sum(1 for (k, st) in oc if fx['expect'] == 'mismatch' and 'mismatch' not in st),
           'states': dict(collections.Counter(s for _, st in oc for s in st))}
    rows.append(row)
    if not rs or row['agreeRate'] < min_agree: failed.append(n)
res = {'harness': man['harness'], 'agent': man['agent'], 'agentChangedSincePrepare': sha(AGENT) != man['agent'],
       'minAgree': min_agree, 'rows': rows, 'failed': failed, 'verdict': 'FAIL' if failed else 'PASS'}
if as_json:
    print(json.dumps(res, ensure_ascii=False, indent=1))
else:
    for r in rows:
        print(f'  {r["fixture"]:<28} 기대 {r["expect"]:<13} k={r["k"]} 일치 {r["agree"]}/{r["k"]}'
              f' · 실패 {r["failedRuns"]} · 기대 불일치 미보고 {r["missedMismatch"]} · {json.dumps(r["states"])}')
    if res['agentChangedSincePrepare']: print('⚠ prepare 이후 claim-remeasurer 정의가 바뀌었다')
    print(f'판정 {res["verdict"]} (일치율 기준 {min_agree:g})' + (f' — 미달: {", ".join(failed)}' if failed else ''))
sys.exit(1 if failed else 0)
PY
exit $?
fi

OUT="$out" SELF="$SELF" PF="$PF" CMD="$cmd" FLIP_FILE="$SELF/$(basename "${BASH_SOURCE[0]}")" python3 - "$@" <<'PY'
import hashlib, json, os, subprocess, sys, collections, time
OUT, SELF, PF, CMD = (os.environ[k] for k in ('OUT', 'SELF', 'PF', 'CMD'))
REPO = os.path.dirname(os.path.dirname(PF))

def sha(p):
    try: return hashlib.sha1(open(p, 'rb').read()).hexdigest()
    except OSError: return None

# 워크플로는 agentType 을 세션의 에이전트 등록에서 해석한다 — 설치본(~/.claude/agents)이다. 이 레포의
# agents/ 가 아니다. 오버레이가 같은 이름의 정의를 덮으면 측정되는 것은 오버레이 정의다. 그래서 다이제스트는
# 설치본에서 뜨고, 그 실경로와 레포 정의와의 일치 여부를 함께 남긴다. PF_AGENTS_DIR 로 자리를 바꾼다.
AGENTS_DIR = os.path.expanduser(os.environ.get('PF_AGENTS_DIR') or '~/.claude/agents')
def agent_source(l):
    p = os.path.join(AGENTS_DIR, f'{l}.md')
    return os.path.realpath(p) if os.path.exists(p) else None
def agent_digests(lanes):
    return {l: sha(agent_source(l)) if agent_source(l) else None for l in sorted(lanes)}
# 대조할 레포 정의는 **이 스크립트 파일이 실제로 놓인 체크아웃**의 agents/ 다. REPO(스크립트 디렉터리 기준)는
# 파일 단위 링크 설치·복사 설치에서 설치 루트 자체가 되어, 설치본을 설치본과 비교하는 빈 대조가 된다.
# 체크아웃이 설치 루트와 같으면(복사 설치) 독립적으로 대조할 수 없다 — sameAsRepo 를 None 으로 남긴다.
# PF_ENGINE_REPO 로 체크아웃을 직접 준다.
def engine_checkout():
    e = os.environ.get('PF_ENGINE_REPO')
    if e: return os.path.realpath(os.path.expanduser(e))
    f = os.path.realpath(os.environ.get('FLIP_FILE') or '')
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(f))))   # <root>/skills/preflight/eval/flip.sh
    if os.path.realpath(root) in (os.path.realpath(os.path.dirname(AGENTS_DIR)), os.path.realpath(os.path.expanduser('~/.claude'))): return None
    return root if os.path.isdir(os.path.join(root, 'agents')) else None
ENGINE = engine_checkout()
def agent_provenance(lanes):
    out = {}
    for l in sorted(lanes):
        src = agent_source(l)
        same = None if not (src and ENGINE) else sha(src) == sha(os.path.join(ENGINE, 'agents', f'{l}.md'))
        out[l] = {'source': src, 'engineRepo': ENGINE, 'sameAsRepo': same}
    return out
def warn_provenance(prov):
    for l, v in prov.items():
        if not v['source']:
            print(f'⚠ {l}: 설치본에 정의가 없다({AGENTS_DIR}) — 워크플로가 이 lane 을 해석하지 못하거나 다른 곳의 정의를 쓴다')
        elif v['sameAsRepo'] is None:
            print(f'⚠ {l}: 측정되는 정의 {v["source"]} 를 레포 정의와 대조하지 못했다(설치 형태상 체크아웃을 못 찾음) — PF_ENGINE_REPO 로 체크아웃을 줘라')
        elif not v['sameAsRepo']:
            print(f'⚠ {l}: 측정되는 정의는 설치본 {v["source"]} 이다 — 이 레포의 agents/{l}.md 와 내용이 다르다')

MODELS = ('haiku', 'sonnet', 'opus')
EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')

if CMD == 'prepare':
    fixtures, lanes_all, docs = {}, set(), set()
    # 측정 전용 override — {lane: 값}. 값 검사는 preflight.js 도 하지만, 잘못된 값으로 k 번 돌린 뒤에
    # 알면 비용이 이미 들었다. 여기서 먼저 막는다.
    ovr = {'laneModel': {}, 'laneEffort': {}}
    for a in open(os.path.join(OUT, '_logs', 'overrides.txt')).read().split():
        key, rest = a[2:].split('=', 1)
        lane, val = rest.split('=', 1)
        field, allowed = ({'lane-model': ('laneModel', MODELS), 'lane-effort': ('laneEffort', EFFORTS)})[key]
        if val not in allowed: sys.exit(f'{a}: 허용 값은 {", ".join(allowed)}')
        if lane in ovr[field]: sys.exit(f'{a}: {lane} 의 {key} 를 두 번 줬다')
        ovr[field][lane] = val
    for n in sorted(d for d in os.listdir(OUT) if not d.startswith('_') and os.path.isdir(os.path.join(OUT, d))):
        base = os.path.join(OUT, n)
        cls = json.load(open(os.path.join(base, 'classify.json')))
        exp = json.load(open(os.path.join(base, 'expect.json')))['lanes']
        # NOT_APPLICABLE 은 등록 조회를 하지 않는 카테고리다 — vault 에 닿지 않는다.
        if (cls.get('vaultLink') or {}).get('status') not in ('EXEMPT', 'NOT_APPLICABLE'):
            sys.exit(f'{n}: vault 연결이 EXEMPT 가 아니다 — 입력이 실제 vault 에 닿는다 ({cls.get("vaultLink")})')
        miss = [l for l in exp if l not in cls['selected']]
        if miss:
            sys.exit(f'{n}: 기대 판정을 둔 lane 을 분류기가 고르지 않았다: {miss} — 입력이 그 lane 을 재지 못한다')
        # 잴 lane 만 남긴다. 나머지는 비용만 들고 측정 대상이 아니다.
        cut = {l: 'eval-narrowed — 이 입력의 측정 대상 아님' for l in cls['selected'] if l not in exp}
        cls['selected'] = {l: v for l, v in cls['selected'].items() if l in exp}
        cls['notSelected'] = {**cls.get('notSelected', {}), **cut}
        doc = (cls.get('laneMeta', {}).get('code-reviewer') or {}).get('conventionDoc')
        if doc: docs.add(doc)
        args = {'repo': cls['repo'], 'mode': 'pr', 'round': 1, 'priorFindings': [],
                'prBodyFile': os.path.join(base, 'body.md'), 'classification': cls}
        # override 는 이 입력이 재는 lane 에만 싣는다 — 실리지 않은 lane 이름은 워크플로가 거부한다.
        mine = {f: {l: v for l, v in m.items() if l in exp} for f, m in ovr.items()}
        mine = {f: m for f, m in mine.items() if m}
        args.update(mine)
        json.dump(args, open(os.path.join(base, 'args.json'), 'w'), ensure_ascii=False, indent=1)
        fixtures[n] = {'repo': cls['repo'], 'expect': exp, 'args': os.path.join(base, 'args.json'),
                       'overrides': mine or None}
        lanes_all |= set(exp)
    unused = sorted({l for m in ovr.values() for l in m} - lanes_all)
    if unused:
        sys.exit(f'override 한 lane 을 재는 입력이 없다: {unused} — 입력을 고르거나 override 를 빼라')
    head = subprocess.run(['git', '-C', REPO, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(['git', '-C', REPO, 'status', '--porcelain', '--', 'agents', 'skills/preflight'],
                                capture_output=True, text=True).stdout.strip())
    man = {'created': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'harness': head, 'harnessDirty': dirty,
           'agents': agent_digests(lanes_all), 'agentSources': agent_provenance(lanes_all),
           'conventionDocs': {d: sha(d) for d in sorted(docs)},
           'workflow': os.path.join(PF, 'preflight.js'), 'overrides': {f: m for f, m in ovr.items() if m} or None,
           'fixtures': fixtures}
    json.dump(man, open(os.path.join(OUT, 'manifest.json'), 'w'), ensure_ascii=False, indent=1)
    print(f'준비됨: {OUT}' + (f'  (측정 전용 override {json.dumps(man["overrides"])})' if man['overrides'] else ''))
    for n, f in fixtures.items():
        print(f'  {n:<22} 기대 {json.dumps(f["expect"])}  args: {f["args"]}')
    warn_provenance(man['agentSources'])
    print(f'각 args.json 을 {man["workflow"]} 의 args 로 k 번 돌리고 결과를 score 에 넘겨라 (영수증은 남기지 마라). 실행마다 서로 다른 runId 를 args 에 더해라.')
    sys.exit(0)

# ── score ───────────────────────────────────────────────────────────────────
try:
    man = json.load(open(os.path.join(OUT, 'manifest.json')))
except Exception as e:
    sys.exit(f'manifest.json 을 못 읽는다 — prepare 를 먼저 돌려라 ({e})')
min_agree, as_json, specs = 1.0, False, []
for a in sys.argv[1:]:
    if a.startswith('--min-agree='):
        min_agree = float(a.split('=', 1)[1])
    elif a == '--json':
        as_json = True
    elif a.startswith('@'):
        for line in open(a[1:]):
            if not line.strip(): continue
            # 경로에 공백이 들어갈 수 있다 — 첫 공백에서만 나눈다.
            parts = line.strip().split(None, 1)
            if len(parts) != 2: sys.exit(f'runs-file 형식 오류 ("<입력> <결과 파일>"): {line!r}')
            specs.append(tuple(parts))
    elif '=' in a:
        specs.append(tuple(a.split('=', 1)))
    else:
        sys.exit(f'알 수 없는 인자: {a}')
if not specs:
    sys.exit('결과가 없다 — <fixture>=<result> 또는 @<runs-file> 을 넘겨라')

def load_result(p):
    t = open(p).read()
    try:
        d = json.loads(t)
    except ValueError:
        # 작업 출력 파일: 워크플로 결과는 "result" 키 뒤의 객체다.
        i = t.find('"result"')
        if i < 0: raise ValueError('워크플로 결과를 찾지 못했다')
        d, _ = json.JSONDecoder().raw_decode(t[t.index('{', i):])
    if 'result' in d and 'lanes' not in d: d = d['result']
    if not isinstance(d.get('lanes'), dict): raise ValueError('lanes 가 없다 — 워크플로 결과가 아니다')
    return d

runs = collections.defaultdict(list)
for n, p in specs:
    fx = man['fixtures'].get(n)
    if not fx: sys.exit(f'manifest 에 없는 입력: {n}')
    try:
        d = load_result(p)
    except Exception as e:
        sys.exit(f'{n}: 결과를 못 읽는다 {p} ({e})')
    # 다른 입력의 결과를 이 입력으로 세면 수치가 통째로 틀린다 — 대상 레포로 묶는다.
    if d.get('repo') != fx['repo']:
        sys.exit(f'{n}: 결과의 대상 레포가 다르다 ({d.get("repo")} ≠ {fx["repo"]}) — {p}')
    # 다른 모델로 돈 결과를 이 측정으로 세면 비교가 통째로 틀린다 — override 를 manifest 와 대조한다.
    want = fx.get('overrides') or {}
    m = d.get('measurement') or {}
    got = {f: m.get(f) for f in ('laneModel', 'laneEffort') if m.get(f)}
    if got != want:
        sys.exit(f'{n}: 결과의 override {json.dumps(got)} 가 prepare 의 것 {json.dumps(want)} 과 다르다 — {p}')
    runs[n].append(d)

rows, failed = [], []
for n, fx in man['fixtures'].items():
    rs = runs.get(n, [])
    for lane, want in fx['expect'].items():
        # 측정 전용 실행은 status 가 MEASUREMENT_ONLY 이고 실제 판정은 measuredStatus 에 있다
        st = [((lambda v: v.get('measuredStatus') or v.get('status'))(r['lanes'].get(lane) or {}) or 'MISSING') for r in rs]
        agree = sum(s == want for s in st)
        # 같은 결함이면 id 도 같아야 재발을 셀 수 있다 — 막은 실행들 사이의 최빈 id 집합 점유율
        bid = [tuple(sorted(f['id'] for f in r.get('blocking', []) if f.get('lane') == lane))
               for r, s in zip(rs, st) if s == 'FAIL']
        top = collections.Counter(bid).most_common(1)
        notes = [sorted(f['id'] for f in r.get('notes', []) if f.get('lane') == lane) for r in rs]
        row = {'fixture': n, 'lane': lane, 'expect': want, 'k': len(rs),
               'statuses': dict(collections.Counter(st)), 'agree': agree,
               'agreeRate': round(agree / len(rs), 3) if rs else None,
               'blockingIds': {','.join(k) or '(없음)': v for k, v in collections.Counter(bid).items()},
               'idStable': round(top[0][1] / len(bid), 3) if bid else None,
               'runsWithNotes': sum(bool(x) for x in notes),
               'distinctNotes': len({i for x in notes for i in x})}
        rows.append(row)
        if not rs or row['agreeRate'] < min_agree: failed.append(f'{n}/{lane}')

# 드리프트는 prepare 가 기록한 경로를 다시 해시해 본다 — score 쪽 환경(PF_AGENTS_DIR)이 달라도 같은 파일을 대조한다
now = {l: (lambda s: sha(s) if s else None)(((man.get('agentSources') or {}).get(l) or {}).get('source')) if man.get('agentSources') else agent_digests({l})[l] for l in {r['lane'] for r in rows}}
drift = {l: (man['agents'].get(l), d) for l, d in now.items() if man['agents'].get(l) != d}
res = {'harness': man['harness'], 'harnessDirty': man['harnessDirty'], 'agents': man['agents'],
       'agentSources': man.get('agentSources'), 'overrides': man.get('overrides'),
       'agentsChangedSincePrepare': sorted(drift), 'minAgree': min_agree, 'rows': rows,
       'failed': failed, 'verdict': 'FAIL' if failed else 'PASS'}
if as_json:
    print(json.dumps(res, ensure_ascii=False, indent=1))
else:
    print(f'harness {man["harness"][:7]}{" (작업 중 변경 있음)" if man["harnessDirty"] else ""}'
          f' · agents ' + ' '.join(f'{l}={(d or "-")[:7]}' for l, d in man['agents'].items())
          + (f' · override {json.dumps(man["overrides"])}' if man.get('overrides') else ''))
    for r in rows:
        print(f'  {r["fixture"]:<22} {r["lane"]:<14} 기대 {r["expect"]:<4} k={r["k"]} '
              f'{json.dumps(r["statuses"])} 일치 {r["agree"]}/{r["k"]}'
              + (f' · id 고정 {r["idStable"]:.0%} {json.dumps(r["blockingIds"], ensure_ascii=False)}' if r['idStable'] is not None else '')
              + (f' · 참고 {r["runsWithNotes"]}회/{r["distinctNotes"]}종' if r['runsWithNotes'] else ''))
    if drift:
        print(f'⚠ prepare 이후 에이전트 정의가 바뀌었다: {sorted(drift)} — 어느 정의를 잰 것인지 섞였을 수 있다')
    if man.get('agentSources'):
        warn_provenance(man['agentSources'])
    print(f'판정 {res["verdict"]} (일치율 기준 {min_agree:g})' + (f' — 미달: {", ".join(failed)}' if failed else ''))
sys.exit(1 if failed else 0)
PY
