# 결함 셋: 새 노트의 status 가 enum 밖, 필수 키 tags 누락, 없는 노트로 가는 링크 — vault-linter FAIL 이 기대값.
. "$(dirname "$0")/_vault_base.sh" "$1"
git checkout -q -b docs/rollback-steps
cat > notes/rollback-steps.md <<'MD'
---
type: note
status: published
created: "2026-11-03"
---

# 롤백 절차

1. 직전 배포 태그를 확인한다.
2. 상세 순서는 [[release-runbook]] 을 따른다.
MD
[ ! -e notes/release-runbook.md ] || { echo '링크 대상이 있다 — 깨진 링크 결함이 아니다' >&2; exit 1; }
git add -A; git commit -qm "docs: add rollback steps note"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 롤백 절차 노트를 추가한다.

## 검증
- 노트 내용을 읽어 확인했다.
MD
echo '{"lanes":{"vault-linter":"FAIL"}}' > "$1/expect.json"
