#!/bin/bash
# flip eval — 같은 입력에 lane 판정이 실행마다 갈리는지 잰다.
#
# 왜 필요한가: lane 판정은 LLM 이 내린다. 같은 변경을 다시 돌렸을 때 FAIL 이 PASS 로 바뀌면
# 그 lane 은 그만큼 결함을 흘린다. 에이전트 정의를 고친 뒤 이 수치가 나아졌는지는 같은 입력을
# 같은 횟수로 다시 돌려 비교하는 것 말고는 알 방법이 없다.
#
# usage:
#   flip.sh prepare <out> [fixture...]     입력을 만들고 분류해 실행 인자를 남긴다 (<out> 은 비어 있어야 한다)
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
    mkdir -p "$out/_logs"; out="$(cd "$out" && pwd -P)"
    if [ $# -gt 0 ]; then names=("$@")
    else names=(); for f in "$SELF"/fixtures/[!_]*.sh; do names+=("$(basename "$f" .sh)"); done
    fi
    for n in "${names[@]}"; do
        fx="$SELF/fixtures/$n.sh"
        [ -f "$fx" ] || { echo "없는 입력: $n" >&2; exit 2; }
        bash "$fx" "$out/$n" >/dev/null 2>"$out/_logs/$n.build.err" || { echo "입력 생성 실패: $n ($out/_logs/$n.build.err)" >&2; exit 1; }
        # 관측 로그를 실 로그와 섞지 않는다 — 측정 라운드가 라운드 집계에 들어가면 그 숫자를 못 믿는다.
        PF_LOG="$out/pf.jsonl" VAULT_EXEMPT="$n/origin" "$PF/classify.sh" "$out/$n/r" pr \
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
AGENT = os.path.join(REPO, 'agents', 'claim-remeasurer.md')
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

OUT="$out" SELF="$SELF" PF="$PF" CMD="$cmd" python3 - "$@" <<'PY'
import hashlib, json, os, subprocess, sys, collections, time
OUT, SELF, PF, CMD = (os.environ[k] for k in ('OUT', 'SELF', 'PF', 'CMD'))
REPO = os.path.dirname(os.path.dirname(PF))

def sha(p):
    try: return hashlib.sha1(open(p, 'rb').read()).hexdigest()
    except OSError: return None

def agent_digests(lanes):
    return {l: sha(os.path.join(REPO, 'agents', f'{l}.md')) for l in sorted(lanes)}

if CMD == 'prepare':
    fixtures, lanes_all, docs = {}, set(), set()
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
        json.dump(args, open(os.path.join(base, 'args.json'), 'w'), ensure_ascii=False, indent=1)
        fixtures[n] = {'repo': cls['repo'], 'expect': exp, 'args': os.path.join(base, 'args.json')}
        lanes_all |= set(exp)
    head = subprocess.run(['git', '-C', REPO, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(['git', '-C', REPO, 'status', '--porcelain', '--', 'agents', 'skills/preflight'],
                                capture_output=True, text=True).stdout.strip())
    man = {'created': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'harness': head, 'harnessDirty': dirty,
           'agents': agent_digests(lanes_all), 'conventionDocs': {d: sha(d) for d in sorted(docs)},
           'workflow': os.path.join(PF, 'preflight.js'), 'fixtures': fixtures}
    json.dump(man, open(os.path.join(OUT, 'manifest.json'), 'w'), ensure_ascii=False, indent=1)
    print(f'준비됨: {OUT}')
    for n, f in fixtures.items():
        print(f'  {n:<22} 기대 {json.dumps(f["expect"])}  args: {f["args"]}')
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
    runs[n].append(d)

rows, failed = [], []
for n, fx in man['fixtures'].items():
    rs = runs.get(n, [])
    for lane, want in fx['expect'].items():
        st = [((r['lanes'].get(lane) or {}).get('status') or 'MISSING') for r in rs]
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

now = agent_digests({r['lane'] for r in rows})
drift = {l: (man['agents'].get(l), d) for l, d in now.items() if man['agents'].get(l) != d}
res = {'harness': man['harness'], 'harnessDirty': man['harnessDirty'], 'agents': man['agents'],
       'agentsChangedSincePrepare': sorted(drift), 'minAgree': min_agree, 'rows': rows,
       'failed': failed, 'verdict': 'FAIL' if failed else 'PASS'}
if as_json:
    print(json.dumps(res, ensure_ascii=False, indent=1))
else:
    print(f'harness {man["harness"][:7]}{" (작업 중 변경 있음)" if man["harnessDirty"] else ""}'
          f' · agents ' + ' '.join(f'{l}={(d or "-")[:7]}' for l, d in man['agents'].items()))
    for r in rows:
        print(f'  {r["fixture"]:<22} {r["lane"]:<14} 기대 {r["expect"]:<4} k={r["k"]} '
              f'{json.dumps(r["statuses"])} 일치 {r["agree"]}/{r["k"]}'
              + (f' · id 고정 {r["idStable"]:.0%} {json.dumps(r["blockingIds"], ensure_ascii=False)}' if r['idStable'] is not None else '')
              + (f' · 참고 {r["runsWithNotes"]}회/{r["distinctNotes"]}종' if r['runsWithNotes'] else ''))
    if drift:
        print(f'⚠ prepare 이후 에이전트 정의가 바뀌었다: {sorted(drift)} — 어느 정의를 잰 것인지 섞였을 수 있다')
    print(f'판정 {res["verdict"]} (일치율 기준 {min_agree:g})' + (f' — 미달: {", ".join(failed)}' if failed else ''))
sys.exit(1 if failed else 0)
PY
