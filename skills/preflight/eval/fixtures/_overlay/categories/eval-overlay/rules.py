# eval-overlay 카테고리 — flip eval 입력 전용. 실제 레포는 이 카테고리에 속하지 않는다:
# flip.sh 가 입력 디렉터리의 overlay/ 를 PF_OVERLAY_DIR 로 줄 때만 적재된다.
# 게이트 오버레이 레포(엔진 위에 얹는 훅·에이전트 레포)를 재현한다. 회귀 명령은 그 레포의 meta-test.sh 이고,
# 실제 오버레이처럼 임시 HOME 에 엔진 + 이 스냅숏(오버레이)을 설치본으로 얹어 돈다 — ~/.claude 설치본은 검사 대상이 아니다.
import os
import shlex


def match(ctx):
    return ['ENGINE_PIN', 'categories/categories.json'] if (
        ctx.snap_has('ENGINE_PIN') and ctx.snap_has('categories/categories.json') and ctx.snap_has('meta-test.sh')) else []


def suites(ctx, changed):
    if not match(ctx):
        return []
    trig = [f for f in changed if f.startswith(('hooks/', 'agents/', 'skills/'))]
    if not trig:
        return []
    # 엔진은 이 분류를 돌린 엔진 체크아웃이다(실제 오버레이 카테고리와 같은 규칙) — 스냅숏 밖에 있다.
    eng = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(os.path.join(str(ctx.selfdir), 'classify.sh')))))
    return [{'name': 'meta-test', 'marker': 'meta-test.sh',
             'cmd': f"HARNESS_ENGINE={shlex.quote(eng)} bash {ctx.snap_token}/meta-test.sh", 'why': trig}]
