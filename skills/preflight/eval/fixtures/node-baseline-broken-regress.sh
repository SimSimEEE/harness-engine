# 결함: 기준선(develop)에 이미 실패하는 테스트가 하나 있고, 그 위에서 소문자 변환을 뺐다 — 통과하던 테스트가 새로 깨진다. test-runner FAIL 이 기대값.
. "$(dirname "$0")/_node_base.sh" "$1"
add_broken_baseline
git checkout -q -b refactor/slug-pattern
python3 - <<'PY'
p='src/slugify.js'; s=open(p).read()
old="""    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')"""
assert old in s
s=s.replace(old,"""    return String(title)
        .replace(/[^A-Za-z0-9]+/g, '-')""")
open(p,'w').write(s)
PY
# 실패가 기준선의 1개보다 많아야 한다
o="$(node --test 2>&1 || true)"
f="$(echo "$o" | sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p')"
[ -n "$f" ] && [ "$f" -gt 1 ] || { echo "실패가 기준선의 1개보다 많아야 한다: fail=${f:-?}" >&2; exit 1; }
git commit -qam "refactor: simplify slug pattern"
cat > "$1/body.md" <<'MD'
## 변경 내용
- slug 정규식을 한 단계로 줄인다.

## 검증
- 기존 테스트로 확인한다. 악센트 문자 테스트는 develop 에서부터 실패한다.
MD
echo '{"lanes":{"test-runner":"FAIL"}}' > "$1/expect.json"
