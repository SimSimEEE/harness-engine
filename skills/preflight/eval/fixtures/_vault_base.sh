# vault-linter 입력의 공통 바탕 — 규칙 문서·템플릿·노트 하나가 있는 문서 레포와 그 원격.
# 쓰는 쪽: `. _vault_base.sh <out>` 뒤 브랜치를 따고 노트를 커밋한다. 위반 입력과 대조군은
# frontmatter 값 하나만 다르다 — 기대 판정의 차이가 그 값 하나로 줄어든다.
# 카테고리는 입력이 들고 온다(<out>/overlay) — flip.sh 가 이 머신의 오버레이 대신 그것을 쓴다.
set -e
R="$1"; mkdir -p "$R"
cp -R "$(dirname "${BASH_SOURCE[0]}")/_overlay" "$R/overlay"
git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p notes templates
cat > VAULT_RULES.md <<'MD'
# Vault 규칙

이 문서가 판정 기준의 정본이다. 기계 검사 스크립트는 없다.

## 문서 위치
- 노트는 `notes/` 아래 `.md` 다. 템플릿은 `templates/note.md` 다.

## Frontmatter (필수)
- `type`: `note` | `guide`
- `status`: `draft` | `active` | `archived` — 이 밖의 값은 ERROR
- `created`: `"YYYY-MM-DD"` (따옴표로 감싼 문자열)
- `tags`: 문자열 배열 (비어도 된다)
- 템플릿의 키가 하나라도 빠지면 ERROR

## 링크
- `[[slug]]` 형식. 대상 `notes/<slug>.md` 가 있어야 한다.

## 이름·내용
- 파일명은 영어 kebab-case.
- 머신 절대경로(사용자 홈 아래 경로)·개인 연락처 금지.
MD
cat > templates/note.md <<'MD'
---
type: note
status: draft
created: "YYYY-MM-DD"
tags: []
---

# 제목

본문.
MD
cat > notes/getting-started.md <<'MD'
---
type: guide
status: active
created: "2026-10-01"
tags: [onboarding]
---

# 시작하기

새 노트는 `templates/note.md` 를 복사해 만든다.
MD
git add -A; git commit -qm "docs: add vault rules and first note"; git push -q origin develop
git remote set-head origin develop

# 노트 하나를 더한다 — 상태 값만 인자로 받는다.
add_note() {
    cat > notes/release-checklist.md <<MD
---
type: note
status: $1
created: "2026-11-02"
tags: [release]
---

# 배포 전 점검

1. 변경 내역을 정리한다.
2. 롤백 절차를 확인한다 — [[getting-started]] 의 작성 규칙을 따른다.
MD
}
