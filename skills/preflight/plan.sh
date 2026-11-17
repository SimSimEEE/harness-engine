#!/bin/bash
# 계획 artifact 의 결속 — 브랜치가 아니라 **포인터**로 묶는다 (docs/cycle-trace.md § 4-2).
#
#   plan.sh resolve <repo>                 이 브랜치에 결속된 계획을 찾아 JSON 으로 낸다
#   plan.sh attach  <repo> <planId>        이 브랜치를 저장소의 계획에 묶는다 (포인터를 쓴다)
#   plan.sh adopt   <repo> <plan.json>     계획 파일을 저장소로 옮기고 이 브랜치를 묶는다
#   plan.sh check   <repo> [plan.json]     계획이 추적 가능한 형태인가 (결정론, docs/cycle-trace.md § 5-2)
#                                          생략하면 이 브랜치에 결속된 계획. READY 면 exit 0
#   plan.sh approve <repo> <plan.json>     사용자 승인을 계획 파일에 기록한다 (check 가 READY 일 때만)
#   plan.sh qa      <repo>                 결속된 계획이 QA 로 닫으라고 한 항목을 참조(R2/qa#1)와 함께 낸다
#   plan.sh review  <repo>                 결속된 계획이 리뷰로 닫으라고 한 항목을 참조(R2/review#1)와 함께 낸다
#   plan.sh test    <repo>                 결속된 계획이 테스트로 닫으라고 한 항목을 참조(R2/test#1)와 함께 낸다
#   plan.sh mutations <repo>               계획 옆 변이 명세(<planId>.mutations.json)를 검사해 경로·명령·닫을 참조를 낸다
#   plan.sh claims  <repo>                 결속된 계획의 claim ID 목록 (requirements 다음 invariants 순)
#
# 본체:   ${PF_PLANS:-~/.claude/plans}/<org>/<repo>/<planId>.json   (origin 이 없으면 _local/<디렉터리명>)
# 포인터: <git-common-dir>/claude-plans/<branch>.json = {"kind":"pointer","planId":"..."}
#
# CONTRACT: plan-resolve-is-one-function
# 분류(classify.sh)와 기록(receipt.sh)이 **이 스크립트 하나로** 계획을 찾는다. 경로를 각자 조립하면
# 한쪽만 고쳐져 "분류는 계획을 봤는데 영수증은 없음" 이 된다.
set -uo pipefail

cmd="${1:-}"; dir="${2:-}"; arg="${3:-}"
case "$cmd" in
    resolve|attach|adopt|check|approve|qa|review|test|mutations|claims) ;;
    *) echo "usage: plan.sh resolve|attach|adopt|check|approve|qa|review|test|mutations|claims <repo> [planId|plan.json]" >&2; exit 2 ;;
esac
[ -n "$dir" ] || { echo "repo 를 줘라" >&2; exit 2; }
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $dir" >&2; exit 2; }
if { [ "$cmd" = attach ] || [ "$cmd" = adopt ] || [ "$cmd" = approve ]; } && [ -z "$arg" ]; then echo "$cmd 에는 인자가 필요하다" >&2; exit 2; fi

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
PF_BRANCH="$(pf_branch "$dir")" CMD="$cmd" DIR="$dir" ARG="$arg" python3 - <<'PY'
import hashlib, json, os, re, subprocess, sys, time

_DEC = {'encoding': 'utf-8', 'errors': 'surrogateescape'}

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. JSON 을 쓰는 자리는 전부 여기를 지난다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

def emit(obj):
    sys.stdout.buffer.write(_json_out(obj).encode('utf-8', 'surrogateescape') + b'\n')

DIR, CMD, ARG = os.environ['DIR'], os.environ['CMD'], os.environ['ARG']

def git(*a):
    p = subprocess.run(['git', '-C', DIR, *a], capture_output=True, **_DEC)
    return p.stdout.strip() if p.returncode == 0 else ''

def _abs(p):
    return os.path.realpath(p if os.path.isabs(p) else os.path.join(DIR, p))

branch = os.environ.get('PF_BRANCH', '')   # lib.sh pf_branch — 첫 커밋 전 브랜치도 이름이 있다
top = git('rev-parse', '--show-toplevel') or DIR   # check 가 affectedArtifacts 를 이 기준으로 본다
gitdir = _abs(git('rev-parse', '--git-dir'))
# 계획 파일은 **worktree 가 공유하는** common dir 한 곳에만 있다 — 포인터든 이전 배치 본체든.
# 이전 배치를 쓰던 planner 는 `<repo>/.git/claude-plans/` 에 썼고, worktree 에서 `.git` 은 파일이라
# 그 자리는 언제나 본 체크아웃의 `.git` = common dir 이다(2026-10-26 전수: 실재 1곳, 그것도 common).
# worktree 별 git-dir 을 후보에 넣으면 읽는 곳과 결속을 검사하는 곳이 갈린다.
common = _abs(git('rev-parse', '--git-common-dir') or gitdir)

# 저장소 슬러그는 vault 연결 판정(classify.sh vault_link)과 같은 규칙으로 origin 에서 뽑는다 —
# 같은 레포의 다른 클론·worktree 가 같은 계획 저장소를 본다.
# origin 이 없으면 **common dir** 로 정한다. toplevel 은 worktree 마다 달라, 포인터(공유)와
# 본체(worktree 별)가 갈려 worktree 에서 DANGLING 이 된다.
_m = re.search(r'[:/]([^/:]+)/([^/]+?)(?:\.git)?$', git('remote', 'get-url', 'origin'))
_home = os.path.dirname(common) if os.path.basename(common) == '.git' else common
slug = (_m.group(1), _m.group(2)) if _m else ('_local', os.path.basename(_home))
store = os.path.join(os.path.expanduser(os.environ.get('PF_PLANS') or '~/.claude/plans'), *slug)

# planId 는 파일 이름이 된다. 경로 구분자·`..` 를 받으면 저장소 밖을 가리킨다.
_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')

def body_path(pid):
    return os.path.join(store, pid + '.json')

def pointer_path():
    return os.path.join(common, 'claude-plans', branch + '.json')

def claims_digest(d):
    """승인이 묶이는 대상 — claim 집합(requirements·invariants)만. 범위 밖·위험·메모를 고치는 것은
    약속을 바꾸지 않으므로 재승인을 요구하지 않는다. 키 순서와 공백에 흔들리지 않게 정규화한다."""
    body = {'requirements': d.get('requirements'), 'invariants': d.get('invariants')}
    return hashlib.sha1(_json_out(body, sort_keys=True, separators=(',', ':'))
                        .encode('utf-8', 'surrogateescape')).hexdigest()

def approval_status(d):
    a = d.get('approval')
    if not isinstance(a, dict) or not a.get('digest'):
        return 'NONE'
    # 승인 뒤 claim 이 바뀌었다 — 승인된 약속과 지금 약속이 다르다 (docs/cycle-trace.md § 4-3).
    return 'APPROVED' if a['digest'] == claims_digest(d) else 'CHANGED'

def _summary(d, path, source, pointer=None):
    return {'status': 'FOUND', 'path': path, 'source': source, 'pointer': pointer,
            'planId': d.get('planId'),
            'requirements': len(d.get('requirements') or []),
            'invariants': len(d.get('invariants') or []),
            'approval': approval_status(d)}

def _load(p):
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        return json.load(f)

def resolve():
    p = pointer_path()
    if not os.path.isfile(p):
        return {'status': 'NONE', 'path': p, 'reason': 'no plan artifact for this branch'}
    try:
        d = _load(p)
    except Exception as e:
        return {'status': 'UNREADABLE', 'path': p, 'reason': f'{type(e).__name__}: {e}'}
    if not isinstance(d, dict):
        return {'status': 'UNREADABLE', 'path': p, 'reason': 'JSON 객체가 아니다'}
    if d.get('kind') != 'pointer':
        # 이전 배치 — 본체가 브랜치 이름으로 직접 놓였다. 그대로 읽는다.
        return _summary(d, p, 'legacy')
    pid = d.get('planId') or ''
    if not _ID.match(pid):
        return {'status': 'UNREADABLE', 'path': p, 'reason': f'포인터의 planId 가 유효하지 않다: {pid!r}'}
    bp = body_path(pid)
    if not os.path.isfile(bp):
        # 포인터는 있는데 본체가 없다 — 다른 머신에서 붙였거나 저장소를 지웠다.
        # "계획 없음" 과 다르다: 약속은 있었는데 지금 읽을 수 없는 것이다.
        return {'status': 'DANGLING', 'path': bp, 'pointer': p, 'planId': pid,
                'reason': '포인터가 가리키는 계획 본체가 저장소에 없다'}
    try:
        return _summary(_load(bp), bp, 'pointer', p)
    except Exception as e:
        return {'status': 'UNREADABLE', 'path': bp, 'pointer': p, 'reason': f'{type(e).__name__}: {e}'}

def _write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(_json_out(obj, indent=2) + '\n')
    os.replace(tmp, path)

def fail(msg, code=1):
    print(msg, file=sys.stderr); sys.exit(code)

def _load_or_fail(p, what):
    try:
        return _load(p)
    except Exception as e:
        fail(f'{what} 를 읽지 못했다: {p} ({type(e).__name__}: {e})')

def _attach_check(pid, body):
    """attach 가 성공할 수 있는가. **쓰기 전에** 부른다 — adopt 가 본체를 쓴 뒤에 실패하면
    고아 본체가 남는다. 이미 같은 계획에 묶였으면 True 를 돌려준다.
    `body` 는 결속 뒤 저장소에 있을 내용이다. 이 브랜치의 이전 배치 본체는 포인터로 **대체되므로**
    그 내용이 저장소로 옮겨지는 경우(같은 내용)만 허락한다 — planId 만 보면 약속이 사라진다."""
    if branch in ('', 'HEAD'):
        fail('브랜치가 없다(detached HEAD) — 포인터는 브랜치 이름에 묶인다')
    if not _ID.match(pid):
        fail(f'planId 가 유효하지 않다: {pid!r} (영문·숫자·._- , 128자 이하)', 2)
    pp = pointer_path()
    if not os.path.isfile(pp):
        return False
    try:
        cur = _load(pp)
    except Exception:
        cur = None
    if isinstance(cur, dict) and cur.get('kind') == 'pointer':
        if cur.get('planId') == pid:
            return True
        # 덮어쓰면 이 브랜치가 따르던 약속이 조용히 바뀐다. 사람이 지우고 다시 붙인다.
        fail(f'이 브랜치에는 이미 계획이 결속돼 있다: {pp}\n'
             f'  다른 계획으로 바꾸려면 그 파일을 직접 지우고 다시 붙여라.')
    # 포인터가 아닌 파일(이전 배치 본체·깨진 파일)은 adopt 만 치울 수 있다.
    if isinstance(cur, dict) and cur.get('planId') == pid:
        if cur == body:
            return False   # 같은 계획의 이전 배치 본체 — 포인터로 바꾼다
        fail(f'이 브랜치의 이전 배치 계획이 같은 planId 의 다른 내용이다: {pp}\n'
             f'  ID 계약(change-planner) — 의미가 바뀌었으면 새 planId 를 발급해라.')
    fail(f'이 브랜치에 포인터가 아닌 계획 파일이 있다: {pp}\n'
         f'  그 파일이 이 계획이면 `plan.sh adopt <repo> {pp}` 로 옮겨라.')

def _attach_write(pid, already):
    pp = pointer_path()
    if not already:
        _write(pp, {'kind': 'pointer', 'planId': pid})
    emit({'attached': pid, 'branch': branch, 'pointer': pp, 'changed': not already})

def attach(pid):
    if not _ID.match(pid):
        fail(f'planId 가 유효하지 않다: {pid!r} (영문·숫자·._- , 128자 이하)', 2)
    if not os.path.isfile(body_path(pid)):
        fail(f'저장소에 계획이 없다: {body_path(pid)}\n  먼저 adopt 로 넣어라.')
    already = _attach_check(pid, _load_or_fail(body_path(pid), '저장소의 계획'))
    _attach_write(pid, already)

def adopt(src):
    d = _load_or_fail(src, '계획 파일')
    if not isinstance(d, dict) or d.get('kind') == 'pointer':
        fail('계획 본체가 아니다 (포인터이거나 JSON 객체가 아니다)')
    pid = d.get('planId') or ''
    if not _ID.match(pid):
        fail(f'계획의 planId 가 유효하지 않다: {pid!r}', 2)
    bp = body_path(pid)
    # 검증을 전부 끝낸 뒤에 쓴다 — 중간에 실패하면 저장소에 고아 본체가 남거나 결속이 끊긴다.
    if os.path.isfile(bp) and _load_or_fail(bp, '저장소의 계획') != d:
        # 같은 ID 에 다른 내용이면 어느 쪽이 약속인지 코드가 정할 수 없다.
        fail(f'저장소에 같은 planId 의 다른 계획이 있다: {bp}\n'
             f'  ID 계약(change-planner) — 의미가 바뀌었으면 새 planId 를 발급해라.')
    already = _attach_check(pid, d)
    fresh = not os.path.isfile(bp)
    if fresh:
        _write(bp, d)
    # 이 브랜치의 이전 배치 본체였다면 포인터가 그 자리를 **원자적으로** 대체한다(_write 의
    # os.replace). 지우고 쓰면 쓰기 실패 사이에 결속이 사라진다.
    try:
        _attach_write(pid, already)
    except OSError as e:
        if fresh:
            os.remove(bp)      # 결속에 실패한 adopt 는 저장소에 아무것도 남기지 않는다
        fail(f'포인터를 쓰지 못했다: {pointer_path()} ({e})')

# ── check — 계획이 추적 가능한 형태인가 ───────────────────────────────────────
# 기계로 표현되는 판정만 여기서 내린다(설계 원칙 2). "claim 이 판정 가능한가" 같은 의미 판정은
# 하지 않는다 — 그건 plan-reviewer 의 몫이다. 규칙의 근거는 agents/change-planner.md 의 계약이다.
# 실측 2026-10-26: 실재 계획 1건(requirement 10 · invariant 7)에서 오류 0 · 열린 질문 5 → BLOCKED.
# 스키마 밖 필드(acceptance·factsEstablished …)가 실제로 쓰이므로 모르는 키는 거부하지 않는다.
_HOW = ('test', 'qa', 'review', 'manual')
# `manual` 은 tracer 가 닫지 못한다. 많으면 추적이 형식이 된다. 초안 상한이다 — 실측 0/37.
_MANUAL_MAX = 0.3
_ITEM_ID = {'requirements': re.compile(r'^R[1-9][0-9]*$'), 'invariants': re.compile(r'^I[1-9][0-9]*$')}

def check(d):
    errors, warnings = [], []
    def err(code, msg, ref=None): errors.append({'code': code, 'ref': ref, 'msg': msg})
    def warn(code, msg, ref=None): warnings.append({'code': code, 'ref': ref, 'msg': msg})
    if not isinstance(d, dict):
        err('schema/not-object', '계획이 JSON 객체가 아니다')
        return errors, warnings, {}
    if not _ID.match(str(d.get('planId') or '')):
        err('schema/planId', f"planId 가 유효하지 않다: {d.get('planId')!r}")
    seen, hows, counts = set(), [], {k: 0 for k in _ITEM_ID}
    for key, idrx in _ITEM_ID.items():
        items = d.get(key)
        if items is None:
            items = []
        if not isinstance(items, list):
            err('schema/list', f'{key} 가 목록이 아니다', key); continue
        for i, it in enumerate(items):
            ref = f'{key}[{i}]'
            if not isinstance(it, dict):
                err('schema/item', '항목이 객체가 아니다', ref); continue
            counts[key] += 1
            iid = it.get('id')
            if not isinstance(iid, str) or not idrx.match(iid):
                err('id/format', f'id 는 {idrx.pattern[1]}<번호> 여야 한다: {iid!r}', ref)
            elif iid in seen:
                # ID 는 tracer 의 기준점이다. 겹치면 어느 claim 을 닫았는지 가를 수 없다.
                err('id/duplicate', f'id 가 겹친다: {iid}', ref)
            else:
                seen.add(iid); ref = iid
            if not (isinstance(it.get('claim'), str) and it['claim'].strip()):
                err('claim/empty', 'claim 이 비었다', ref)
            ver = it.get('verification')
            if not isinstance(ver, list) or not ver:
                # 검증 방법을 못 쓰는 claim 은 판정 불가다 (change-planner EVIDENCE).
                err('verification/missing', '검증 방법이 없다', ref); continue
            for j, v in enumerate(ver):
                vref = f'{ref}/verification[{j}]'
                how = v.get('how') if isinstance(v, dict) else None
                if how not in _HOW:
                    err('verification/how', f"how 는 {'|'.join(_HOW)} 중 하나여야 한다: {how!r}", vref)
                else:
                    hows.append(how)
                if not (isinstance(v, dict) and isinstance(v.get('what'), str) and v['what'].strip()):
                    err('verification/what', '무엇을 확인하는지(what)가 비었다', vref)
    if not any(counts.values()):
        err('schema/no-claims', 'requirement·invariant 가 하나도 없다 — 추적할 것이 없다')
    manual = hows.count('manual')
    if hows and manual / len(hows) > _MANUAL_MAX:
        err('verification/manual-ratio',
            f'manual 이 {manual}/{len(hows)} 다 (상한 {int(_MANUAL_MAX * 100)}%) — tracer 가 닫을 수 없는 검증이 너무 많다')
    oos = d.get('outOfScope')
    if not isinstance(oos, list) or not oos:
        # 무엇을 안 할지 적지 않으면 범위가 조용히 넓어진다 (change-planner 규칙).
        err('scope/out-of-scope-empty', 'outOfScope 가 비었다')
    oq = d.get('openQuestions')
    if oq is not None and not isinstance(oq, list):
        err('schema/list', 'openQuestions 가 목록이 아니다', 'openQuestions')
        oq = []
    arts = d.get('affectedArtifacts')
    if not isinstance(arts, list) or not arts:
        warn('artifacts/empty', 'affectedArtifacts 가 비었다 — 영향 범위가 기록되지 않았다')
    else:
        for i, a in enumerate(arts):
            p = a.get('path') if isinstance(a, dict) else a
            if not isinstance(p, str) or not p.strip():
                warn('artifacts/path', '경로가 비었다', f'affectedArtifacts[{i}]'); continue
            if re.match(r'^[a-z][a-z0-9+.-]*://', p) or os.path.isabs(p):
                continue     # URL·다른 레포 절대경로는 여기서 확인할 수 없다
            # 새로 만들 파일도 정당하게 들어온다 — 그래서 경고다.
            if not os.path.exists(os.path.join(top, p)):
                warn('artifacts/missing', f'레포에 없는 경로다 (새로 만들 파일이면 무시): {p}', f'affectedArtifacts[{i}]')
    # 개수는 위 검사 루프가 센 것을 쓴다 — 원본을 다시 순회하면 목록이 아닌 값에서 죽는다.
    stats = {'requirements': counts['requirements'], 'invariants': counts['invariants'],
             'verifications': len(hows), 'manual': manual,
             'openQuestions': len(oq or [])}
    return errors, warnings, stats

def run_check(src):
    if src:
        path = src
    else:
        r = resolve()
        if r['status'] != 'FOUND':
            fail(f"이 브랜치에 검사할 계획이 없다: {r['status']} ({r.get('reason') or r.get('path')})", 2)
        path = r['path']
    try:
        d = _load(path)
    except Exception as e:
        fail(f'계획 파일을 읽지 못했다: {path} ({type(e).__name__}: {e})', 2)
    errors, warnings, stats = check(d)
    # 열린 질문은 결함이 아니라 사람에게 넘길 것이다 — planner 계약의 BLOCKED 와 같은 뜻.
    verdict = 'REVISE' if errors else ('BLOCKED' if stats.get('openQuestions') else 'READY')
    emit({'verdict': verdict, 'path': path, 'planId': d.get('planId') if isinstance(d, dict) else None,
          'errors': errors, 'warnings': warnings, 'stats': stats})
    sys.exit(0 if verdict == 'READY' else 1)

def approve(src):
    """사용자 승인을 기록한다. **누가 승인했는지는 검증하지 못한다** — 이 명령을 부르는 것은 에이전트다.
    그래서 형식 조건만 코드로 막는다: READY 가 아닌 계획(오류·열린 질문)에는 승인을 쓸 수 없다.
    사용자가 채팅에서 명시적으로 승인한 뒤에만 부른다는 규칙은 skills/plan/SKILL.md 에 있다."""
    d = _load_or_fail(src, '계획 파일')
    errors, _, stats = check(d)
    if errors or stats.get('openQuestions'):
        verdict = 'REVISE' if errors else 'BLOCKED'
        fail(f'READY 가 아닌 계획은 승인할 수 없다 ({verdict}) — 먼저 `plan.sh check` 를 통과시켜라')
    d['approval'] = {'by': 'user', 'at': int(time.time() * 1000), 'digest': claims_digest(d)}
    _write(src, d)
    emit({'approved': d.get('planId'), 'path': src, 'digest': d['approval']['digest']})

# CONTRACT: qa-ref-is-one-function
# QA 항목의 참조(`R2/qa#1`)는 **여기서만** 만든다. 분류기가 QA 실행자에게 주는 목록과 영수증이
# 덮임을 계산하는 목록이 같은 문자열이어야 대조가 된다 — 양쪽이 각자 만들면 번호 규칙이 갈린다.
# 번호는 그 claim 의 `how: <how>` 항목 중 몇 번째인가(1부터)다. 다른 how 가 끼어도 번호가 밀리지 않는다.
# 리뷰 항목(`R2/review#1`)도 같은 함수가 만든다 — reviewer 가 답하는 참조와 tracer 가 받는 참조가 같아야 한다.
def how_items(d, how):
    items = []
    for key in _ITEM_ID:
        for it in (d.get(key) if isinstance(d.get(key), list) else []):
            if not isinstance(it, dict) or not isinstance(it.get('id'), str):
                continue
            k = 0
            for v in (it.get('verification') if isinstance(it.get('verification'), list) else []):
                if isinstance(v, dict) and v.get('how') == how:
                    k += 1
                    items.append({'ref': f"{it['id']}/{how}#{k}", 'id': it['id'],
                                  'claim': it.get('claim'), 'what': v.get('what')})
    return items

def run_items(how):
    r = resolve()
    if r['status'] != 'FOUND':
        emit({'status': r['status'], 'planId': r.get('planId'), 'items': []}); return
    try:
        d = _load(r['path'])
    except Exception as e:
        emit({'status': 'UNREADABLE', 'planId': r.get('planId'), 'items': [],
              'reason': f'{type(e).__name__}: {e}'}); return
    emit({'status': 'FOUND', 'planId': r.get('planId'), 'approval': r.get('approval'), 'items': how_items(d, how)})

# ── mutations — 계획의 "변이 확인" 테스트 항목을 닫을 변이 명세 ─────────────────────────────
# 변이는 코드를 바꿔야 하므로 계획 본문(승인 대상)에 넣지 않는다 — 코드가 바뀌면 patch 도 바뀌는데
# 그때마다 재승인을 요구하게 된다. 그래서 계획 옆 파일로 두고 planId 로만 묶는다.
# 명세는 **주장**이다(이 patch 가 그 항목의 변이다). 실행은 게이트 안의 mutate.sh 가 한다 —
# 밖에서 돌린 결과 파일을 근거로 받지 않는다. CONTRACT: mutations-run-in-gate
def mutations_path(plan_path):
    return plan_path[:-5] + '.mutations.json' if plan_path.endswith('.json') else plan_path + '.mutations.json'

def check_mutations(m, plan_id, test_refs):
    errs = []
    if not isinstance(m, dict):
        return ['명세가 JSON 객체가 아니다']
    if m.get('planId') != plan_id:
        errs.append(f"planId 가 계획과 다르다: {m.get('planId')!r} (계획 {plan_id!r})")
    if not isinstance(m.get('cmd'), str) or not m['cmd'].strip():
        errs.append('cmd(변이마다 돌릴 테스트 명령)가 없다')
    ms = m.get('mutations')
    if not isinstance(ms, list) or not ms:
        return errs + ['mutations 가 비었거나 목록이 아니다']
    names = set()
    for i, x in enumerate(ms):
        if not isinstance(x, dict) or not isinstance(x.get('name'), str) or not x['name']:
            errs.append(f'mutations[{i}]: name 이 없다'); continue
        if x['name'] in names:
            errs.append(f"mutations[{i}]: name 중복 {x['name']!r}")
        names.add(x['name'])
        if not isinstance(x.get('refs'), list) or not x['refs'] or not all(isinstance(r, str) for r in x['refs']):
            errs.append(f"{x['name']}: refs 는 비지 않은 문자열 목록이어야 한다")
        else:
            bad = [r for r in x['refs'] if r not in test_refs]
            if bad:
                errs.append(f"{x['name']}: 계획의 how:test 항목이 아닌 참조 {bad}")
        ps = x.get('patches')
        if not isinstance(ps, list) or not ps or not all(
                isinstance(p, dict) and all(isinstance(p.get(k), str) for k in ('file', 'find', 'replace'))
                and p['find'] for p in ps):
            errs.append(f"{x['name']}: patches 는 file·find·replace(문자열, find 비지 않음) 목록이어야 한다")
    return errs

def run_mutations():
    r = resolve()
    if r['status'] != 'FOUND':
        emit({'status': 'NONE', 'planStatus': r['status'], 'refs': []}); return
    mp = mutations_path(r['path'])
    if not os.path.isfile(mp):
        emit({'status': 'NONE', 'path': mp, 'planId': r.get('planId'), 'refs': []}); return
    try:
        d, m = _load(r['path']), _load(mp)
    except Exception as e:
        emit({'status': 'UNREADABLE', 'path': mp, 'planId': r.get('planId'), 'refs': [],
              'reason': f'{type(e).__name__}: {e}'}); return
    test_refs = {i['ref'] for i in how_items(d, 'test')}
    errs = check_mutations(m, r.get('planId'), test_refs)
    if errs:
        emit({'status': 'INVALID', 'path': mp, 'planId': r.get('planId'), 'refs': [], 'errors': errs}); return
    refs = sorted({ref for x in m['mutations'] for ref in x['refs']})
    emit({'status': 'FOUND', 'path': mp, 'planId': r.get('planId'), 'cmd': m['cmd'],
          'mutations': len(m['mutations']), 'refs': refs})

# 머지 보고의 분모다 — "claim N개 중 M개 닫힘" 의 N 은 tracer 가 보고한 수가 아니라 이 목록이다.
def run_claims():
    r = resolve()
    if r['status'] != 'FOUND':
        emit({'status': r['status'], 'planId': r.get('planId'), 'ids': []}); return
    try:
        d = _load(r['path'])
    except Exception as e:
        emit({'status': 'UNREADABLE', 'planId': r.get('planId'), 'ids': [], 'reason': f'{type(e).__name__}: {e}'}); return
    ids = [it['id'] for key in _ITEM_ID for it in (d.get(key) if isinstance(d.get(key), list) else [])
           if isinstance(it, dict) and isinstance(it.get('id'), str)]
    emit({'status': 'FOUND', 'planId': r.get('planId'), 'approval': r.get('approval'), 'ids': ids})

if CMD == 'resolve':
    emit(resolve())
elif CMD == 'claims':
    run_claims()
elif CMD in ('qa', 'review', 'test'):
    run_items(CMD)
elif CMD == 'mutations':
    run_mutations()
elif CMD == 'approve':
    approve(ARG)
elif CMD == 'check':
    run_check(ARG)
elif CMD == 'attach':
    attach(ARG)
else:
    adopt(ARG)
PY
