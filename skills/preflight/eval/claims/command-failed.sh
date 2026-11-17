# 명령이 죽었는데 `2>/dev/null` 로 가려 0 으로 읽은 경우 — 검사기는 stderr 를 되살려 실패로 본다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

lib 에 TODO 는 0건이다.

```
$ grep -rn TODO lib 2>/dev/null | wc -l
0
```
MD
fx_commit "docs: note lib has no todos"
echo '{"warn":{"claim/command-failed":1},"info":{},"verified":0,"nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$1/expect.json"
