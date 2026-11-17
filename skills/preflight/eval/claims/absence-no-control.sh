# 부재 주장 + 양성 대조 없음 — 0건이 '없어서' 인지 '패턴·경로가 틀려서' 인지 가를 수 없다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

src 에 `console.log` 는 0건이다.

```
$ grep -rn 'console.log' src | wc -l
0
```
MD
fx_commit "docs: note there is no console logging"
echo '{"warn":{"claim/absence-no-control":1},"info":{},"verified":0,"nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$1/expect.json"
