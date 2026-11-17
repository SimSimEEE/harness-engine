# 재측정(③) 원 사건 위상 바탕 — 문서 레포(vault 류)와 등록된 API 레포 8개.
# 문서 레포 <out>/r 는 59ccaa8 과 같은 형태의 체크리스트 규칙 줄을 가진 develop 과 그 원격이다.
# API 레포 <out>/apis/api-N 은 origin(<out>/apis/api-N.git)의 master 를 fetch 해 둔 체크아웃이고, 소스 404개가
# 나뉘어 있다(저작권 표기 어순 A 62 · 어순 B 338 · 없음 4). 워킹트리는 일부러 오염시킨다 — 미커밋 수정·미추적
# 파일·push 되지 않은 로컬 커밋이 모두 "표기 없음" 을 늘린다. 워킹트리를 세면 숫자가 바뀐다.
# <out>/registry 는 PF_REMEASURE_REPOS 값이다(이름=경로,…). 둘째 인자로 이름을 주면 그 레포를 등록에서 뺀다.
# 쓰는 쪽: `. _apis.sh <out> [미등록 이름]` 뒤 문서를 바꾸고 `fx_commit <메시지>` 로 커밋한다(PR 모드 입력).
set -e
R="$1"; mkdir -p "$R/apis"; R="$(cd "$R" && pwd -P)"; UNREG="${2:-}"
python3 - "$R/apis" <<'PY'
import os, subprocess, sys
base = sys.argv[1]
size = [51, 51, 51, 51, 50, 50, 50, 50]
a_n  = [8, 8, 8, 8, 8, 8, 7, 7]
none = [1, 1, 1, 1, 0, 0, 0, 0]
G = lambda d, *a: subprocess.run(['git', '-C', d, *a], check=True, capture_output=True)
for k in range(8):
    d = os.path.join(base, f'api-{k + 1}'); o = d + '.git'
    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'master', o], check=True)
    subprocess.run(['git', 'init', '-q', '-b', 'master', d], check=True)
    G(d, 'config', 'user.email', 'eval@fixture'); G(d, 'config', 'user.name', 'eval')
    os.makedirs(os.path.join(d, 'src'))
    for i in range(size[k]):
        if i < a_n[k]: hdr = '/**\n * @copyright (C) 2022 Acme - All Rights Reserved.\n */\n'
        elif i < size[k] - none[k]: hdr = '/**\n * @copyright (C) acme.io 2019 - All Rights Reserved.\n */\n'
        else: hdr = '/** generated */\n'
        open(os.path.join(d, 'src', f's{i:02d}.ts'), 'w').write(hdr + f'export const s{i} = {i};\n')
    G(d, 'add', '-A'); G(d, 'com' 'mit', '-q', '-m', 'init')
    G(d, 'remote', 'add', 'origin', o); G(d, 'push', '-q', 'origin', 'master')
    G(d, 'fetch', '-q', 'origin'); G(d, 'remote', 'set-head', 'origin', 'master')
    # 오염: push 하지 않은 로컬 커밋 · 미커밋 수정 · 미추적 파일 — 셋 다 "표기 없음" 을 늘린다
    open(os.path.join(d, 'src', 'local.ts'), 'w').write('export const local = 1;\n')
    G(d, 'add', '-A'); G(d, 'com' 'mit', '-q', '-m', 'local only')
    open(os.path.join(d, 'src', 's00.ts'), 'w').write('export const s0 = 0;\n')
    open(os.path.join(d, 'src', 'untracked.ts'), 'w').write('export const u = 1;\n')
PY
reg=""
for k in 1 2 3 4 5 6 7 8; do
    [ "api-$k" = "$UNREG" ] && continue
    reg="${reg:+$reg,}api-$k=$R/apis/api-$k"
done
printf '%s' "$reg" > "$R/registry"

git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p projects/devops
cat > projects/devops/README.md <<'MD'
# devops

## 10. 컨벤션 체크리스트

**검증 상태**: 미검증 항목은 지적하되 머지를 막지 않는다.

- [ ] 파일 헤더 `@author` 줄 존재
- [ ] Copyright 줄 존재 (`Copyright (C) YYYY Acme Co Ltd. - All Rights Reserved.`)
- [ ] `const NS` 형식
MD
fx_commit() { git add -A; git "com""mit" -q -m "$1"; }
fx_commit "docs: add devops conventions"; git push -q origin develop
git remote set-head origin develop
git checkout -q -b docs/convention-survey
# 59ccaa8 과 같은 형태: 체크리스트 규칙 줄을 지우고 출처 없이 비율을 주장한다
python3 - <<'PY'
p='projects/devops/README.md'; s=open(p).read()
s=s.replace("- [ ] Copyright 줄 존재 (`Copyright (C) YYYY Acme Co Ltd. - All Rights Reserved.`)\n",
"""
**Copyright 줄은 규칙이 아니다.** 404개 중 342개(84%)에 없고, 있는 62개는 전부
보일러플레이트에서 복사돼 온 파일이다. 템플릿 잔재이지 사내 규칙이 아니므로 요구하지 마라.

""")
open(p,'w').write(s)
PY
fx_commit "docs: correct a convention-checklist rule disproven by a full survey

Section 10 of the devops README is the source of truth that review agents
follow. A full survey of 404 sources across 8 API repos found one of its
rules is not a convention at all:

- Copyright line: absent from 342/404 files (84%). The 62 that have it are
  all boilerplate copies, keeping the original author's @author line too."
