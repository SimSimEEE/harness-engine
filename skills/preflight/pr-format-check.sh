#!/usr/bin/env bash
# PR 포맷 중 **정규식으로 표현되는 것**만 검사한다. 판단이 필요한 것(본문에 요약·검증
# 성격 섹션이 있는가)은 여기서 하지 않는다 — pr-quality 에이전트 몫이다. 다만 본문 초안이
# **있는가** 는 여기서 정한다 (아래 no-body-is-one-fixed-verdict).
#
# 각 규칙의 blocking 여부는 **실측 위반률**로 정했다 (2026-09-09, 7개 API 레포 머지 PR 162건 +
# 5개 레포 커밋 653건). 위반률이 높은 규칙을 blocking 으로 걸면 정상 작업이 멈춘다:
#   - base 브랜치      : 12/162(7.4%)이 정당한 예외 (릴리즈 develop→master, 스택 PR,
#                        신규 레포 chore/init-repo→master) → **advisory**
#   - 커밋 영어        : API 0~3% vs wiki 34% → API 만 blocking, wiki 는 advisory
#   - 커밋 형식        : 85% 준수. 나머지는 `v<version>` 단독·`Revert "…"`·`Initial commit`
#                        같은 자동/릴리즈 커밋이라 면제 → blocking
#
# 사용: pr-format-check.sh [--json] <repo> [--base <ref>] [--title <제목>] [--body-file <파일>]
set -uo pipefail
JSON=0; [ "${1:-}" = "--json" ] && { JSON=1; shift; }
# --rules: 이 검사기가 낼 수 있는 rule 목록(JSON). 워크플로가 지적 id 어휘로 쓴다 — 정본은 아래 RULES 하나다.
RULES_ONLY=0; [ "${1:-}" = "--rules" ] && { RULES_ONLY=1; set -- /; }
REPO="${1:-}"; shift || true
[ -z "$REPO" ] && { echo "usage: pr-format-check.sh [--json] <repo> [--base <ref>] [--title <t>] [--body-file <f>]" >&2; exit 2; }
BASE=""; TITLE=""; BODYF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2;;
    --title) TITLE="${2:-}"; shift 2;;
    --body-file) BODYF="${2:-}"; shift 2;;
    *) shift;;
  esac
done
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
PF_BRANCH="$(pf_branch "${REPO:-.}")" RULES_ONLY=$RULES_ONLY JSON=$JSON REPO="$REPO" BASE="$BASE" TITLE="$TITLE" BODYF="$BODYF" python3 <<'ZZEND'
import os, re, subprocess, sys, json

REPO=os.environ['REPO']; BASE=os.environ['BASE']
TITLE=os.environ['TITLE']; BODYF=os.environ['BODYF']

def git(*a):
    r=subprocess.run(['git','-C',REPO,*a],capture_output=True,text=True)
    return r.stdout.strip() if r.returncode==0 else ''

# CONTRACT: json-out-is-one-function — 정본은 lib.sh.
# 이 스크립트가 걸리는 이유: `out['repo']` 에 argv 로 받은 **레포 루트 경로**가 실린다.
def _json_out(obj,**kw):
    s=json.dumps(obj,ensure_ascii=False,**kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s=json.dumps(obj,ensure_ascii=True,**kw)
    return s

# CONTRACT: checker-rules-one-place
# 이 목록 밖의 rule 은 add() 가 거부한다 — 워크플로가 이 목록을 지적 id 어휘로 쓰므로, 목록에 없는
# rule 을 내면 그 지적은 스키마에 맞는 rule 을 못 받는다.
RULES=('branch/name','base/branch','base/unresolved','commits/empty','commit/format','commit/language',
       'title/format','title/case','title/language','body/not-provided','body/unreadable')
if os.environ.get('RULES_ONLY')=='1':
    print(_json_out(list(RULES))); sys.exit(0)

findings=[]
def add(rule,msg,blocking=True,fix=''):
    if rule not in RULES: raise ValueError(f'RULES 에 없는 rule: {rule}')
    findings.append({'rule':rule,'message':msg,'blocking':blocking,**({'fix':fix} if fix else {})})

# 레포 종류는 **구조**로 본다 — 이름으로 보면 vault 의 worktree 를 오인한다 (classify.sh 와 같은 판정)
is_wiki=os.path.isfile(os.path.join(REPO,'VAULT_RULES.md'))
kind='wiki' if is_wiki else 'api'
# 기대 base: wiki 는 master. 그 외는 **`origin/develop` 이 있으면 develop, 없으면 그 레포의 기본 브랜치**다.
# develop 이 없는 레포는 기본 브랜치로 PR 을 보낸다. `origin/HEAD` 만 보지 않는 이유: 클론 시점에 굳어
# develop 이 있는데도 master 를 가리키는 레포가 있다.
def _default_branch():
    if git('rev-parse','--verify','--quiet','origin/develop'): return 'develop'
    h=git('symbolic-ref','-q','--short','refs/remotes/origin/HEAD')
    return h.split('/',1)[-1] if h else 'master'
expected_base='master' if is_wiki else _default_branch()

branch=os.environ.get('PF_BRANCH','')   # lib.sh pf_branch
if not BASE:
    for c in (f'origin/{expected_base}','origin/HEAD','origin/develop','origin/master','origin/main'):
        if git('rev-parse','--verify','--quiet',c): BASE=c; break

# ── 브랜치명
if is_wiki:
    # 실측: 머지된 wiki PR 20건 전부 `<type>/<YYYY-MM-DD>-<topic>` 형태였다
    m=re.match(r'^(ingest|docs|chore|fix|feat|refact)/(\d{4}-\d{2}-\d{2})-[a-z0-9][a-z0-9-]*(-\d+)?$', branch)
    if not m:
        add('branch/name', f"wiki 브랜치는 `<type>/<YYYY-MM-DD>-<topic>` 이어야 한다 (현재 `{branch}`)",
            fix="예: docs/2026-09-09-convention-rules")
else:
    # 실측 분포: feat 82 · chore 40 · fix 24 · refact 6 · revert 1 · docs 1 (162건 중)
    if not re.match(r'^(feat|fix|chore|refact|docs|revert)/[a-z0-9][a-z0-9./-]*$', branch):
        add('branch/name', f"API 브랜치는 `<type>/<kebab>` 이어야 한다 (현재 `{branch}`)",
            fix="type: feat|fix|chore|refact|docs|revert")

# ── base — 정당한 예외가 7.4% 라 막지 않고 사유만 남긴다
if BASE:
    short=BASE.split('/')[-1]
    if short!=expected_base:
        add('base/branch', f"이 레포의 기대 base 는 `{expected_base}` 인데 `{short}` 다. "
            f"릴리즈(develop→master)·스택 PR·신규 레포 초기화면 정상이다 — 아니면 고쳐라",
            blocking=False)
else:
    add('base/unresolved', "base 를 해석하지 못했다 (origin fetch 누락?) — 커밋 범위 검사가 생략됐다",
        blocking=False)

# ── 커밋
TYPES=r'(feat|fix|chore|docs|test|refactor|refact|revert|style|perf)'
fmt=re.compile(rf'^{TYPES}(\([^)]+\))?: .+')
rel=re.compile(rf'^v[0-9][0-9a-z.]* - {TYPES}(\([^)]+\))?: .+')  # v0.26.901c - fix: …
exempt=re.compile(r'^(Revert ".*"|v[0-9][0-9a-z.]*|Initial commit)$')
han=re.compile(r'[가-힣]')

if BASE:
    log=git('log','--no-merges','--format=%h%x09%s',f'{BASE}..HEAD')
    lines=[l for l in log.splitlines() if l.strip()]
    if not lines:
        add('commits/empty', f"`{BASE}..HEAD` 에 커밋이 없다 — base 가 틀렸거나 아직 커밋하지 않았다",
            blocking=False)
    for l in lines:
        sha,_,subj=l.partition('\t')
        if exempt.match(subj): continue
        if not (fmt.match(subj) or rel.match(subj)):
            add('commit/format', f"`{sha}` 커밋 제목이 `<type>[(<scope>)]: <설명>` 이 아니다 — {subj[:60]}")
        if han.search(subj):
            # 실측: API 0~3% vs wiki 34%. wiki 에서 막으면 기존 작업 흐름이 멈춘다
            add('commit/language', f"`{sha}` 커밋 제목에 한글이 있다 (커밋은 영어) — {subj[:50]}",
                blocking=not is_wiki)

# ── PR 제목 (주어졌을 때만)
if TITLE:
    # 대소문자를 무시하고 먼저 본다 — `Feat:` 을 "형식 위반" 으로 잡으면 진짜 사유(대문자)가 가려진다
    if not re.match(rf'^{TYPES}(\([^)]+\))?: .+', TITLE, re.I):
        add('title/format', f"PR 제목은 `<type>: <설명>` 이어야 한다 — {TITLE[:60]}")
    elif TITLE[0].isupper():
        add('title/case', f"type 접두는 소문자다 (`{TITLE.split(':')[0]}:` → `{TITLE.split(':')[0].lower()}:`)")
    if not han.search(TITLE):
        add('title/language', f"PR 제목은 한국어다 (커밋과 반대) — {TITLE[:60]}")

# ── PR 본문 — **있는가** 만 여기서 본다. 섹션 판단은 의미 판단이라 pr-quality 에이전트 몫이다.
# CONTRACT: no-body-is-one-fixed-verdict
# 초안이 없을 때의 결과를 에이전트에게 맡기면 실행마다 판정이 갈린다. 그래서 이 자리가
# **고정 warn 하나**를 낸다. 본문은 PR 생성 시점에 쓰는 일이 흔하고, 없는 것을
# 막으면 게이트가 본문 작성 순서를 강제하게 된다 — 막지 않고 미검사 사실만 남긴다.
# 넘겼는데 못 읽는 것은 다르다: 검사를 의도했는데 사고가 났으므로 막는다 (receipt.sh 의
# transcripts-unreadable 과 같은 구분).
body_provided = False
if not BODYF:
    add('body/not-provided', "PR 본문 초안이 넘어오지 않았다 — 본문 섹션은 검사하지 않았다. "
        "`gh pr create --body-file` 로 쓸 파일을 `--body-file` 로 넘기면 검사한다", blocking=False)
else:
    try:
        body_provided = bool(open(BODYF, encoding='utf-8', errors='replace').read().strip())
    except OSError:
        body_provided = None
    if not body_provided:
        add('body/unreadable', f"`--body-file {BODYF}` 를 넘겼는데 " +
            ("읽을 수 없다" if body_provided is None else "비어 있다") +
            " — 본문 검사를 의도했는데 할 수 없다")
        body_provided = False
body_note = ("본문 섹션 판단은 이 검사기 범위 밖이다 (의미 판단 — 에이전트 몫)" if body_provided
             else "본문 초안이 없어 본문 섹션은 아무도 검사하지 않는다")

blocking=[f for f in findings if f['blocking']]
out={'repo':REPO,'kind':kind,'branch':branch,'base':BASE,'expectedBase':expected_base,
     'errorCount':len(blocking),'warnCount':len(findings)-len(blocking),
     'bodyProvided':body_provided,'findings':findings,'notChecked':body_note}
if os.environ.get('JSON')=='1':
    print(_json_out(out,indent=2))
else:
    print(f"{kind} 레포 · 브랜치 {branch} · base {BASE or '(미해석)'}")
    for f in findings:
        print(f"  {'error' if f['blocking'] else 'warn '}  {f['message']}  [{f['rule']}]"
              + (f"\n         → {f['fix']}" if f.get('fix') else ''))
    print(f"\n{len(blocking)} error · {len(findings)-len(blocking)} warning")
    print(f"미검사: {body_note}")
sys.exit(1 if blocking else 0)
ZZEND
