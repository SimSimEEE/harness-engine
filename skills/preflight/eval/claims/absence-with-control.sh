# 부재 주장 + 같은 패턴의 양성 대조 — 알려진 파일(test/probe.ts)에서 1건이 나온다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

src 에 `console.log` 는 0건이다.

```
$ grep -rn 'console.log' src | wc -l
0
$ grep -rn 'console.log' test | wc -l
1
```
MD
fx_commit "docs: note there is no console logging"
echo '{"warn":{},"info":{},"verified":1,"nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$1/expect.json"
