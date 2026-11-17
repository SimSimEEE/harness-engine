# 허용 목록 밖 명령은 실행하지 않는다 — 참고(info)로만 남는다.
. "$(dirname "$0")/_base.sh" "$1"
cat >> docs/conventions.md <<'MD'

의존성은 12개 중 3개가 낡았다.

```
$ npm outdated --parseable | wc -l
3
```
MD
fx_commit "docs: note outdated deps"
echo '{"warn":{},"info":{"claim/unverifiable":1},"verified":0}' > "$1/expect.json"
