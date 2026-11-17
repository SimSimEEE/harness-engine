#!/bin/bash
# 프로필 생성기의 결정론 부분 — 현황 점검·이력 실측·후보 표·승인 항목 조립 (#47 「생성기 스킬 흐름」).
#
# 이 스크립트가 고르고 센다. LLM(스킬)은 표를 사용자에게 보이고 사용자가 고른 id 를 넘기는 한 칸만 한다.
# 판정·적재는 하지 않는다 — 카테고리는 category.sh(= classify.sh) 가, 프로필 형식 검사는 적재기(classify.sh
# _load_profiles)가, 쓰기는 profile.sh init 이 한다. 여기서 같은 판정을 다시 하면 둘이 갈라진다.
#
# usage:
#   profile-measure.sh status  <repo>
#       현황 점검. stdout JSON {repo, origin, category, evidence, profile, engineVersion, stack, next, reason}
#       next 는 "measure"(다음 단계로) 또는 "stop"(이유는 reason). 멈춤도 정상 출력이다 — exit 0.
#   profile-measure.sh measure <repo> [--commits N] [--window K]
#       대상 레포의 최근 비머지 커밋 N 개(기본 200)를 **실제 분류기(classify.sh commit 모드)** 로 다시 분류해
#       force-lane 후보마다 4축 수치를 낸다. stdout JSON {repo, head, scanned, command, candidates:[…], unclassified:[…]}
#       대상 레포는 건드리지 않는다 — 공유 클론(--shared --no-checkout)을 임시 디렉터리에 만들어 그 안에서 돌린다.
#   profile-measure.sh table   <measure.json> [<adjustments.json>]
#       4축 표(markdown). adjustments 를 주면 승인 열을 붙인다 — DECISIONS.md 에 그대로 붙이는 기록이다.
#   profile-measure.sh select  <measure.json> <id>...
#       사용자가 승인한 id 의 조정 항목 목록(JSON)을 낸다. approved 는 오늘(date +%F). profile.sh init --adjustments 의 입력이다.
#
# exit: 0 정상 · 2 인자 오류 · 3 실측 불가(분류기 실패·커밋 없음·모르는 id)
set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELFDIR/lib.sh"

usage(){ sed -n '/^# usage:/,/^# exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die(){ printf '%s\n' "$1" >&2; exit 3; }

sub="${1:-}"; [ $# -ge 2 ] || usage; shift

case "$sub" in
status)
    [ $# -eq 1 ] || usage
    repo=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $1" >&2; exit 2; }
    err=$(mktemp "${TMPDIR:-/tmp}/pfmeas.XXXXXX") || exit 2
    trap 'rm -f -- "$err"' EXIT
    out=$(bash "$SELFDIR/category.sh" "$repo" 2>"$err"); rc=$?
    REPO="$repo" OUT="$out" RC="$rc" ERR1="$(head -1 "$err")" ENGINE="$(pf_engine_version)" python3 - <<'PY'
import collections, json, os, posixpath, subprocess, sys
repo, rc = os.environ['REPO'], int(os.environ['RC'])
def git(*a):
    p = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, errors='surrogateescape')
    return p.stdout if p.returncode == 0 else ''
# 스택 실측: 추적 파일 확장자 상위 10개와 비머지 커밋 수. 카테고리를 고르는 데 쓰지 않는다 — 사람이 보는 근거다.
files = [f for f in git('ls-files', '-z').split('\0') if f]
ext = collections.Counter((posixpath.splitext(f)[1] or '(없음)') for f in files)
commits = git('rev-list', '--count', '--no-merges', 'HEAD').strip()
res = {'repo': repo, 'origin': None, 'category': None, 'evidence': {}, 'profile': None,
       'engineVersion': os.environ['ENGINE'] or None,
       'stack': {'files': len(files), 'nonMergeCommits': int(commits) if commits.isdigit() else 0,
                 'topExtensions': ext.most_common(10)}}
def stop(reason):
    res.update(next='stop', reason=reason)
    print(json.dumps(res, ensure_ascii=False, indent=2)); sys.exit(0)
if rc != 0:
    stop(f'조회 실패(exit {rc}): {os.environ["ERR1"]} — 겹침이면 표식 하나를 정리하고, 적재 실패면 profiles·categories 를 먼저 고친다')
d = json.loads(os.environ['OUT'])
res.update(origin=d.get('origin'), category=d.get('category'), evidence=d.get('evidence') or {}, profile=d.get('profile'))
if not res['engineVersion']:
    stop('엔진 버전(ENGINE_VERSION)을 읽지 못했다 — 설치본을 먼저 고친다')
if res['profile']:
    stop(f'이미 프로필이 있다: {res["profile"]["path"]} (engineVersion {res["profile"]["engineVersion"]}) — 생성기는 새 프로필만 만든다')
if not res['origin']:
    stop('origin 리모트가 없어 프로필 키(<owner>/<repo>)를 정할 수 없다')
if not res['category']:
    stop('맞는 카테고리가 없다 — 어느 카테고리 표식에도 걸리지 않는다. 새 카테고리는 여기서 만들지 않는다'
         '(카테고리는 실제로 쓰는 레포가 생겼을 때 따로 만든다). stack 을 근거로 보고하고 멈춘다')
if not res['stack']['nonMergeCommits']:
    stop('비머지 커밋이 없어 이력 실측을 할 수 없다')
res.update(next='measure', reason=f'카테고리 {res["category"]} 추론, 프로필 없음 — 이력 실측으로 넘어간다')
print(json.dumps(res, ensure_ascii=False, indent=2))
PY
    ;;

measure)
    src="$1"; shift; n=200; k=5
    while [ $# -gt 0 ]; do
        case "$1" in
            --commits) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; n=$2; shift 2 ;;
            --window)  [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; k=$2; shift 2 ;;
            *) usage ;;
        esac
    done
    repo=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || { echo "git 레포가 아니다: $src" >&2; exit 2; }
    head=$(git -C "$repo" rev-parse --verify -q HEAD) || die "HEAD 커밋이 없다: $repo"
    W=$(mktemp -d "${TMPDIR:-/tmp}/pfmeas.XXXXXX") || exit 2
    trap 'rm -rf -- "$W"' EXIT
    # 공유 클론: 대상의 객체를 alternates 로 읽기만 한다 — 대상의 refs·인덱스·워킹트리·.git/worktrees 를 건드리지 않는다.
    # origin 을 지운다 — 클론의 origin 은 원본 경로인데 적재기는 그 끝 두 마디도 슬러그로 읽는다(…/owner/repo).
    # 프로필이 실측에 끼면 이미 강제된 lane 이 "선택" 으로 세진다.
    git clone -q --shared --no-checkout -- "$repo" "$W/r" 2>"$W/clone.err" || die "공유 클론 실패: $(head -1 "$W/clone.err")"
    git -C "$W/r" remote remove origin 2>/dev/null
    git -C "$W/r" rev-list --no-merges --reverse -n "$n" "$head" > "$W/list" || die "커밋 목록을 못 읽었다"
    : > "$W/rows"
    while IFS= read -r c; do
        git -C "$W/r" rev-parse -q --verify "$c^" >/dev/null || continue        # 루트 커밋은 부모가 없어 커밋 게이트로 재현할 수 없다
        # 워킹트리 = 부모, 인덱스 = 그 커밋 — 커밋 직전 게이트가 본 상태다(commit 모드는 HEAD 대 인덱스).
        if ! git -C "$W/r" checkout -q -f --detach "$c^" 2>/dev/null || ! git -C "$W/r" read-tree "$c" 2>/dev/null; then
            printf '%s\t-\t체크아웃 실패\n' "$c" >> "$W/rows"; continue
        fi
        # 관측 로그를 쓰지 않는다 — 실측 재생은 게이트 라운드가 아니다.
        if PF_LOG=/dev/null bash "$SELFDIR/classify.sh" "$W/r" commit > "$W/cls.json" 2>"$W/cls.err"; then
            printf '%s\t%s\t\n' "$c" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({"s":sorted(d["selected"]),"n":d["notSelected"],"cat":d["category"]},ensure_ascii=False))' "$W/cls.json")" >> "$W/rows"
        else
            printf '%s\t-\t분류 실패(exit %s): %s\n' "$c" "$?" "$(head -1 "$W/cls.err")" >> "$W/rows"
        fi
    done < "$W/list"
    REPO="$repo" HEADSHA="$head" N="$n" K="$k" ROWS="$W/rows" LIST="$W/list" CLONE="$W/r" ENGINE="$(pf_engine_version)" python3 - <<'PY' || exit 3
import json, os, re, statistics, subprocess, sys
repo, head, n, k = os.environ['REPO'], os.environ['HEADSHA'], int(os.environ['N']), int(os.environ['K'])
def git(*a):
    p = subprocess.run(['git', '-C', os.environ['CLONE'], *a], capture_output=True, text=True, errors='surrogateescape')
    return p.stdout if p.returncode == 0 else ''
rows, bad = [], []
for line in open(os.environ['ROWS'], encoding='utf-8', errors='surrogateescape'):
    c, j, why = line.rstrip('\n').split('\t', 2)
    if j == '-':
        bad.append({'commit': c, 'reason': why}); continue
    rows.append((c, json.loads(j)))
if not rows:
    print('분류된 커밋이 없다 — 실측할 수 없다' + (f' (첫 실패: {bad[0]["reason"]})' if bad else ''), file=sys.stderr)
    sys.exit(3)

# 수정 커밋 판정 — 제목만 본다. 이 정규식이 영향도 축의 정의다(출력에 함께 싣는다).
FIX_RE = r'^(fix|hotfix|revert)(\([^)]*\))?!?:|^Revert "'
fixre = re.compile(FIX_RE, re.I)
# 창·거리는 재생한 **전체** 비머지 커밋 목록으로 센다 — 분류에 실패한 커밋을 빼고 세면 창이 넓어지고 거리가 짧아진다.
order = [l.strip() for l in open(os.environ['LIST']) if l.strip()]
pos = {c: j for j, c in enumerate(order)}
files = {c: set(f for f in git('diff-tree', '--no-commit-id', '-r', '--name-only', '-z', c).split('\0') if f) for c in order}
subj = {c: git('log', '-1', '--format=%s', c).strip() for c in order}
def lines(c):
    t = 0
    for l in git('show', '--format=', '--numstat', c).splitlines():
        a, d, *_ = l.split('\t') + ['', '']
        t += (int(a) if a.isdigit() else 0) + (int(d) if d.isdigit() else 0)
    return t
def followup(i):
    """분류된 i 번째 커밋 뒤 K 커밋(전체 목록 기준) 안에서, 같은 파일을 건드린 첫 수정 커밋 (거리, sha) 또는 None."""
    s = pos[rows[i][0]]
    for j in range(s + 1, min(s + 1 + k, len(order))):
        c = order[j]
        if fixre.search(subj[c]) and files[c] & files[order[s]]:
            return j - s, c
    return None

# 각 lane 이 왜 강제할 수 없는 동작을 하는지 — 자동 수정 축. lane 정의(agents/<lane>.md)가 보고만 하므로 셋 다 없음이다.
AUTOFIX = {
    'code-reviewer': '없음 — 리뷰 lane 은 지적만 한다 (agents/code-reviewer.md)',
    'test-runner': '없음 — `--fix`·`npm run lint` 를 금지한다 (agents/test-runner.md)',
    'crossrepo-impact': '없음 — 영향 분석만 낸다 (agents/crossrepo-impact.md)',
}
cmd = f'bash skills/preflight/profile-measure.sh measure <repo> --commits {n} --window {k}'
cands = []
for lane in AUTOFIX:
    sk, ru = [], []
    for i, (c, d) in enumerate(rows):
        (sk if lane in d['n'] else ru if lane in d['s'] else []).append(i)
    if not sk:
        continue
    reasons = {}
    for i in sk:
        r = rows[i][1]['n'][lane]
        r = r.split(' — ')[0].split(' (')[0]
        reasons[r] = reasons.get(r, 0) + 1
    fk = [(i, f) for i in sk if (f := followup(i))]
    fr = [(i, f) for i in ru if (f := followup(i))]
    cost = [lines(f[1]) for _, f in fk]
    rate = lambda a, b: round(a / b, 3) if b else None
    ev = (f'{cmd} @ {head[:12]} (엔진 {os.environ["ENGINE"] or "?"}) — commit 게이트 미선택 {len(sk)}/{len(rows)}; '
          f'미선택 뒤 {k}커밋 안 수정 {len(fk)}/{len(sk)}, 선택 뒤 {len(fr)}/{len(ru)}')
    cands.append({
        'id': f'force-{lane}-commit', 'lane': lane, 'modes': ['commit'],
        'axes': {
            'violationRate': {'skipped': len(sk), 'total': len(rows), 'rate': rate(len(sk), len(rows)), 'reasons': reasons,
                              'means': '강제하면 이 비율만큼 커밋 게이트에 lane 이 더 돈다 — 강제 비용'},
            'impact': {'skippedFollowedByFix': len(fk), 'skippedRate': rate(len(fk), len(sk)),
                       'selected': len(ru), 'selectedFollowedByFix': len(fr), 'selectedRate': rate(len(fr), len(ru)),
                       'examples': [{'commit': rows[i][0][:12], 'fix': f[1][:12], 'distance': f[0]} for i, f in fk[:5]],
                       'means': f'미선택 커밋 뒤 {k}커밋 안에 같은 파일을 고친 수정 커밋이 온 비율 (선택된 커밋과 비교)'},
            'recoveryCost': {'fixLinesMedian': statistics.median(cost) if cost else None,
                             'fixDistanceMedian': statistics.median([f[0] for _, f in fk]) if fk else None,
                             'means': '그 수정 커밋의 변경 줄 수(numstat 추가+삭제)와 커밋 거리의 중앙값'},
            'autoFix': AUTOFIX[lane],
        },
        'adjustment': {'id': f'force-{lane}-commit', 'kind': 'force-lane', 'lane': lane, 'modes': ['commit'], 'evidence': ev},
    })
_m = re.search(r'[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$', subprocess.run(['git', '-C', repo, 'remote', 'get-url', 'origin'],
                 capture_output=True, text=True).stdout.strip())
print(json.dumps({'repo': repo, 'origin': f'{_m.group(1)}/{_m.group(2)}' if _m else None, 'head': head, 'engineVersion': os.environ['ENGINE'] or None,
                  'scanned': len(rows), 'requested': n, 'window': k, 'fixPattern': FIX_RE, 'command': cmd,
                  'categories': sorted({d['cat'] or '없음' for _, d in rows}),
                  'limits': ['커밋 게이트 재생은 --review·PR 게이트 이후 강제를 모른다 — code-reviewer 미선택은 플래그 없이 커밋했을 때의 값이다',
                             'PR 모드 후보는 내지 않는다 — 머지된 PR 의 게이트 입력(본문·base)을 이력에서 재현할 수 없다',
                             '수정 커밋은 제목 정규식(fixPattern)과 파일 겹침으로만 본다 — 원인 귀속이 아니라 상관이다'],
                  'candidates': cands, 'unclassified': bad}, ensure_ascii=False, indent=2))
PY
    ;;

table)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    python3 - "$@" <<'PY' || exit 3
import json, sys
try:
    m = json.load(open(sys.argv[1]))
    appr = {a['id']: a['approved'] for a in json.load(open(sys.argv[2]))} if len(sys.argv) > 2 else None
except Exception as e:
    print(f'입력을 읽지 못했다 ({type(e).__name__}: {e})', file=sys.stderr); sys.exit(3)
pct = lambda r: '—' if r is None else f'{r * 100:.1f}%'
print(f"대상 `{m['origin'] or m['repo']}` @ `{m['head'][:12]}` · 엔진 {m['engineVersion']} · 비머지 커밋 {m['scanned']}개 재분류 · 창 {m['window']}커밋")
print(f"재현: `{m['command']}` (수정 커밋 정규식 `{m['fixPattern']}`)\n")
head = '| 후보 | 위반율(강제 비용) | 영향도(미선택 / 선택 뒤 수정) | 복구 비용(줄·거리 중앙값) | 자동 수정 |'
sep = '|---|---|---|---|---|'
if appr is not None:
    head += ' 승인 |'; sep += '---|'
print(head); print(sep)
for c in m['candidates']:
    a = c['axes']; v, i, r = a['violationRate'], a['impact'], a['recoveryCost']
    row = (f"| `{c['id']}` | {v['skipped']}/{v['total']} ({pct(v['rate'])}) | "
           f"{i['skippedFollowedByFix']}/{v['skipped']} ({pct(i['skippedRate'])}) / "
           f"{i['selectedFollowedByFix']}/{i['selected']} ({pct(i['selectedRate'])}) | "
           f"{r['fixLinesMedian'] if r['fixLinesMedian'] is not None else '—'}줄 · "
           f"{r['fixDistanceMedian'] if r['fixDistanceMedian'] is not None else '—'}커밋 | {a['autoFix'].split(' — ')[0]} |")
    if appr is not None:
        row += f" {appr.get(c['id'], '미승인')} |"
    print(row)
if not m['candidates']:
    print('| (후보 없음 — 강제할 수 있는 lane 이 이미 모든 커밋에서 돈다) | | | | |' + (' |' if appr is not None else ''))
print('\n한계: ' + ' / '.join(m['limits']))
if m['unclassified']:
    print(f"분류 못 한 커밋 {len(m['unclassified'])}개 — 첫 사유: {m['unclassified'][0]['reason']}")
PY
    ;;

select)
    [ $# -ge 2 ] || usage
    python3 - "$@" <<'PY' || exit 3
import datetime, json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    print(f'실측 결과를 읽지 못했다 ({type(e).__name__}: {e})', file=sys.stderr); sys.exit(3)
by = {c['id']: c['adjustment'] for c in m['candidates']}
ids = sys.argv[2:]
miss = [i for i in ids if i not in by]
if miss:
    print(f'후보에 없는 id: {", ".join(miss)} (있는 것: {", ".join(by) or "없음"})', file=sys.stderr); sys.exit(3)
if len(set(ids)) != len(ids):
    print('같은 id 를 두 번 골랐다', file=sys.stderr); sys.exit(3)
today = datetime.date.today().isoformat()
print(json.dumps([{**by[i], 'approved': today} for i in ids], ensure_ascii=False, indent=2))
PY
    ;;

*) usage ;;
esac
