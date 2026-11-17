# 출처 있음 + 숫자 일치 — 경고가 없어야 한다. 백분율은 비율에서 파생되므로 출력에 없어도 된다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

src 의 4개 중 4개(100%)가 `@copyright` 를 단다.

```
$ grep -l '@copyright' src/*.ts | wc -l
4
$ ls src | wc -l
4
```
MD
fx_commit "docs: record the copyright survey"
echo '{"warn":{},"info":{},"verified":1,"nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$1/expect.json"
