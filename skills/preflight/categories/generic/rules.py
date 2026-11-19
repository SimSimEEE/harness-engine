# generic 카테고리 — 기본(fallback) 카테고리. 어느 카테고리에도 신호가 없는 레포가 여기 속한다.
# 선언(categories.json)의 `fallback` 으로만 소속된다 — classify.sh 는 fallback 의 match 를 부르지 않는다.
# match 로 모든 레포에 걸면 다른 카테고리와 늘 겹친다(겹침은 풀지 않는다).
# 규칙은 두지 않는다: 관례 문서·QA 엔드포인트·vault 연동이 없고, lane 은 엔진 기본 선택(파일 종류별)대로 돈다.
# 레포에 맞는 규칙이 필요하면 새 카테고리를 만들고(오버레이의 categories/), /harness-profile 로 프로필을 둔다.


def match(ctx):
    return []


# 시크릿 검사 라우팅: SECRET_SCAN 을 두지 않는다(= 'always', 늘 secret-scanner). 미분류 레포가 모두 여기 오므로 'auto' 면
# 미분류 문서 레포의 개인 데이터 검사와 정규식 밖 자격증명 검사가 함께 빠진다.
