# 재측정(③) 픽스처의 같은 레포 바탕 — 소스 404개(저작권 표기 어순 A 62개 · 어순 B 338개 · 없음 4개)와
# 체크리스트 규칙 문서가 있는 develop 과 그 원격. 2026-09-09 사건의 숫자를 한 레포 안에 재현한다:
# 어순 A 만 찾으면 "없음" 이 342 이고, 두 어순을 다 찾으면 400 이 표기를 단다.
# 쓰는 쪽: `. _corpus404.sh <out>` 뒤 문서를 바꾸고 `fx_commit <메시지>` 로 커밋한다(PR 모드 입력).
set -e
R="$1"; mkdir -p "$R"; R="$(cd "$R" && pwd -P)"
git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p src docs
python3 - <<'PY'
for i in range(404):
    if i < 62:    hdr = '/**\n * @copyright (C) 2022 Acme - All Rights Reserved.\n */\n'
    elif i < 400: hdr = '/**\n * @copyright (C) acme.io 2019 - All Rights Reserved.\n */\n'
    else:         hdr = '/** generated */\n'
    open(f'src/m{i:03d}.ts', 'w').write(hdr + f'export const m{i} = {i};\n')
PY
cat > docs/conventions.md <<'MD'
# 코드 관례

## 파일 헤더

- [ ] `@author` 줄 존재
- [ ] Copyright 줄 존재 (`@copyright (C) … - All Rights Reserved.`)
MD
fx_commit() { git add -A; git "com""mit" -q -m "$1"; }
fx_commit "docs: add conventions"; git push -q origin develop
git remote set-head origin develop
git checkout -q -b docs/claim-fixture
