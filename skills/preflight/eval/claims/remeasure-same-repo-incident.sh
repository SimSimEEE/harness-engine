# 재측정(③) 사건 재현 — 같은 레포 위상. Copyright 규칙 줄을 지우며 "404개 중 342개(84%)에 없다" 를 주장하고,
# 어순 A 만 찾는 명령과 그 출력(342)을 출처로 붙인다. 명령을 다시 돌려도 342 라 ②는 출처를 확인으로 센다.
# ③ 의 기대: 불일치(실제 없음 4).
. "$(dirname "$0")/_corpus404.sh" "$1"
python3 - <<'PY'
p='docs/conventions.md'; s=open(p).read()
s=s.replace("- [ ] Copyright 줄 존재 (`@copyright (C) … - All Rights Reserved.`)\n",
"""
**Copyright 줄은 규칙이 아니다.** 404개 중 342개(84%)에 없다.

```
$ grep -L '@copyright (C) 20' src/*.ts | wc -l
342
$ ls src | wc -l
404
```
""")
open(p,'w').write(s)
PY
fx_commit "docs: drop the copyright rule disproven by a survey"
echo '{"warn":{},"info":{},"verified":1,"remeasure":"mismatch","nobox":{"warn":{},"info":{"claim/unverifiable":1},"verified":0}}' > "$R/expect.json"
