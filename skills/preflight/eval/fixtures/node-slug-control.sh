# 대조군: 같은 함수에 최대 길이 옵션을 더한다. 기존 테스트는 그대로 통과한다 — test-runner PASS 가 기대값.
. "$(dirname "$0")/_node_base.sh" "$1"
git checkout -q -b feat/slug-max-length
python3 - <<'PY'
p='src/slugify.js'; s=open(p).read()
s=s.replace("""function slugify(title) {
    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');
}""","""// maxLength 를 주면 그 길이에서 자르고, 잘린 끝의 '-' 를 다시 지운다.
function slugify(title, maxLength) {
    const s = String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');
    return maxLength > 0 ? s.slice(0, maxLength).replace(/-+$/, '') : s;
}""")
open(p,'w').write(s)
PY
cat >> test/slugify.test.js <<'JS'

test('cuts at maxLength without a trailing separator', () => {
    assert.equal(slugify('Release Notes Draft', 8), 'release');
});
JS
node --test >/dev/null
git commit -qam "feat: add an optional slug max length"
cat > "$1/body.md" <<'MD'
## 변경 내용
- slug 에 최대 길이 옵션을 더한다. 잘린 끝의 구분자는 지운다.

## 검증
- `node --test` 로 기존·추가 테스트 3건 통과를 확인했다.
MD
echo '{"lanes":{"test-runner":"PASS"}}' > "$1/expect.json"
