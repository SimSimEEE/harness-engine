# 대조군: 기준선(develop)에 이미 실패하는 테스트가 하나 있다. 그 위의 최대 길이 옵션 변경은 새로 깨는 테스트가 없다 — test-runner PASS 가 기대값.
. "$(dirname "$0")/_node_base.sh" "$1"
add_broken_baseline
git checkout -q -b feat/slug-max-length
python3 - <<'PY'
p='src/slugify.js'; s=open(p).read()
old="""function slugify(title) {
    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');
}"""
assert old in s
s=s.replace(old,"""// maxLength 를 주면 그 길이에서 자르고, 잘린 끝의 '-' 를 다시 지운다.
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
# 실패는 기준선의 1개뿐이어야 한다
o="$(node --test 2>&1 || true)"
echo "$o" | grep -qE '^# fail 1$' || { echo "실패가 기준선의 1개뿐이어야 한다: $(echo "$o" | grep -E '^# (pass|fail) ')" >&2; exit 1; }
git commit -qam "feat: add an optional slug max length"
cat > "$1/body.md" <<'MD'
## 변경 내용
- slug 에 최대 길이 옵션을 더한다. 잘린 끝의 구분자는 지운다.

## 검증
- `node --test` 로 추가 테스트 통과를 확인했다. 악센트 문자 테스트는 develop 에서부터 실패한다.
MD
echo '{"lanes":{"test-runner":"PASS"}}' > "$1/expect.json"
