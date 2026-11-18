# 결함 둘: 소문자 변환과 양끝 '-' 제거를 함께 뺐다 — 기존 테스트 둘이 각각 깨진다. test-runner FAIL 이 기대값.
. "$(dirname "$0")/_node_base.sh" "$1"
git checkout -q -b refactor/slug-steps
python3 - <<'PY'
p='src/slugify.js'; s=open(p).read()
old="""    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');"""
assert old in s
s=s.replace(old,"""    return String(title)
        .replace(/[^A-Za-z0-9]+/g, '-');""")
open(p,'w').write(s)
PY
# 기존 테스트 2개가 모두 깨지는지 만들 때 확인한다
o="$(node --test 2>&1 || true)"
echo "$o" | grep -qE '^# fail 2$' || { echo "기존 테스트 2개가 모두 깨져야 한다: $(echo "$o" | grep -E '^# (pass|fail) ')" >&2; exit 1; }
git commit -qam "refactor: drop redundant slug steps"
cat > "$1/body.md" <<'MD'
## 변경 내용
- slug 변환 단계를 줄인다.

## 검증
- 기존 테스트로 확인한다.
MD
echo '{"lanes":{"test-runner":"FAIL"}}' > "$1/expect.json"
