# 결함: 새 노트의 created 가 규칙 형식("YYYY-MM-DD") 밖의 슬래시 날짜다. 다른 키·링크는 유효 — vault-linter FAIL 이 기대값.
. "$(dirname "$0")/_vault_base.sh" "$1"
git checkout -q -b docs/oncall-handoff
cat > notes/oncall-handoff.md <<'MD'
---
type: note
status: active
created: "2026/11/04"
tags: [oncall]
---

# 당번 인계

1. 열린 알림과 진행 중인 조치를 적는다.
2. 작성 규칙은 [[getting-started]] 를 따른다.
MD
git add -A; git commit -qm "docs: add oncall handoff note"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 당번 인계 노트를 추가한다.

## 검증
- 링크 대상 노트가 있는 것을 확인했다.
MD
echo '{"lanes":{"vault-linter":"FAIL"}}' > "$1/expect.json"
