#!/usr/bin/env bash
# lane 계약(에이전트 frontmatter 의 `contract:`)이 실제 구성과 맞는지 검사한다.
#
# 선언만 하고 검증하지 않으면 계약이 아니라 주석이다.
# **지금 대조되는 것은 `needs`(classify.sh 의 sequential)와 `network: dev`(qa-runner 하나)뿐이다.**
# `scope` 와 `writes: true` 는 비교 대상이 없어 아직 선언에 머문다 — 넓힐 때는 scope 를
# classify.sh 가 그 lane 에 넘기는 payload 형태와 대조하는 것이 가장 싸다.
# 여기서 보는 것은 **두 자리가 갈리는가**이지 계약 내용의 옳음이 아니다.
set -uo pipefail

# 검사 대상은 **워킹트리**다. `install.sh --link` 에서는 설치본이 레포로의 심링크라 둘이 같지만,
# 복사 모드(클라우드)에서는 `cp -R` 이라 재설치 전에 돌리면 옛 classify.sh 로 검증하고 clean 을 낸다.
# `pwd -P` 는 심링크만 푼다 — `--link` 설치에서는 이것으로 레포에 닿지만, 복사 모드에서는
# 설치본 자신을 가리킨다. 그때는 **레포 체크아웃에서 직접 실행해야** 워킹트리를 본다.
_SD="$(cd "$(dirname "$0")" && pwd -P)"
_ROOT="$(dirname "$(dirname "$_SD")")"
export LC_AGENTS="${LC_AGENTS:-$_ROOT/agents}"
export LC_PREFLIGHT="${LC_PREFLIGHT:-$_ROOT/skills/preflight}"

python3 <<'ZZEND'
import json, os, re, sys, glob

A = os.environ['LC_AGENTS']
P = os.environ['LC_PREFLIGHT']
bad = []

def frontmatter(p):
    t = open(p, errors='ignore').read()
    m = re.match(r'^---\n(.*?)\n---\n', t, re.S)
    return (m.group(1) if m else ''), t

contracts = {}
# LC_AGENTS 는 콜론으로 이은 디렉터리 목록일 수 있다 — 엔진 에이전트 위에 오버레이 에이전트를 얹어 볼 때(뒤가 같은 이름을 덮는다).
_files = {}
for _d in [x for x in A.split(':') if x]:
    for f in sorted(glob.glob(_d + '/*.md')):
        _files[os.path.basename(f)] = f
for f in [_files[k] for k in sorted(_files)]:
    name = os.path.basename(f)[:-3]
    fm, body = frontmatter(f)
    if 'contract:' not in fm:
        bad.append(f'{name}: contract 선언이 없다')
        continue
    c = {}
    for k in ('writes', 'network', 'scope'):
        m = re.search(rf'^\s+{k}:\s*(\S+)', fm, re.M)
        if not m: bad.append(f'{name}: contract.{k} 가 없다')
        else: c[k] = m.group(1)
    m = re.search(r'^\s+needs:\s*\[([^\]]*)\]', fm, re.M)
    c['needs'] = [x.strip() for x in (m.group(1) if m else '').split(',') if x.strip()]
    contracts[name] = (c, body)

# ── needs 는 classify.sh 의 sequential 과 같은 사실을 말해야 한다
cls = open(os.path.join(P, 'classify.sh'), errors='ignore').read()
declared_pairs = {(a, b) for name, (c, _) in contracts.items() for a in c['needs'] for b in [name]}
for a, b in declared_pairs:
    if not re.search(rf"\['{re.escape(a)}',\s*'{re.escape(b)}'\]", cls):
        bad.append(f'{b}.needs 에 {a} 가 있는데 classify.sh 의 sequential 에 그 체인이 없다')
for m in re.finditer(r"sequential\.append\(\['([^']+)',\s*'([^']+)'\]\)", cls):
    a, b = m.group(1), m.group(2)
    if a not in contracts.get(b, ({'needs': []},))[0]['needs']:
        bad.append(f'classify.sh 가 {a}→{b} 를 순차로 두는데 {b}.needs 에 {a} 가 없다')

# ── scope 는 열거다. 값을 대조하지는 않지만 **오타는 잡는다** (지금은 무엇을 써도 통과했다).
SCOPES = {'intent', 'files', 'branch', 'report', 'plan'}
for n, (c, _) in contracts.items():
    sc = c.get('scope')
    if sc and sc not in SCOPES:
        bad.append(f'{n}: scope 가 열거 밖이다 — {sc} (허용: {", ".join(sorted(SCOPES))})')

# ── network: dev 는 qa-runner 하나여야 한다. 늘어나면 prod 금지 규약을 다시 봐야 한다
netdev = sorted(n for n, (c, _) in contracts.items() if c.get('network') == 'dev')
if netdev != ['qa-runner']:
    bad.append(f'network: dev 인 lane 이 {netdev} 다 — qa-runner 하나여야 한다')

# ── writes: false 는 본문이 읽기 전용을 선언해야 뒷받침된다.
# 쓰기 어휘를 그냥 찾으면 **금지문**("파일을 수정하지 마라")이 걸린다 — 실제로 그랬다.
# 그래서 금지 표지가 없는 줄에서만 쓰기 지시로 본다.
NEG = re.compile(r'마라|않는다|금지|아니다|말고')
# 백틱 git 언급만으로는 쓰기 **지시**가 아니다 — `\`git add\` 이후 … 호출된다` 처럼
# 호출 시점을 서술하는 줄이 걸렸다. 명령형이 붙은 경우만 지시로 본다.
WRITE_HINT = re.compile(r'파일을 (수정|생성)하|커밋해라|커밋한다|`git (add|commit)`[^\n]{0,30}?(해라|하라|실행한다)')
# 선언 어미가 한 가지가 아니다 — `쓰지 마라`·`쓰지 않는다`·`읽기 전용` 이 다 쓰인다
READONLY = re.compile(r'읽기 전용|(수정|커밋|쓰지)\s*(하지)?\s*(마라|않는다)|파일은 쓰지')
for n, (c, body) in contracts.items():
    if c.get('writes') != 'false':
        continue
    offend = [l for l in body.splitlines()
              if WRITE_HINT.search(l) and not NEG.search(l)]
    # CONTRACT: readonly-and-write-are-independent
    # 두 조건은 독립이다. 하나로 묶으면(`offend and not READONLY`) 선언이 있는 순간
    # 쓰기 지시를 아예 안 보게 되어, 검사기가 잡겠다고 적어 둔 바로 그 모순
    # (읽기 전용 선언 + 쓰기 지시)이 구조적으로 검출 불가가 된다. 실측으로 확인한 구멍이다.
    if not READONLY.search(body):
        bad.append(f'{n}: writes=false 인데 본문에 읽기 전용 선언이 없다')
    if offend:
        bad.append(f'{n}: writes=false 인데 본문이 쓰기를 지시한다 — {offend[0].strip()[:50]}')

if bad:
    print('lane 계약 불일치:')
    for b in bad: print('  -', b)
    sys.exit(1)
print(f'lane contract: clean · {len(contracts)} lanes')
ZZEND
