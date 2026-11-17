# shell-tool 카테고리 — 게이트 자신을 담은 셸·python 도구 레포(이 하네스 레포). classify.sh 가 적재해 부른다.
# 이름은 넓지만 판정은 "스위트와 훅이 함께 스냅숏에 있다" 다 — 717a7e9 의 _self_suites 대상 판정 그대로.
import posixpath

_MT = 'skills/preflight/meta-test.sh'
_HOOK = 'hooks/preflight-gate.sh'


# 스위트가 **스냅숏에** 있는가로 본다 — 미추적 사본만 있으면 커밋될 레포는 게이트 레포가 아니다.
def match(ctx):
    return [_MT, _HOOK] if (ctx.snap_has(_MT) and ctx.snap_has(_HOOK)) else []


# ── 레포 자신의 회귀 스위트 — 돌릴지는 분류기가 정한다. test-runner 가 고르지 않는다.
# lane 이 고르면 변경 파일을 보고 건너뛰고, test-runner 는 .ts/.js 가 바뀔 때만 골라지므로
# 셸·에이전트 정의만 바뀐 변경에서는 스위트가 돌지 않는다. 그래서 스위트가 있으면 lane 도 분류기가 고른다.
# 판단이 안 서면 더 도는 쪽이다: agents/ 도 스위트가 읽으므로 meta-test 의 트리거에 넣는다.
# 실행 명령도 스냅숏 안의 스크립트다(#8 R21) — 원본 워킹트리에만 있는 변경이 스위트 결과를 바꾸지
# 않는다. 스냅숏 경로는 워크플로가 만든 뒤에야 정해지므로 자리표시(ctx.snap_token)로 둔다.
# CONTRACT: suites-decided-by-classifier
def suites(ctx, changed):
    if not match(ctx):
        return []
    tok = ctx.snap_token
    out = []
    trig = [f for f in changed if f.startswith(('hooks/', 'skills/', 'agents/'))]
    if trig:
        # 설치본은 체크아웃 하나만 가리킨다. 래퍼가 있으면 임시 HOME 으로 **이 체크아웃**을 설치본
        # 삼아 돌린다 — 없으면 설치 체크아웃이 다른 브랜치일 때 어느 워크트리도 통과하지 못한다.
        _mt = ('skills/preflight/meta-test-isolated.sh' if ctx.snap_has('skills/preflight/meta-test-isolated.sh')
               else _MT)
        out.append({'name': 'meta-test', 'marker': posixpath.basename(_mt), 'cmd': f"bash {tok}/{_mt}", 'why': trig})
    trig = [f for f in changed if (f.startswith('agents/') and f.endswith('.md')) or f == 'skills/preflight/classify.sh']
    if trig:
        out.append({'name': 'lane-contract-check', 'marker': 'lane-contract-check.sh',
                    'cmd': f"bash {tok}/skills/preflight/lane-contract-check.sh", 'why': trig})
    return out
