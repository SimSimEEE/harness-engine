# test-runner 입력의 공통 바탕 — 의존성 없는 node 라이브러리 하나와 내장 테스트 러너 테스트, 그 원격.
# 쓰는 쪽: `. _node_base.sh <out>` 뒤 브랜치를 따고 변경을 커밋한다. 회귀 입력과 대조군은 같은
# 함수를 고치되, 기존 테스트를 깨는지 하나만 다르다.
# 카테고리는 입력이 들고 온다(<out>/overlay) — 회귀 명령이 `node --test` 로 확정돼 설치·네트워크가 필요 없다.
set -e
R="$1"; mkdir -p "$R"
cp -R "$(dirname "${BASH_SOURCE[0]}")/_overlay" "$R/overlay"
git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p src test
printf '{"name":"slug-kit","version":"1.0.0","private":true,"scripts":{"test":"node --test"}}\n' > package.json
cat > src/slugify.js <<'JS'
'use strict';

// 제목을 URL 조각으로 바꾼다: 소문자, 영숫자 외 문자는 '-', 연속 '-' 는 하나로, 양끝 '-' 제거.
function slugify(title) {
    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');
}

module.exports = { slugify };
JS
cat > test/slugify.test.js <<'JS'
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { slugify } = require('../src/slugify');

test('lowercases and joins words', () => {
    assert.equal(slugify('Hello World'), 'hello-world');
});

test('collapses separators and trims edges', () => {
    assert.equal(slugify('  --Release  Notes!! '), 'release-notes');
});
JS
node --test >/dev/null
git add -A; git commit -qm "feat: add slugify"; git push -q origin develop
git remote set-head origin develop

# 깨진 기준선 — 지금 구현이 못 맞추는 테스트 하나를 develop 에 커밋·push 한다. 브랜치가 새로 깨는 것과 구별하게 한다.
add_broken_baseline() {
    cat >> test/slugify.test.js <<'JS'

test('folds accented letters', () => {
    assert.equal(slugify('Café'), 'cafe');
});
JS
    local o; o="$(node --test 2>&1 || true)"
    echo "$o" | grep -qE '^# fail 1$' || { echo "기준선 실패가 정확히 1개여야 한다: $(echo "$o" | grep -E '^# (pass|fail) ')" >&2; exit 1; }
    git commit -qam "test: expect accented letters to fold"
    git push -q origin develop
}
