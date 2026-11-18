# eval-node 카테고리 — flip eval 입력 전용. 실제 레포는 이 카테고리에 속하지 않는다:
# flip.sh 가 입력 디렉터리의 overlay/ 를 PF_OVERLAY_DIR 로 줄 때만 적재된다.
# 의존성 설치 없이 도는 node 내장 테스트 러너를 회귀 명령으로 확정해, test-runner 판정이 네트워크·
# 로컬 node_modules 상태에 흔들리지 않게 한다. 흔들림은 측정 대상(모델)이 아니라 잡음이다.


def match(ctx):
    return ['package.json', 'test/'] if (ctx.snap_has('package.json') and not ctx.snap_has('VAULT_RULES.md')
                                         and ctx.snap_under('test', ('.test.js',))) else []


def suites(ctx, changed):
    if not match(ctx):
        return []
    trig = [f for f in changed if f.endswith('.js')]
    if not trig:
        return []
    return [{'name': 'node-test', 'marker': 'node --test', 'cmd': f"cd {ctx.snap_token} && node --test", 'why': trig}]
