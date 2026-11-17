# 출처 있음 + 숫자 불일치 — 기록된 출력(3)이 낡았고 다시 돌리면 1 이다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

남은 TODO 는 3곳이다.

```
$ grep -rn TODO src | wc -l
3
```
MD
fx_commit "docs: count remaining todos"
echo '{"warn":{"claim/mismatch":1},"info":{},"verified":0,"nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$1/expect.json"
