# 결함 없음: PG 를 부르기 전에 0 이하 금액을 거절한다. 본문도 깨끗하다 — 두 lane 모두 통과가 기대값.
. "$(dirname "$0")/_base.sh" "$1"
git checkout -q -b feat/refund-guard
add_amount_guard
git commit -qam "fix: reject a non-positive refund amount"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 환불 금액이 0 이하이면 PG 를 부르기 전에 `400 INVALID` 로 거절한다.

## 검증
- 금액 0 · 음수 요청이 PG 호출 없이 거절되는 것을 확인했다.
MD
echo '{"lanes":{"code-reviewer":"PASS","pr-quality":"PASS"}}' > "$1/expect.json"
