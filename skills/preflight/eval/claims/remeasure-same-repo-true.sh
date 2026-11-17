# 재측정(③) 참인 대조 — 같은 코퍼스에서 규칙 줄을 지우며 참인 수치 "404개 중 4개에 없다" 를 주장한다.
# 출처가 없으므로 ②는 출처 없음을 낸다(독립성 검사가 걸리지 않는다). ③ 의 기대: 불일치 없음.
. "$(dirname "$0")/_corpus404.sh" "$1"
python3 - <<'PY'
p='docs/conventions.md'; s=open(p).read()
s=s.replace("- [ ] Copyright 줄 존재 (`@copyright (C) … - All Rights Reserved.`)\n",
"\n**Copyright 줄은 체크리스트에서 뺀다.** 404개 중 4개에 없다 — 생성 파일뿐이라 따로 적는다.\n")
open(p,'w').write(s)
PY
fx_commit "docs: move the copyright rule out of the checklist"
echo '{"warn":{"claim/no-source":1},"info":{},"verified":0,"remeasure":"no-mismatch"}' > "$R/expect.json"
