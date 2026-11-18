# 결함: 정리 명목으로 소문자 변환을 뺐다 — 기준선에서 통과하던 테스트가 새로 깨진다. test-runner FAIL 이 기대값.
. "$(dirname "$0")/_node_base.sh" "$1"
git checkout -q -b refactor/slug-pattern
python3 - <<'PY'
p='src/slugify.js'; s=open(p).read()
s=s.replace("""    return String(title)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')""","""    return String(title)
        .replace(/[^A-Za-z0-9]+/g, '-')""")
open(p,'w').write(s)
PY
# 입력이 실제로 회귀를 담는지 만들 때 확인한다 (`! cmd` 는 set -e 가 보지 않으므로 if 로 쓴다)
if node --test >/dev/null 2>&1; then echo '회귀 입력인데 테스트가 통과한다' >&2; exit 1; fi
git commit -qam "refactor: simplify slug pattern"
cat > "$1/body.md" <<'MD'
## 변경 내용
- slug 정규식을 한 단계로 줄인다.

## 검증
- 기존 테스트로 확인한다.
MD
echo '{"lanes":{"test-runner":"FAIL"}}' > "$1/expect.json"
