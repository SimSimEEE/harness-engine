#!/bin/bash
# mutate.sh — 계획의 "변이 확인" 테스트 항목을 게이트 안에서 실행한다.
#
#   mutate.sh --origin <원본 레포> <변이 명세.json> <격리 worktree>
#
# 명세(plan.sh mutations 가 찾고 검사한다): {planId, cmd, mutations:[{name, refs, patches:[{file, find, replace}]}]}
# 변이마다: patch 적용(find 는 정확히 한 번 나와야 한다) → cmd 실행 → 원복 → 원복을 바이트로 대조.
# cmd 가 0 이 아닌 코드로 끝나면 그 변이는 죽었다(killed). 참조(ref)는 그 참조의 변이가 **전부** 죽어야 닫힌다.
# 테스트 단언이 아니라 컴파일이 잡았거나(compile-error) 시간이 다 됐으면(timeout) killed 가 아니다 — 닫지 않는다.
#
# 변이 전 기준 실행이 먼저다. 기준이 이미 실패하면 "변이가 테스트를 깨뜨렸다" 를 가를 수 없으므로
# 아무 참조도 닫지 않는다(baseline-failed).
#
# **원본 레포에서는 돌지 않는다** — 파일을 고쳐 쓰기 때문이다. test-runner 의 격리 worktree 에서만 돈다.
# 출력: stdout 에 결과 JSON, stderr 에 변이마다 한 줄. 모든 참조가 닫히면 exit 0, 아니면 1, 사용법·안전 오류는 2.
# CONTRACT: mutations-run-in-gate
set -u
ORIGIN=""
if [ "${1:-}" = "--origin" ]; then ORIGIN="${2:-}"; shift 2; fi
MANIFEST="${1:-}"; ROOT="${2:-}"
if [ -z "$ORIGIN" ] || [ -z "$MANIFEST" ] || [ -z "$ROOT" ]; then
    echo "usage: mutate.sh --origin <repo> <manifest.json> <isolated-worktree>" >&2; exit 2
fi
exec python3 - "$ORIGIN" "$MANIFEST" "$ROOT" <<'PY'
import json, os, re, subprocess, sys

origin, manifest, root = sys.argv[1:4]
def die(msg):
    print(f'mutate: {msg}', file=sys.stderr); sys.exit(2)

if not os.path.isdir(root):
    die(f'격리 worktree 가 없다: {root}')
if not os.path.isdir(origin):
    die(f'원본 레포가 없다: {origin}')
_r, _o = os.path.realpath(root), os.path.realpath(origin)
# 같은 경로만이 아니라 원본의 하위·상위 경로도 거부한다 — 어느 쪽이든 patch 가 원본 파일에 닿는다.
if _r == _o or _r.startswith(_o + os.sep) or _o.startswith(_r + os.sep):
    die('원본 레포(또는 그 안·바깥 경로)에서는 돌지 않는다 — 격리 worktree 경로를 넘겨라')
try:
    m = json.load(open(manifest, encoding='utf-8'))
    cmd, muts = m['cmd'], m['mutations']
except Exception as e:
    die(f'명세를 읽지 못했다: {type(e).__name__}: {e}')
TIMEOUT = int(os.environ.get('MUTATE_TIMEOUT') or 600)
ANSI = re.compile(r'\x1b\[[0-9;]*m')

# 테스트 명령은 자기 프로세스 그룹에서 돈다 — 시간 초과·중단 때 jest 워커 같은 손자까지 함께 끝낸다.
# 그러지 않으면 끝나지 않은 변이의 테스트가 다음 변이를 적용한 worktree 위에서 계속 돈다.
import signal
_child = [None]
def _kill_group(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass

def run():
    p = subprocess.Popen(cmd, shell=True, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors='replace', start_new_session=True)
    _child[0] = p
    try:
        raw, _ = p.communicate(timeout=TIMEOUT)
        out, code = ANSI.sub('', raw or ''), p.returncode
    except subprocess.TimeoutExpired:
        _kill_group(p)
        raw, _ = p.communicate()
        out, code = ANSI.sub('', raw or ''), 'timeout'
    finally:
        _child[0] = None
    # jest 의 실패 표기만 이름으로 뽑는다. 다른 러너면 비고, 판정은 종료 코드로 한다.
    failed = re.findall(r'✕ (.+?)(?: \(\d+ ms\))?$', out, re.M)
    tail = [l for l in out.splitlines() if l.strip()][-3:]
    return code, failed, tail, 'Test suite failed to run' in out

def path_of(f):
    p = os.path.realpath(os.path.join(root, f))
    if not p.startswith(os.path.realpath(root) + os.sep):
        die(f'worktree 밖 경로를 고치려 한다: {f}')
    return p

snap = {}
for x in muts:
    for p in x['patches']:
        fp = path_of(p['file'])
        if fp not in snap:
            try:
                snap[fp] = open(fp, 'rb').read()
            except OSError as e:
                snap[fp] = None   # 없는 파일 — 그 변이는 patch-miss 가 된다

def restore():
    for fp, b in snap.items():
        if b is not None:
            open(fp, 'wb').write(b)

# 도구 시간 상한 등으로 끊겨도 변이를 남기지 않는다 — finally 는 SIGTERM 에서 돌지 않는다.
def _on_signal(sig, _frm):
    if _child[0] is not None:
        _kill_group(_child[0])
    restore(); print(f'mutate: 신호 {sig} 로 중단 — 원복했다', file=sys.stderr); sys.exit(2)
for _s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_s, _on_signal)

def restored():
    return all(b is None or open(fp, 'rb').read() == b for fp, b in snap.items())

res = {'manifest': manifest, 'planId': m.get('planId'), 'root': root, 'cmd': cmd, 'results': []}
code, failed, tail, _ = run()
res['baseline'] = {'exit': code, 'failed': failed, 'tail': tail}
if code != 0:
    print(f'MUTATION <baseline> FAILED (exit {code}) — 변이 전 테스트가 이미 실패한다. 아무 참조도 닫지 않는다.', file=sys.stderr)
    res['refs'] = {r: 'baseline-failed' for x in muts for r in x['refs']}
    print(json.dumps(res, ensure_ascii=False, indent=1)); sys.exit(1)
print(f'MUTATION <baseline> passed (exit 0)', file=sys.stderr)

try:
    for x in muts:
        row = {'name': x['name'], 'refs': x['refs']}
        miss = None
        for p in x['patches']:
            fp = path_of(p['file'])
            if snap.get(fp) is None:
                miss = f"파일이 없다: {p['file']}"; break
            s = open(fp, encoding='utf-8', errors='surrogateescape').read()
            n = s.count(p['find'])
            if n != 1:
                miss = f"{p['file']}: find 가 {n}번 나온다 (정확히 1번이어야 한다): {p['find'][:60]!r}"; break
            open(fp, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(p['find'], p['replace']))
        if miss:
            row.update(status='patch-miss', reason=miss)
        else:
            code, failed, tail, compile_err = run()
            st = ('survived' if code == 0 else 'timeout' if code == 'timeout'
                  else 'compile-error' if compile_err else 'killed')
            row.update(status=st, exit=code, failed=failed, tail=tail)
        restore()
        if not restored():
            die(f"{x['name']} 원복에 실패했다 — worktree 를 버려라: {root}")
        res['results'].append(row)
        why = row.get('reason') or ('; '.join(row.get('failed') or []) or ' / '.join(row.get('tail') or []))
        print(f"MUTATION {x['name']} {row['status']}"
              + (f" (exit {row.get('exit')})" if 'exit' in row else '')
              + f" refs={','.join(x['refs']) or '-'} :: {why[:300]}", file=sys.stderr)
finally:
    restore()

refs = {}
for row in res['results']:
    for r in row['refs']:
        prev = refs.get(r, 'killed')
        refs[r] = prev if prev != 'killed' else row['status']
res['refs'] = refs
for r, st in sorted(refs.items()):
    print(f'REF {r} {st}', file=sys.stderr)
print(json.dumps(res, ensure_ascii=False, indent=1))
sys.exit(0 if refs and all(v == 'killed' for v in refs.values()) else 1)
PY
