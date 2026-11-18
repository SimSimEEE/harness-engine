# 대조군(오탐 유도): 본문에 enum 밖 낱말·슬래시 날짜·URL 이 나오지만 frontmatter·링크는 규칙 안이다 — vault-linter PASS 가 기대값.
. "$(dirname "$0")/_vault_base.sh" "$1"
git checkout -q -b docs/status-guide
cat > notes/status-guide.md <<'MD'
---
type: guide
status: archived
created: "2026-11-05"
tags: []
---

# 상태 값 안내

노트의 상태는 draft · active · archived 셋 중 하나다. 다른 도구에서 쓰던 "published" 는 여기서 쓰지 않는다.
11/05 회의에서 정한 내용이며, 옛 설명은 https://example.com/docs/status 에 있었다.
작성 규칙은 [[getting-started]] 를 따른다.
MD
git add -A; git commit -qm "docs: add status guide note"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 노트 상태 값 안내를 추가한다.

## 검증
- 링크 대상 노트가 있는 것을 확인했다.
MD
echo '{"lanes":{"vault-linter":"PASS"}}' > "$1/expect.json"
