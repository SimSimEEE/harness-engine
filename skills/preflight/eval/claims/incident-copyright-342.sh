# 실제 사건 재현 (2026-09-09): 재현 명령 없이 "404개 중 342개(84%)" 로 규칙을 지운 변경.
# 문서 줄과 커밋 메시지 줄이 둘 다 출처 없는 비율 주장으로 잡혀야 한다.
. "$(dirname "$0")/_base.sh" "$1"
python3 - <<'PY'
p='docs/conventions.md'; s=open(p).read()
s=s.replace("- [ ] Copyright 줄 존재 (`@copyright (C) … - All Rights Reserved.`)\n",
"\n**Copyright 줄은 규칙이 아니다.** 404개 중 342개(84%)에 없고, 있는 62개는 전부 보일러플레이트 복사본이다.\n")
open(p,'w').write(s)
PY
fx_commit "docs: drop the copyright rule disproven by a survey

- Copyright line: absent from 342/404 files (84%)."
echo '{"warn":{"claim/no-source":2},"info":{},"verified":0}' > "$1/expect.json"
