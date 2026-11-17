# 테스트 전용 카테고리 — 공용 코어 패키지(acme-core·@acme-core/*)에 의존하는 TS 백엔드. meta-test 의 훅·프로필 절이 쓴다.
# 실제 조직 카테고리에 기대지 않고 카테고리 층 동작(근거 신호·절차 요구·겹침)을 보려고 둔다. 설치본 카테고리가 아니다.
import json


def _core(n):
    return n == 'acme-core' or str(n).startswith('@acme-core/')


def match(ctx):
    if not ctx.snap_has('package.json'):
        return []
    try:
        p = json.loads(ctx.snap_read('package.json') or '')
        deps = [(s, k) for s in ('dependencies', 'devDependencies', 'peerDependencies') for k in (p.get(s) or {})]
    except Exception as e:
        return [f'package.json: 읽을 수 없다 ({type(e).__name__}) — 판단이 안 서면 대상으로 본다']
    return [f'package.json: {s}.{k}' for s, k in deps if _core(k)]
