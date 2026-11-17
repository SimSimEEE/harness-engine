# 결함: 코드는 깨끗한데 PR 본문이 이 머신 전용 도구의 이름과 상태를 바깥 글에 쓴다.
. "$(dirname "$0")/_base.sh" "$1"
git checkout -q -b feat/refund-guard-note
add_amount_guard
git commit -qam "fix: reject a non-positive refund amount"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 환불 금액이 0 이하이면 PG 를 부르기 전에 `400 INVALID` 로 거절한다.
- 커밋 게이트 영수증과 secret-scanner·code-reviewer lane 이 모두 PASS 였다.

## 검증
- preflight 게이트 통과 (lane 3개 PASS, 영수증 기록됨)
MD
echo '{"lanes":{"pr-quality":"FAIL"}}' > "$1/expect.json"
