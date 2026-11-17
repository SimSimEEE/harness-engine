# 사실 주장 검사(claim-verify.sh) 픽스처의 공통 바탕 — 소스 4개와 규칙 문서 하나가 있는 develop 과 그 원격.
# 쓰는 쪽: `. _base.sh <out>` 뒤 문서를 바꾸고 `fx_commit <메시지>` 로 커밋한다(PR 모드 입력).
# 기대값은 <out>/expect.json — {"warn": {rule: 개수}, "info": {rule: 개수}, "verified": n}.
# 실행 결과에 기대는 픽스처는 "nobox": {같은 세 키} 를 더한다 — 검증된 샌드박스가 없는 플랫폼의 기대(run.sh).
# 결정론 검사기라 LLM 흔들림 측정(eval/fixtures, flip.sh)과 섞지 않는다.
set -e
R="$1"; mkdir -p "$R"
git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p src test docs
# 저작권 표기는 어순 두 가지다 — 실제 사건에서 한쪽만 찾는 정규식이 '미준수 84%' 를 냈다
for i in 1 2 3; do printf '/**\n * @copyright (C) 2022 Acme - All Rights Reserved.\n */\nexport const a%s = 1;\n' "$i" > "src/a$i.ts"; done
printf '/**\n * @copyright (C) acme.io 2019 - All Rights Reserved.\n */\n// TODO: split\nexport const b = 1;\n' > src/b.ts
printf 'console.log("probe");\n' > test/probe.ts
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
