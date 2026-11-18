# 결함: 새 노트의 status 가 규칙의 enum(draft·active·archived) 밖의 값이다 — vault-linter FAIL 이 기대값.
. "$(dirname "$0")/_vault_base.sh" "$1"
git checkout -q -b docs/release-checklist
add_note published
git add -A; git commit -qm "docs: add release checklist note"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 배포 전 점검 노트를 추가한다.

## 검증
- 링크 대상 노트가 있는 것을 확인했다.
MD
echo '{"lanes":{"vault-linter":"FAIL"}}' > "$1/expect.json"
