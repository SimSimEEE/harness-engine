#!/bin/bash
# preflight receipt — 게이트 결과를 .git/ 안에 남기고 검증한다 (커밋되지 않음).
#
# 신뢰 경계: git 은 **인덱스**를 커밋하고, lane 은 그 인덱스를 푼 **스냅숏**을 읽는다(#8).
# 그래서 receipt 는 **인덱스 트리**에 묶는다 — 분류가 본 트리 = 검사한 트리 = 커밋될 트리.
# 워킹트리에만 있는 차이(미스테이징 수정·미추적 파일·부분 스테이징)는 커밋되지 않으므로 기록을
# 막지 않고 목록만 보여 준다(D4). 예외는 `--qa` 라운드다 — dev 배포는 워킹트리를 빌드하므로,
# 커밋될 경로만큼은 워킹트리 = 인덱스여야 QA 결과가 커밋될 내용의 것이다(D5).
#
# usage:
#   receipt.sh record commit|pr <dir> [lanes-json|@file] [classify-json|@file] [transcripts-dir]
#     게이트 결과 기록 (스테이징 후). transcripts-dir 을 넘기면 전사 기반 검사 셋이 켜진다
#     (no-lane-evidence · concealed-promotion · sequence-violated). 넘겼는데 못 읽으면 거부한다.
#     classify 를 생략하면 <gitdir>/claude-preflight.classify.json 을 자동으로 읽는다.
#   receipt.sh verify commit|pr <dir>                검증 (exit 0 통과, 1 차단)
#   receipt.sh report pr <dir> [branch]              머지 보고 — 계획 claim 닫힘 · QA 상태 (판정하지 않는다)
#
# lanes-json 예: '{"secret-scanner":"PASS","crossrepo-impact":{"status":"SKIPPED","reason":"no-public-type-surface-change"}}'
#   허용 상태: PASS / SKIPPED / NOT_APPLICABLE
#   차단 상태: FAIL / ERROR / TIMEOUT  ← 에이전트가 죽어도 게이트가 열리지 않게 (fail-closed)
#   면제(waiver): WARNING 을 사람이 승인해 통과시킬 때는 상태를 PASS 로 바꾸되
#     {"status":"PASS","waived":true,"originalStatus":"WARNING","reason":"…"} 로 남긴다.
#     originalStatus/reason 이 없으면 기록을 거부한다 — 승인 사실이 사라지면 면제가 아니라 은폐다.
#   충돌 상태: 같은 scope 에 PASS 와 FAIL 이 동시에 나오면 CONFLICT 로 차단한다.
#             LLM 중재자를 두지 않는다 — 판정이 갈렸다는 사실 자체가 사람이 볼 신호다.
#
# classify-json 예: '{"selected":{"code-reviewer":["src/api/orders-api.ts"]},
#                     "notSelected":{"vault-sync":"no-linked-repo"}}'
#   왜 그 lane 을 골랐는지/안 골랐는지를 남긴다 — "왜 crossrepo 가 안 돌았지?" 를 역추적하기 위함.
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cmd="${1:-}"; kind="${2:-}"; dir="${3:-$PWD}"; lanes="${4:-}"; classify="${5:-}"; transcripts="${6:-}"

gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || { echo "not a git repo"; exit 1; }
receipt="$gitdir/claude-preflight.json"
# 로그의 repo 는 호출 인자가 아니라 해석된 레포 루트여야 한다 — "." 로 부르면 집계가 갈린다.
repo_top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")

# 인자가 @<path> 면 파일에서 읽는다 — 워크플로 결과 JSON 을 쉘 인자로 밀어 넣다가
# 따옴표가 깨지는 사고를 막는다.
_read_arg() { case "${1:-}" in @*) cat "${1#@}" 2>/dev/null ;; *) printf '%s' "${1:-}" ;; esac; }
lanes=$(_read_arg "$lanes")
classify=$(_read_arg "$classify")
# classify 를 안 넘기면 classify.sh 가 남긴 artifact 를 자동으로 읽는다.
# 분류 근거는 게이트 기록의 일부여야지, 넘겨주는 걸 잊었다고 사라지면 안 된다.
if [ -z "$classify" ] && [ -f "$gitdir/claude-preflight.classify.json" ]; then
    classify=$(cat "$gitdir/claude-preflight.classify.json")
fi

# 커밋될 내용 그 자체. `git write-tree` 는 인덱스를 트리 객체로 굳혀 해시를 준다.
index_tree() { git -C "$dir" write-tree 2>/dev/null; }

case "$cmd" in
record)
    it=$(index_tree)
    # 계획 참조 — 있으면 planId, 없으면 "없음" 을 명시적으로 남긴다.
    # 침묵은 기록이 아니다: 나중에 "계획 없이 갔나?" 를 역추적할 수 있어야 한다.
    # CONTRACT: plan-resolve-is-one-function — 분류기와 같은 규칙으로 찾는다 (plan.sh).
    planjson=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan.sh" resolve "$dir" 2>/dev/null) || planjson=''
    planqa=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan.sh" qa "$dir" 2>/dev/null) || planqa=''
    planclaims=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan.sh" claims "$dir" 2>/dev/null) || planclaims=''
    # QA 기록은 계획 포인터와 같은 자리(worktree 가 공유하는 common dir)에 둔다 — 커밋한 worktree 와
    # PR 을 여는 체크아웃이 달라도 같은 기록을 본다.
    common_dir=$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || common_dir=''
    # `--verify -q` 가 아니면 커밋 없는 레포에서 문자열 'HEAD' 가 그대로 담긴다
    # (rev-parse 는 해석 못 한 인자를 stdout 에 뱉는다) — sha 아닌 값이 결속 기준이 된다.
    head=$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null || echo '')
    branch=$(pf_branch "$dir")
    ts=$(date +%s)
    engver=$(pf_engine_version)
    KIND="$kind" OKMODES="$(pf_ok_modes "$kind")" IT="$it" HEAD_SHA="$head" BRANCH="$branch" TS="$ts" R="$receipt" \
    LANES="$lanes" CLASSIFY="$classify" PLANJSON="$planjson" PLANQA="$planqa" PLANCLAIMS="$planclaims" COMMON_DIR="$common_dir" DIR="$dir" REPO_TOP="$repo_top" TRANSCRIPTS="$transcripts" ENGINE_VER="$engver" \
    PF_CATS="$(pf_category_roots)" python3 - <<'PY'
import json, os, re, subprocess, sys

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. JSON 을 쓰는 자리는 전부 여기를 지난다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

# 사람에게 보여줄 경로. 인코딩 불가 바이트는 이스케이프해 **표시가 죽지 않게** 한다.
def _disp(s):
    return s.encode('utf-8', 'backslashreplace').decode('utf-8')

def _parse(name):
    raw = os.environ.get(name) or ''
    if not raw: return {}
    try: return json.loads(raw)
    except Exception as e: print(f"{name.lower()}-json 파싱 실패: {e}"); sys.exit(1)
def _log(event, outcome, **kw):
    # 실패해도 조용히 넘어간다. 로그는 게이트의 판정에 절대 개입하지 않는다.
    try:
        rec = {'ts': int(os.environ.get('TS') or 0), 'event': event, 'outcome': outcome,
               'kind': os.environ.get('KIND'), 'repo': os.environ.get('REPO_TOP') or os.environ.get('DIR'),
               'branch': os.environ.get('BRANCH'), 'engineVersion': os.environ.get('ENGINE_VER') or None}
        rec.update(kw)
        path = os.path.expanduser(os.environ.get('PF_LOG') or '~/.claude/preflight-log.jsonl')
        with open(path, 'a') as f:
            f.write(_json_out(rec) + '\n')
    except Exception:
        pass

lanes = _parse('LANES')
classify = _parse('CLASSIFY')

OK = {'PASS', 'SKIPPED', 'NOT_APPLICABLE'}
bad = []
seen = {}
for name, v in lanes.items():
    st = v.get('status') if isinstance(v, dict) else v
    scope = v.get('scope') if isinstance(v, dict) else None
    if scope:
        prev = seen.get(scope)
        if prev is not None and (prev == 'PASS') != (st == 'PASS'):
            bad.append(f"CONFLICT[{scope}] {name}={st} vs {prev}")
        seen[scope] = st
    if st not in OK: bad.append(f"{name}={st}")
    # WARNING 을 사람이 승인해 통과시킨 경우, 무엇을 승인했는지가 기록에 남아야 한다.
    # 승인 흔적 없는 PASS 로 덮어쓰면 "원래 WARNING 이었다" 는 사실이 사라진다.
    if isinstance(v, dict) and v.get('waived'):
        if not v.get('originalStatus') or not v.get('reason'):
            bad.append(f"{name}: waived 인데 originalStatus/reason 이 없다")
if bad:
    print("게이트 기록 거부 — 통과하지 못한 lane: " + ', '.join(bad))
    print("  PASS/SKIPPED/NOT_APPLICABLE 만 허용된다 (FAIL·ERROR·TIMEOUT 은 fail-closed)")
    _log('record', 'refused', reason='lane-status', detail=bad)
    sys.exit(1)

# 분류가 본 인덱스와 지금 인덱스가 같은가 (#8 R5·I5). 커밋될 내용의 결속은 이것 하나다 — 분류 뒤의
#  `git add`(다른 세션 것 포함)·`update-index`·`add -p`·인덱스까지 치우는 `git stash` 를 전부 잡는다.
#  워킹트리만 바뀌는 조작(미스테이징 수정·미추적 파일·`stash push -u -- <경로>`·`--keep-index`)은
#  커밋될 내용을 바꾸지 않으므로 여기서도 어디서도 거부하지 않는다(#8 D4) — `--qa` 라운드는 아래 예외.
#  값이 없는 분류는 여기서 건너뛰고 아래 스키마 검사가 거부한다.
_it_decl = classify.get('indexTree') if isinstance(classify, dict) else None
if os.environ.get('KIND') == 'commit' and _it_decl and _it_decl != os.environ.get('IT'):
    _log('record', 'refused', reason='index-changed',
         declared=_it_decl[:12], current=(os.environ.get('IT') or '')[:12])
    print("게이트 기록 거부 — 분류 이후 커밋될 내용(인덱스)이 바뀌었다")
    print(f"    분류 시점 {_it_decl[:12]} != 현재 {(os.environ.get('IT') or '')[:12]}")
    print("  다른 세션의 `git add` 일 수도 있다. 스테이징을 확인하고 classify.sh 부터 다시 실행해라.")
    sys.exit(1)

# 인덱스와 워킹트리 내용이 다른 추적 경로 (#8 D4). 막지 않고 보여 준다 — 고친 뒤 `git add` 를 잊은
#  경우를 알릴 곳이 여기뿐이다. `--qa` 라운드에서는 이 목록 중 커밋될 경로가 있으면 거부한다(D5).
#  미추적 파일은 담지 않는다(D2 — 분류 artifact 의 untrackedCount 가 개수만 싣는다). 경로는 `-z` 로
#  받는다(lib.sh CONTRACT: git-paths-read-with-z). 표시 전용이고 영수증·로그에는 개수만 남긴다 —
#  남의 경로가 게이트 기록에 들어가지 않는다(#8 I2). 못 구하면 None 이다.
def _git_paths(*a):
    try:
        p = subprocess.run(['git', '-C', os.environ['DIR'], *a], capture_output=True)
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return sorted({x.decode('utf-8', 'surrogateescape') for x in p.stdout.split(b'\0') if x})
wt_diff = (_git_paths('diff', '--no-renames', '--name-only', '-z')   # worktree-listing-ok: 표시 전용(D4)·--qa 대조(D5)
           if os.environ.get('KIND') == 'commit' else [])

# ── 절차 검증 (Procedure Verification)
# 여기까지 온 lanes-json 이 **결과적으로** 통과인지는 위에서 봤다. 이제 그 결과가
# **분류가 요구한 절차를 실제로 밟은 결과인가** 를 본다. 워크플로를 돌리지 않고 손으로
# lanes-json 을 지어내도 통과하면 게이트는 성실성에 기대는 장치가 된다 — 그러면 안 된다.
if not classify:
    print("게이트 기록 거부 — 분류 근거가 없다")
    print("  classify.sh 를 먼저 실행해라. 무엇을 검사해야 했는지 모르면 무엇을 안 했는지도 모른다.")
    _log('record', 'refused', reason='no-classification')
    sys.exit(1)

cd_decl = classify.get('contentDigest')
# 검사 대상(contentDigest)은 다시 구하지 않는다 — 커밋 모드는 위 index-changed 가, PR 모드
#  (base..HEAD)는 아래 stale-head 가 같은 것을 본다. 분류 뒤 워킹트리 변화는 결속 대상이 아니다(#8 D4):
#  lane 은 스냅숏(인덱스 트리)을 읽었고, 커밋되는 것도 그 트리다.

# 분류 artifact 가 온전한가. 아래 세 결속(branch·mode·head)과 위 내용 결속(indexTree)은
#  전부 **값 truthiness** 로 걸려 있어, 값이 비면 조용히 꺼진다 — 키 존재만 보면
#  `{"mode":"","branch":"","hasHead":false}` 가 셋을 전부 통과한다. classify.sh 산출물은 전부 채운다.
#  contentDigest 는 record 가 대조하지 않는다(위 주석). 분류 식별자·라운드 집계·영수증의 근거라
#  스키마 필드로만 요구한다 — 검사 대상의 결속은 커밋 모드 index-changed, PR 모드 stale-head 가 맡는다.
# **빈 값을 일괄 거부하지는 않는다** — 커밋이 없는 레포는 branch·head 가 정상적으로 비고
#  (`git init` 직후 classify 는 branch='' head='' hasHead=false), 그걸 막으면 첫 커밋이
#  막힌다. 그래서 축마다 **런타임 사실**과 대조한다: 현재 값이 있는데 분류가 비었으면 거부.
#  mode 는 호출자가 늘 주므로 무조건 요구한다.
#  내용 결속 값(과 contentDigest)도 무조건 요구한다 — 키를 지우거나 비우면 그 결속만 골라 꺼진다. classify.sh 는
#  빈 레포·깨끗한 트리에서도 빈 입력의 해시를 채우므로 빈 레포 예외가 필요 없다. indexTree 는
#  커밋 모드 분류에만 있다(PR 모드는 인덱스를 보지 않는다).
#  `qa` 표시도 불리언으로 요구한다 — 키를 지우면 아래 `--qa` 예외가 꺼진다(#8 R19).
_bad = [] if classify.get('mode') else ['mode']
for _k in ('contentDigest',) + (('indexTree',) if classify.get('mode') != 'pr' else ()):
    if not classify.get(_k):
        _bad.append(_k)
if 'hasHead' not in classify:
    _bad.append('hasHead')
if not isinstance(classify.get('qa'), bool):
    _bad.append('qa')
if _bad:
    print(f"게이트 기록 거부 — 분류 artifact 가 온전하지 않다 (빈 필드: {', '.join(_bad)})")
    print("  classify.sh 부터 게이트를 다시 돌려라.")
    _log('record', 'refused', reason='classify-schema-old', missing=_bad)
    sys.exit(1)

# 기준은 `HEAD_SHA` 다 — 커밋이 있으면 branch·head 가 반드시 채워져야 한다.
# BRANCH 로 정하지 않는다: 커밋이 없는 레포에서는 결속할 head 가 없어 branch 를 요구할 근거도 없다.
# (브랜치 이름은 양쪽 다 lib.sh pf_branch 로 구하므로 첫 커밋 전에도 같은 값이 나온다.)
cur_head = os.environ.get('HEAD_SHA') or ''
cls_branch = classify.get('branch')
cur_branch = os.environ.get('BRANCH') or ''
# 분류가 **이 브랜치**의 것인가. 내용 다이제스트는 브랜치를 담지 않는다 — 같은 변경을 담은 두
#  브랜치나, 변경이 없는 분류(빈 입력의 해시)는 서로 구분되지 않는다. #8 전에는 PR 모드가 늘 빈
#  해시였다(실측: 기록 98건 중 20건이 빈-트리 해시).
if cur_head and not cls_branch:
    print("게이트 기록 거부 — 분류 artifact 에 branch 가 없다 (구 artifact 이거나 지어낸 분류)")
    print("  classify.sh 부터 게이트를 다시 돌려라.")
    _log('record', 'refused', reason='classify-schema-old', missing=['branch'])
    sys.exit(1)
if cls_branch and cur_branch and cls_branch != cur_branch:
    print(f"게이트 기록 거부 — 분류가 다른 브랜치의 것이다: {cls_branch} != {cur_branch}")
    print("  classify.sh 를 이 브랜치에서 다시 실행해라.")
    _log('record', 'refused', reason='branch-mismatch',
         classified=cls_branch, current=cur_branch)
    sys.exit(1)

# 분류가 **이 모드**의 것인가. artifact 경로가 모드와 무관하게 하나라, commit 분류가 그대로
#  남아 있으면 `record pr` 이 그것으로 통과한다. 그러면 PR 전용 lane(pr-quality·vault-sync)이
#  selected 에 없어 verify 의 필수 집합에서 통째로 빠지고, secret-scanner 의 PR diffRange 도
#  없어 diff 가 비어 보인다 — PR 게이트가 통째로 우회된다. verify 는 영수증에 저장된 분류에서
#  필수 lane 을 뽑으므로 거기서는 못 잡는다(자기일관적으로 통과한다). 여기서 막아야 한다.
#  **`all` 은 PR 을 대신하지 못한다.** classify.sh 의 base 해석은 `MODE == 'pr'` 에만 걸려 있어
#  `all` 분류는 `base.ref` 가 비고 `diffFrom` 이 HEAD 다(실측) — 커밋 뒤 워킹트리가 깨끗하면
#  변경이 0건으로 보인다. 그래서 `all` 관용은 커밋 모드에만 둔다.
cls_mode = classify.get('mode')
_kind = os.environ.get('KIND') or ''
_ok_modes = (os.environ.get('OKMODES') or '').split()   # CONTRACT: ok-modes-is-one-function (lib.sh)
if cls_mode and _kind and cls_mode not in _ok_modes:
    print(f"게이트 기록 거부 — 분류가 다른 모드의 것이다: {cls_mode} != {_kind}")
    print(f"  classify.sh <repo> {_kind} 로 다시 실행해라.")
    _log('record', 'refused', reason='mode-mismatch',
         classified=cls_mode, current=_kind)
    sys.exit(1)

# 분류가 **이 커밋** 위의 것인가. 커밋 모드 contentDigest 는 HEAD 대 인덱스의 차이라, `--amend` 처럼
# 커밋이 바뀌어도 차이가 같으면 같은 값이 나온다. PR 모드(base..HEAD)는 커밋이 바뀌면 값도
# 바뀌지만, record 는 그것을 다시 구하지 않으므로 커밋 결속은 이 검사가 맡는다.
#
# CONTRACT: 이 검사는 **브랜치 검사 뒤**에 와야 한다. 앞에 두면 브랜치 전환이 stale-head 로
#  잡혀 사유 코드가 섞이고, 이 레포는 그 코드를 세어 판단 근거로 쓴다
#  (아래 CONTRACT: no-gate-run-is-its-own-reason 참고).
# CONTRACT: 이걸 빼면 amend 이전 실행의 lane 결과가 그대로 기록된다. 훅(verify)은 커밋
#  경로에서 head 를 읽지 않고 indexTree 만 보므로(아래 `kind == 'commit'` 분기) 그 뒤에는
#  잡히지 않는다 — 검사한 내용과 기록이 갈린 채 통과한다. 여기서 막아야 하는 이유다.
cls_head = classify.get('head')
# 판정은 분류가 신고한 `hasHead` 가 아니라 **런타임 사실**에 건다. 신고값을 믿으면
#  `hasHead:false` 를 적어 넣는 것만으로 커밋이 있는 레포에서도 이 결속을 끌 수 있다.
if cur_head and not cls_head:
    print("게이트 기록 거부 — 분류 artifact 에 head 가 없다 (구 artifact 이거나 지어낸 분류)")
    print("  classify.sh 부터 게이트를 다시 돌려라.")
    _log('record', 'refused', reason='classify-schema-old', missing=['head'])
    sys.exit(1)
if cls_head and cur_head and cls_head != cur_head:
    print("게이트 기록 거부 — 분류 이후 커밋이 바뀌었다")
    print(f"    분류 시점 {cls_head[:12]} != 현재 {cur_head[:12]}")
    print("  검사한 커밋과 기록될 커밋이 다르다. classify.sh 부터 다시 실행해라.")
    _log('record', 'refused', reason='stale-head',
         declared=(cls_head or '')[:12], current=(cur_head or '')[:12])
    sys.exit(1)

# `--qa` 라운드의 예외 (#8 R19·D5). dev 배포는 워킹트리를 빌드하므로, QA 결과(인덱스 트리에 묶인다)가
#  거짓이 아니려면 **커밋될 경로**만큼은 워킹트리 = 인덱스여야 한다. 커밋되지 않는 경로(남의 미스테이징
#  수정·미추적 파일)는 요구하지 않는다 — 요구하면 이슈 #8 이 `--qa` 라운드에서 재발한다.
#  `--qa` 여부는 record 인자가 아니라 분류 artifact 에서 읽는다. 표시를 지우면 위 스키마 검사가,
#  qa lane 이 골라졌는데 표시만 끄면 여기서 거부한다 — qa lane 은 `--qa` 분류에서만 생긴다.
_qa_lane = ('qa-runner' in (classify.get('selected') or {})
            or any('qa-runner' in (c or []) for c in (classify.get('sequential') or []))
            or str((classify.get('notSelected') or {}).get('qa-runner') or '').startswith('qa-skipped'))
if _qa_lane and classify.get('qa') is not True:
    print("게이트 기록 거부 — 분류 artifact 의 qa 표시가 qa lane 과 어긋난다 (지어낸 분류이거나 고친 분류)")
    print("  classify.sh 부터 게이트를 다시 돌려라.")
    _log('record', 'refused', reason='classify-schema-old', missing=['qa'])
    sys.exit(1)
if classify.get('qa') is True and os.environ.get('KIND') == 'commit':
    _staged = (_git_paths('diff', '--cached', '--no-renames', '--name-only', '-z', 'HEAD') if cur_head
               else _git_paths('ls-files', '-z'))
    _qa_bad = None if (_staged is None or wt_diff is None) else sorted(set(_staged) & set(wt_diff))
    if _qa_bad is None or _qa_bad:
        _log('record', 'refused', reason='qa-worktree-differs',
             count=(len(_qa_bad) if _qa_bad is not None else None))
        if _qa_bad is None:
            print("게이트 기록 거부 — `--qa` 라운드인데 인덱스·워킹트리 차이를 구하지 못했다")
        else:
            print("게이트 기록 거부 — `--qa` 라운드인데 커밋될 경로의 워킹트리 내용이 인덱스와 다르다:")
            for f in _qa_bad[:20]: print(f"    {_disp(f)}")
            if len(_qa_bad) > 20: print(f"    … 외 {len(_qa_bad) - 20}개")
        print("  dev 배포는 워킹트리를 빌드한다 — QA 가 본 것과 커밋될 것이 다르다.")
        print("  `git add` 로 맞추거나 워킹트리를 인덱스로 되돌린 뒤, 배포·classify.sh --qa 부터 다시 실행해라.")
        sys.exit(1)

# 이 검사들(브랜치·모드·head)보다 **뒤**에 둔다. 앞에 두면 PR 전용인 이 검사가 먼저 걸려
# 분류가 어긋난 사건이 vault-unregistered 로 기록된다 — 사유 코드가 섞인다.
# vault 연동은 작업이 **랜딩할 때** 유지되어야 한다. 등록되지 않은 레포는 추적 노트 자체가
# 없어 드리프트를 감지할 대상조차 없다 — 그래서 감지가 아니라 등록을 먼저 요구한다.
# 등록 여부는 디렉터리와 frontmatter 로 확정되는 사실이므로 에이전트가 아니라 여기서 판정한다.
if os.environ.get('KIND') == 'pr':
    vl = classify.get('vaultLink') or {}
    # UNKNOWN 은 두 종류다. origin 미설정·vault 경로 미해결처럼 **등록 대상을 특정할 수 없는**
    # 경우는 막지 않는다(로컬 전용 레포가 영원히 막힌다). 반면 조회가 **죽은** 경우는 미등록인지
    # 아닌지 모르는 것이므로 막는다 — 모른다는 것을 등록됨으로 읽으면 통제가 사라진다.
    # **통과 목록으로 판정한다.** 거부 목록으로 두면 새 status 가 조용히 통과한다.
    #   REGISTERED 추적 중 · SELF vault 자신 · EXEMPT 추적 안 하기로 결정
    #   NOT_APPLICABLE 조회 비적용 — 등록 조회는 카테고리 규칙이고 이 레포의 카테고리에는 없다(classify.sh vault_link)
    #   UNKNOWN/UNRESOLVED 등록 대상을 특정할 수 없음(로컬 전용 레포를 영영 막지 않는다)
    _vl_ok = (vl.get('status') in ('REGISTERED', 'SELF', 'EXEMPT', 'NOT_APPLICABLE')
              or (vl.get('status') == 'UNKNOWN' and vl.get('lookup') != 'FAILED'))
    if not _vl_ok:
        print(f"게이트 기록 거부 — 이 레포가 vault 에 연결되지 않았다: {vl.get('repo') or '(미상)'}")
        print(f"  {vl.get('reason') or ''}")
        print("  github-project-link 스킬로 먼저 등록한 뒤 PR 게이트를 다시 돌려라.")
        print("  추적 대상이 아니면 config.json 의 vaultExempt 에 슬러그를 넣어 제외로 기록해라.")
        print("  (커밋 게이트는 영향받지 않는다 — 등록은 랜딩 시점의 요건이다)")
        _log('record', 'refused', reason='vault-unregistered', repoSlug=vl.get('repo'))
        sys.exit(1)

    # 승인 뒤 claim 이 바뀐 계획으로는 랜딩하지 않는다 (docs/cycle-trace.md § 4-3).
    # 승인된 약속과 지금 추적 기준이 다르면, 추적이 PASS 여도 "승인받은 것을 했다" 가 성립하지 않는다.
    # 분류 시점이 아니라 **지금** 결속된 계획으로 본다 — 분류 뒤에 계획을 고쳐도 잡는다.
    # 미승인(NONE)은 막지 않는다 — tracer 보고에 표시만 한다. 승인을 강제하면 계획 자체를 안 쓴다.
    try:
        _pl = json.loads(os.environ.get('PLANJSON') or '{}')
    except Exception:
        _pl = {}
    if _pl.get('status') == 'FOUND' and _pl.get('approval') == 'CHANGED':
        print(f"게이트 기록 거부 — 승인 뒤 계획의 claim 이 바뀌었다: {_pl.get('planId')}")
        print(f"  계획: {_pl.get('path')}")
        print("  승인된 약속과 지금 추적 기준이 다르다. /plan 으로 새 planId 를 만들어 다시 승인받아라")
        print("  (같은 planId 로는 다시 넣을 수 없다 — ID 계약).")
        _log('record', 'refused', reason='plan-changed', planId=_pl.get('planId'))
        sys.exit(1)

selected = classify.get('selected') or {}
required = list(selected)
for chain in (classify.get('sequential') or []):
    required += [l for l in chain if l not in required]
missing = [l for l in required if l not in lanes]

# CONTRACT: no-gate-run-is-its-own-reason
# 보고된 lane 이 **하나도** 없으면 '일부 누락' 이 아니라 워크플로를 안 돌린 것이다.
# 조건은 `not lanes` 다 — `missing == required` 로 두면 옛 lane 이름으로 보고한 경우까지
# 같은 칸에 들어가 사유가 다시 합쳐진다.
# 실측(2026-09-11): record 거부 18건 중 incomplete-lanes 5건, **5건 전부** missing==required.
# 가르는 근거는 그 **형태**다 — 전무 아니면 전부이고 부분 누락이 0건이다.
# 재현: preflight-log.jsonl 에서 event=record·outcome=refused 를 reason 별로 센다.
if required and not lanes:
    print("게이트 기록 거부 — 검사를 돌리지 않았다. lane 결과가 하나도 없다.")
    print(f"  분류가 요구한 lane: {', '.join(sorted(required))}")
    print("  classify.sh 는 **무엇을 검사할지 정할 뿐**이고 검사는 워크플로가 한다.")
    print("  순서: classify.sh → preflight.js(Workflow) → record")
    print("  verify 가 막았다면 record 만 다시 부르지 말고 **분류부터** 다시 돌려라.")
    _log('record', 'refused', reason='no-gate-run', required=sorted(required), reported=[])
    sys.exit(1)
if missing:
    print("게이트 기록 거부 — 분류가 요구한 lane 이 기록되지 않았다: " + ', '.join(missing))
    print(f"  선택된 lane: {', '.join(required)}")
    print("  결과가 없는 lane 은 통과가 아니라 미실행이다. 게이트를 다시 돌려라.")
    # reported 를 남겨야 '전무'와 '엉뚱한 lane 보고' 를 사후에 가를 수 있다 —
    # 기존 5건은 lanes 를 안 남겨 지금도 판별 불가다.
    _log('record', 'refused', reason='incomplete-lanes', missing=missing,
         required=sorted(required), reported=sorted(lanes))
    sys.exit(1)

# ── 전사 기반 실행 검증 ───────────────────────────────────────────────
# 보고(self-report)가 아니라 **전사**를 본다 — 코드가 관찰한 실행 사실.
# 최소 증거 = 명령 + 시각 + 종료 상태 + 대상. 출력 내용의 정당성은 범위 밖.
_RANK = {'PASS': 1, 'NOT_APPLICABLE': 1, 'SKIPPED': 1, 'WARNING': 2, 'FAIL': 3, 'ERROR': 3}


# CONTRACT: qa-execution-is-counted-not-claimed
# **주장을 좁힌다.** "요청을 보냈나" 는 명령 문자열로 결정할 수 없다 — 클라이언트를 열거하면
# `RES=$(…)`·래퍼·루프·서브셸·wget 이 빠지고, 이름을 늘릴수록 같은 구멍으로 돌아온다.
# 결정 가능한 것만 센다: **URL 이 실린 실행 명령**. 위 형태는 전부 URL 을 갖는다.
# 재현: ~/.claude/projects/**/agent-*.jsonl 을 이 파일의 _LIVE·_HEREDOC 과 아래와 같은 귀속
# (수락된 최종 StructuredOutput.lane)으로 센다. 실측 2026-09-11, 전사 2,622건 · 명령 5,603건:
#   qa-runner 87건 · live==0 2건(그중 PASS 1건) · 열거(curl|awscurl|wget) 규칙과 불일치 0건
#   오탐 6건 — URL 이 실린 grep·echo. 그것만으로 통과한 전사는 0/87
#   미탐 12건 — URL 이 히어독 본문에만. 전부 `cat > f <<EOF` 쓰기라 판정이 갈린 전사는 0/87
# 크롬 세션(`mcp__claude-in-chrome__navigate`)은 `input.url` 이 http(s) 면 센다. 명령 문자열이 없는
# 경로라 같은 규칙(URL 이 실린 실행)을 그 도구의 입력에 적용한 것이다. `javascript_tool` 본문은
# 세지 않는다 — 함수 정의에도 URL 이 들어 있어 정의만 하고 부르지 않은 것과 가를 수 없다.
_HEREDOC = re.compile(r"<<-?\s*'?[A-Za-z_]\w*'?\n.*?\n\s*\w+\s*$", re.S | re.M)
_LIVE = re.compile(r'https?://')

# CONTRACT: origin-reads-counted-not-judged (#8 R20 · D7)
# lane 이 **원본 체크아웃**을 내용 출처로 읽은 도구 호출 수. 스냅숏을 받고도 원본을 읽으면 커밋되지
# 않을 남의 변경을 검사한 것이다. 관측 로그에만 남기고 **판정에는 쓰지 않는다** — 실측 전에 막지 않는다.
# 셈 규칙 (호출 하나에 최대 1):
#   · 파일 도구(Read·Grep·Glob·NotebookRead)의 경로 인자가 원본 레포 루트 아래면 센다.
#   · Bash 명령은 원본 루트 경로가 나오는 자리 중 **`-C <루트>` 가 아닌 곳**이 하나라도 있으면 센다 —
#     `git -C <원본> rev-parse` 처럼 레포를 가리키기만 하는 인자는 내용 읽기가 아니다.
#   · 스냅숏 경로는 원본 루트 아래가 아니므로 세지 않는다.
def _origin_read(name, inp, origin):
    if not origin or not isinstance(inp, dict):
        return 0
    o = origin.rstrip('/')
    under = lambda p: isinstance(p, str) and (p == o or p.startswith(o + '/'))
    if name.split('__')[-1] in ('Read', 'Grep', 'Glob', 'NotebookRead'):
        return 1 if any(under(inp.get(k)) for k in ('file_path', 'path', 'notebook_path')) else 0
    cmd = inp.get('command')
    if not isinstance(cmd, str):
        return 0
    for m in re.finditer(re.escape(o) + r'(?=$|[/\s\'"])', cmd):
        if not re.search(r'-C\s+[\'"]?$', cmd[:m.start()]):
            return 1
    return 0

def _scan_transcripts(d):
    """워크플로 전사에서 lane 별 실행 사실을 뽑는다. {lane: {calls, errors, first, last}}"""
    import glob as _g
    _origin = os.environ.get('REPO_TOP') or ''
    out = {}
    for f in _g.glob(os.path.join(d, 'agent-*.jsonl')):
        lane = None; calls = 0; errors = 0; first = None; last = None; _lane = None; live = 0; oreads = 0
        # 구조화 출력은 **스키마 검증에 거절되면 재시도**된다. 거절된 호출을 판정으로 세면
        # 재시도로 통과한 lane 이 FAIL 로 읽힌다 — 전사 1,422건 중 427건(3할)이 이 형태다.
        # 호출 id 를 들고 있다가 tool_result 가 is_error 면 그 호출을 판정에서 뺀다.
        # 채택은 **가장 늦게 수락된 호출** — 워크플로가 보는 최종 결과와 같다.
        # lane 귀속은 **수락된 출력**에만 근거한다. 거절된 호출의 lane 을 받으면 baseline 이
        # lane="test-runner" 로 거절당한 전사의 도구호출이 test-runner 증거에 합산돼
        # no-lane-evidence 가 우회된다. 수락된 것이 하나도 없으면 이 전사는 귀속하지 않는다.
        cmds = []      # 실행한 명령 — 회귀 명령이 실제로 돌았는지 기록 단계가 본다
        cand = {}      # tool_use_id → (timestamp, verdict)
        rejected = set()
        try: lines = open(f, errors='ignore').read().splitlines()
        except Exception: continue
        for line in lines:
            try: rec = json.loads(line)
            except Exception: continue
            ts = rec.get('timestamp')
            content = (rec.get('message') or {}).get('content')
            if not isinstance(content, list): continue
            for b in content:
                if not isinstance(b, dict): continue
                if b.get('type') == 'tool_use':
                    nm = str(b.get('name') or '')
                    if 'StructuredOutput' in nm:
                        # lane 식별은 **구조화 출력**에서만 한다. 프롬프트에도 lane 이름이
                        # 들어 있어 본문 grep 으로 잡으면 남의 전사를 자기 것으로 오인한다.
                        _in = b.get('input') or {}
                        _lane = _in.get('lane')
                        # 구조화 출력을 냈으면 verdict 는 반드시 어휘 안에 있어야 한다.
                        # 없거나 열거 밖이면 fail-closed 로 FAIL 취급 — 그러지 않으면
                        # reported 가 None 이 되어 승격 검사가 통째로 건너뛰어진다.
                        _v = _in.get('verdict')
                        if _v not in _RANK:
                            _v = 'FAIL'
                        # verdict=PASS 라도 blocking findings 가 있으면 워크플로는 FAIL 로 집계한다.
                        elif any((x or {}).get('blocking') for x in (_in.get('findings') or [])):
                            _v = 'FAIL'
                        # id 가 없으면 위치로 키를 만든다 — 버리면 그 lane 의 판정이 사라진다
                        # lane 도 함께 들고 있다가 **수락된** 호출의 것만 채택한다.
                        cand[b.get('id') or f'_pos{len(cand)}'] = (ts or '', _v, _lane, _in)
                    else:
                        calls += 1
                        oreads += _origin_read(nm, b.get('input'), _origin)
                        # 규칙·근거·실측은 _LIVE 정의. 히어독 본문은 파일로 쓰인 것이라 뺀다.
                        _cmd = (b.get('input') or {}).get('command') or ''
                        if isinstance(_cmd, str) and _cmd:
                            cmds.append(_HEREDOC.sub(' ', _cmd))
                        if isinstance(_cmd, str) and _LIVE.search(_HEREDOC.sub(' ', _cmd)):
                            live += 1
                        # 크롬 세션 — 규칙은 _LIVE 정의 위. 호스트는 Bash 쪽과 같이 보지 않는다.
                        elif nm.endswith('claude-in-chrome__navigate'):
                            _url = (b.get('input') or {}).get('url') or ''
                            if isinstance(_url, str) and _LIVE.match(_url):
                                live += 1
                        if ts and (first is None or ts < first): first = ts
                        if ts and (last is None or ts > last): last = ts
                elif b.get('type') == 'tool_result' and b.get('is_error'):
                    errors += 1
                    if b.get('tool_use_id') in cand: rejected.add(b['tool_use_id'])
        # CONTRACT: rejected-excluded
        accepted = [v for k, v in cand.items() if k not in rejected]
        # 판정 자신의 시각으로 고른다. 도구호출 시각(last)을 쓰면 판정 시각과 어긋난다.
        # raw 튜플로 max 하면 시각 동률에서 verdict 문자열 **알파벳 순**으로 갈린다
        # (max([('t','FAIL'),('t','PASS')]) → PASS). 심각도를 키에 넣어 fail-closed 로 고정한다.
        # CONTRACT: lane-attribution-accepted-only · tiebreak-severity
        reported_at, reported, lane, output = (max(accepted, key=lambda x: (x[0], _RANK.get(x[1], 0)))
                                               if accepted else ('', None, None, None))
        if lane:
            e = out.setdefault(lane, {'calls': 0, 'errors': 0, 'live': 0, 'originReads': 0, 'first': None, 'last': None, 'reported': None, 'reportedAt': '', 'cmds': []})
            e['calls'] += calls; e['errors'] += errors; e['live'] += live; e['originReads'] += oreads
            e['cmds'].extend(cmds)
            # 한 lane 에 전사가 여럿인 경우는 **재실행·재시도**다 — 시간 축이라 나중 것이 맞다.
            # 동률이면 심각도로 가른다 (fail-closed) — 그러지 않으면 glob 순서가 판정을 바꾼다.
            if reported:
                cur, cur_at = e.get('reported'), e.get('reportedAt') or ''
                if (reported_at > cur_at
                        or (reported_at == cur_at and _RANK.get(reported, 0) > _RANK.get(cur, 0))):
                    e['reported'] = reported; e['reportedAt'] = reported_at
                    e['output'] = output   # 채택된 구조화 출력 원문 — 아래에서 꺼내 영수증에는 싣지 않는다
            if first and (e['first'] is None or first < e['first']): e['first'] = first
            if last and (e['last'] is None or last > e['last']): e['last'] = last
    return out

# CONTRACT: suites-run-is-counted
# 분류기가 회귀 명령을 정했으면 test-runner 는 **돌았어야** 한다. 대상 아님·건너뜀으로 기록하면
# lane 이 분류기의 결정을 다시 뒤집는 것이다 — 이 검사는 전사 유무와 무관하다.
_suites = ((classify.get('laneMeta') or {}).get('test-runner') or {}).get('suites') or []
_trs = lanes.get('test-runner')
_trs = (_trs.get('status') if isinstance(_trs, dict) else _trs) or ''
if _suites and _trs in ('SKIPPED', 'NOT_APPLICABLE'):
    print(f"게이트 기록 거부 — 분류기가 회귀 명령을 정했는데 test-runner 가 {_trs} 로 기록됐다.")
    print("  " + ', '.join(str(x.get('name')) for x in _suites if isinstance(x, dict)) + " 를 돌려야 한다. 1번부터 다시 돌려라.")
    _log('record', 'refused', reason='suite-not-run', suites=[x.get('name') for x in _suites if isinstance(x, dict)], status=_trs)
    sys.exit(1)

evidence = {}
lane_outputs = {}
tdir = os.environ.get('TRANSCRIPTS') or ''
# CONTRACT: transcripts-required-when-given
if tdir and not os.path.isdir(tdir):
    print(f"게이트 기록 거부 — 전사 디렉터리를 읽을 수 없다: {tdir}")
    print("  넘겼는데 못 읽으면 전사 기반 검사 셋(no-lane-evidence · concealed-promotion ·")
    print("  sequence-violated)이 전부 건너뛰어진다. 경로를 고치거나, 검증을 낮출 의도면 인자를 빼라.")
    _log('record', 'refused', reason='transcripts-unreadable', transcripts=tdir)
    sys.exit(1)
if tdir:
    evidence = _scan_transcripts(tdir)
    # 출력 원문은 영수증·로그에 싣지 않는다(크고, 판정에 쓰지 않는다). QA 기록만 이것을 쓴다.
    lane_outputs = {l: e.pop('output', None) for l, e in evidence.items()}
    lane_cmds = {l: e.pop('cmds', []) for l, e in evidence.items()}
    # PASS 인데 도구를 한 번도 안 쓴 lane 은 "검사했다" 는 주장만 있는 것이다
    def _st(v): return (v.get('status') if isinstance(v, dict) else v) or ''
    ran = [l for l in required if _st(lanes.get(l)) not in ('SKIPPED', 'NOT_APPLICABLE')]
    noev = [l for l in ran if evidence.get(l, {}).get('calls', 0) == 0]
    if noev:
        print("게이트 기록 거부 — 실행 흔적이 없는 lane 이 있다: " + ', '.join(noev))
        print(f"  전사: {tdir}")
        print("  전사에 도구 실행이 하나도 없다. 보고는 있으나 검사는 없었다는 뜻이다.")
        _log('record', 'refused', reason='no-lane-evidence', lanes=noev, transcripts=tdir)
        sys.exit(1)

    # CONTRACT: qa-execution-is-counted-not-claimed
    # QA 는 **배포된 것에 요청을 보내** 검사한다. 도구를 썼다는 사실로는 그것이 증명되지 않는다 —
    # qa-reviewer 가 전사를 읽고 내리던 판정("변경을 아예 실행하지 않았다")을 여기서 코드가 센다.
    # `ran` 이면 충분하다 — SKIPPED·NOT_APPLICABLE 은 거기서 이미 빠졌고, FAIL·ERROR 는
    # 위 lane-status 검사가 먼저 끊는다. 통과 어휘를 여기 또 적으면 두 곳이 갈린다.
    if 'qa-runner' in ran:
        _live = evidence.get('qa-runner', {}).get('live', 0)
        if _live == 0:
            print("게이트 기록 거부 — QA 가 통과로 보고됐는데 라이브 요청이 0건이다.")
            print(f"  전사: {tdir}")
            print("  실행한 명령 중 URL(http/https)이 실린 것이 하나도 없다 —")
            print("  배포된 것에 요청을 보내지 않았다는 뜻이다. 검사한 것이 아니라 읽은 것이다.")
            print("  (히어독 본문은 세지 않는다 — 파일로 쓴 것은 아직 실행이 아니다)")
            _log('record', 'refused', reason='qa-not-executed',
                 calls=evidence.get('qa-runner', {}).get('calls', 0), live=0, transcripts=tdir)
            sys.exit(1)
    # 전사가 있으면 **실행했는지**까지 센다. 그 스크립트가 **명령 자리**에 와야 한다 — 명령 첫머리나
    # 구분자 뒤에서, 환경변수 대입·`timeout N`·`env`·`nice`·`time` 과 셸 인터프리터만 앞에 올 수 있다.
    # `grep … meta-test.sh`·`grep bash …/meta-test.sh` 처럼 인자로만 나온 것은 실행이 아니다.
    # 셸이 **글자로만** 다루는 자리(작은따옴표 안, 큰따옴표 안, `#` 주석, heredoc 본문)의 구분자
    # `;&|()`·백틱·줄바꿈은 지운다 — `grep '^X=\|Y=' meta-test.sh` 의 `|` 뒤를 명령 자리로 보면
    # grep 이 실행으로 셌다. 큰따옴표 안이라도 `$(…)`·백틱은 셸이 실행하므로 명령 문맥으로 되돌린다.
    # 지우기는 글자 수를 그대로 두므로 위치를 원문에 그대로 옮길 수 있다.
    def _shell_seps_outside_quotes(cmd):
        out, st, esc, prev, i, n = [], ['c'], False, '\n', 0, len(cmd)
        hd = []   # 이 줄이 끝나면 건너뛸 heredoc 종결어
        while i < n:
            ch, top = cmd[i], st[-1]
            lit = top in ('"', "'", '#')
            if top == 'h':
                end = cmd.find('\n', i)
                line = cmd[i:] if end < 0 else cmd[i:end + 1]
                out.append(re.sub(r'[^\n]', ' ', line)); i += len(line)
                if line.strip() == hd[0]:
                    hd.pop(0)
                    if not hd: st.pop()
                continue
            if top == '#':
                if ch == '\n': st.pop(); lit = st[-1] in ('"', "'")
            elif esc:
                esc = False
            elif ch == '\\' and top != "'":
                esc = True
            elif top == "'":
                if ch == "'": st.pop()
            elif top == '"' and ch == '"':
                st.pop()
            elif ch == '$' and cmd[i + 1:i + 2] == '(' and top != "'":
                st.append('$('); out.append('$('); prev, i = '(', i + 2; continue
            elif ch == '`':
                if top == '`': st.pop()
                else: st.append('`'); lit = False
            elif top == '"':
                pass
            elif ch in '"\'':
                st.append(ch)
            elif ch == '#' and (prev.isspace() or prev in ';&|(`'):
                st.append('#'); lit = True
            elif ch == '(':
                st.append('(')
            elif ch == ')' and top in ('$(', '('):
                st.pop()
            elif ch == '<' and cmd[i:i + 2] == '<<' and cmd[i:i + 3] != '<<<':
                m = re.match(r'<<-?\s*([\'"]?)([A-Za-z_]\w*)\1', cmd[i:])
                if m: hd.append(m.group(2))
            if ch == '\n' and hd and st[-1] != 'h' and not (st[-1] in ('"', "'")):
                out.append(ch); prev, i = ch, i + 1; st.append('h'); continue
            if lit and ch in ';&|()`\n':
                ch, esc = ' ', False
            prev = ch
            out.append(ch)
            i += 1
        return ''.join(out)
    _CMD_POS = r'(?:^|[;&|(`]\s*)(?:\w+=\S*\s+)*(?:(?:timeout\s+\S+|env|nice|time(?:\s+-p)?)\s+)*'
    # `bash -c "…"`·`eval "…"` 의 인자는 그 자체가 명령이다. `-n`(구문만 검사)이 섞이면 실행이 아니다.
    _SH_C = re.compile(_CMD_POS + r'''(?:(?:\S*/)?(?:bash|sh|zsh)\s+(?:-(?![A-Za-z]*n)[A-Za-z]+\s+)*?'''
                       r'''-(?![A-Za-z]*n)[A-Za-z]*c[A-Za-z]*\s+|eval\s+)("(?:[^"\\]|\\.)*"|'[^']*')''', re.M)
    def _ran_script(marker, cmd):
        masked = _shell_seps_outside_quotes(cmd)
        if re.search(_CMD_POS + r'(?:(?:bash|sh|zsh|source)\s+)?(?:\S*/)?' + re.escape(marker)
                     + r'''(?:\s|$|[;&|)"'`])''', masked, re.M):
            return True
        for m in _SH_C.finditer(masked):
            inner = cmd[m.start(1) + 1:m.end(1) - 1]
            if cmd[m.start(1)] == '"': inner = re.sub(r'\\(["\\$`])', r'\1', inner)
            if _ran_script(marker, inner): return True
        return False
    if _suites and 'test-runner' in ran:
        _tc = lane_cmds.get('test-runner') or []
        _miss = [x.get('name') for x in _suites
                 if isinstance(x, dict) and x.get('marker') and not any(_ran_script(x['marker'], c) for c in _tc)]
        if _miss:
            print("게이트 기록 거부 — 분류기가 정한 회귀 명령이 실행되지 않았다: " + ', '.join(_miss))
            print(f"  전사: {tdir}")
            print("  test-runner 의 실행 명령 중 그 스크립트를 부른 것이 없다. 1번부터 다시 돌려라.")
            _log('record', 'refused', reason='suite-not-run', suites=_miss, transcripts=tdir)
            sys.exit(1)
    # WARNING 을 waived 없이 PASS 로 덮으면 "원래 WARNING 이었다" 가 사라진다. lanes 는 호출자가
    # 고칠 수 있으므로 lanes 안에서는 이 승격을 볼 수 없다 — 전사의 verdict 가 유일한 독립 기록이다.
    promoted = []
    for lane, ev in evidence.items():
        rep = ev.get('reported')
        v = lanes.get(lane)
        if not rep or v is None: continue
        # lanes 는 dict 와 문자열 둘 다 정본이고(위 usage), 허용 상태는 PASS·SKIPPED·
        # NOT_APPLICABLE 셋이다. 한 갈래만 보면 나머지로 빠져나간다.
        st = v.get('status') if isinstance(v, dict) else v
        wv = isinstance(v, dict) and v.get('waived')
        # "통과가 아닌 것" 의 정의는 _RANK 하나에서만 나온다. 여기 어휘를 손으로 적으면
        # _RANK 에 값이 늘 때 갈린다 (ERROR 가 그 자리였다).
        # CONTRACT: promotion-vocab-from-rank
        if _RANK.get(rep, 0) >= 2 and st in OK and not wv:
            promoted.append(f"{lane}: 전사 verdict={rep} 인데 waived 없이 {st} 로 기록")
    if promoted:
        print("게이트 기록 거부 — 승인 흔적 없이 통과로 승격된 lane 이 있다:")
        for s in promoted: print("  " + s)
        print('  승인했으면 {"status":"PASS","waived":true,"originalStatus":"<원래값>","reason":"<승인 내용>"} 로 기록해라.')
        _log('record', 'refused', reason='concealed-promotion', detail=promoted)
        sys.exit(1)

    # 의존 순서 — 앞 lane 이 **보고를 낸 시각**이 뒤 lane 의 첫 실행보다 앞서야 한다.
    # 앞 lane 의 마지막 도구호출만 보면, 그 뒤 판정을 쓰는 동안 출발한 뒤 lane 이 통과한다 —
    # 보고가 나오기 전에 시작했으니 그 보고를 받았을 수 없다. 도구호출 없이 보고만 낸 lane 은
    # 보고 시각으로 잰다(그러지 않으면 시각이 비어 검사가 건너뛰어진다).
    # CONTRACT: sequence-measured-from-report
    bad_seq = []
    for chain in (classify.get('sequential') or []):
        for a, b in zip(chain, chain[1:]):
            ea, eb = evidence.get(a) or {}, evidence.get(b) or {}
            a_end = max(ea.get('reportedAt') or '', ea.get('last') or '')
            b_start = eb.get('first') or eb.get('reportedAt') or ''
            if a_end and b_start and a_end > b_start:
                bad_seq.append(f"{a}(끝 {a_end}) > {b}(시작 {b_start})")
    if bad_seq:
        print("게이트 기록 거부 — 순차 lane 의 실행 순서가 어긋났다:")
        for s in bad_seq: print("  " + s)
        print("  뒤 lane 이 앞 lane 의 결과 없이 판정했다는 뜻이다.")
        _log('record', 'refused', reason='sequence-violated', detail=bad_seq)
        sys.exit(1)

# ── 하네스 뷰가 뒤처졌는가 (harness-view-stale)
# README 의 마커 안은 생성물이다 — agents frontmatter·훅 등록·lane 집합. 그것들을 고치고
#  재생성을 잊으면 표가 조용히 거짓이 된다. 틀린 표는 없는 표보다 나쁘다.
# 검사가 여기 있는 이유는 **여기만 조건이 맞기 때문**이다: 진짜 레포 루트에서 돌고(생성기는
#  루트 파일을 읽는다), 분류 산출물이 <gitdir> 에 있고(생성기가 lane 집합을 거기서 읽는다),
#  커밋 직전이다. meta-test 의 임시 HOME 에는 레포 루트 파일이 없고, 스냅숏은 worktree 전용
#  gitdir 때문에 생성기가 판단 불가로 빠진다.
#
# **판정의 입력은 전부 인덱스여야 한다.** 생성기의 `--check` 를 쓰지 않는 이유가 이것이다 —
#  그것은 워킹트리 입력으로 만든 표를 워킹트리 README 와 비교하므로 두 방향으로 틀린다:
#  재생성해 놓고 `git add README.md` 를 잊으면 통과시키면서 뒤처진 표를 커밋에 담고(막겠다던
#  바로 그 일이다), 남의 미스테이징 수정이 표에 새면 커밋에 들어가지도 않는 파일로 거부한다
#  (#8 D4 위반). 그래서 `--stdout-from-index`(입력을 인덱스에서 읽는다) 와 인덱스의 README
#  blob 을 쓴다.
#
# 표를 만드는 **코드도 입력이다.** 생성기 스크립트 자체는 워킹트리 사본을 돌리므로, 그것이
#  인덱스와 다르면 커밋되지 않을 코드가 만든 표로 판정하는 셈이다 — 거짓 거부가 되고, 안내대로
#  재생성하면 커밋되지 않은 코드의 출력이 인덱스에 들어간다. 그래서 **다르면 판정하지 않고
#  그 사실을 남긴다**(침묵하면 미스테이징 한 줄로 이 검사만 조용히 꺼진다). 인덱스에 없어도
#  마찬가지다. 세 입력이 모두 인덱스와 같을 때만 판정한다.
#
# 마커 문자열은 **생성 결과의 첫 줄·끝 줄**에서 가져온다 — 여기 상수로 적으면 생성기와
#  갈린다. 마커를 인덱스 README 에서 못 찾으면 판정하지 않는다.
# 생성기가 0 으로 끝나지 않으면(2 인자 오류 · 4 판단 불가) 무시한다 — 판단 불가를 거부로
#  쓰면 분류 산출물이 없는 레포에서 기록이 영원히 막힌다. 생성기가 없는 레포는 대상이 아니다.
# lane 집합은 게이트 모드로 갈리지 않는다 — 생성기가 selected ∪ notSelected 를 쓰고, 두
#  모드 다 lane 전부를 한쪽에 담는다. commit·pr 분류로 각각 생성한 결과가 같다(2026-11-13 실측).
_hv_root = os.environ.get('REPO_TOP') or os.environ.get('DIR') or ''
_hv = os.path.join(_hv_root, 'make-harness-view.sh')
if _hv_root and os.path.isfile(_hv):
    def _hv_run(*a):
        try:
            r = subprocess.run(a, cwd=_hv_root, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=120)
            return (r.returncode, r.stdout.decode('utf-8', 'replace'),
                    r.stderr.decode('utf-8', 'replace'))
        except Exception as e:
            return (None, '', str(e))
    # 판정하지 못한 이유는 **전부** 적는다. 한 경로라도 침묵하면 거기로 검사가 조용히 꺼진다 —
    #  마커를 지우는 것만으로 영구히 꺼지는 것이 가장 조용한 경로다.
    _hv_skip, _gen, _idx = None, '', ''
    _hsrc = None
    try:
        with open(_hv, 'rb') as _f:
            _hsrc = _f.read().decode('utf-8', 'replace')
    except Exception as _e:
        _hv_skip = f'생성기를 읽을 수 없다 ({_e})'
    if _hv_skip is None:
        _hirc, _hidx, _herr = _hv_run('git', '-C', _hv_root, 'show', ':make-harness-view.sh')
        if _hirc != 0:
            _hv_skip = 'make-harness-view.sh 가 인덱스에 없다 (추적되지 않는다)'
        elif _hsrc != _hidx:
            _hv_skip = ('make-harness-view.sh 가 인덱스와 다르다 — 커밋되지 않을 코드가 만든 '
                        '표로는 판정하지 않는다. git add 하면 판정한다')
    if _hv_skip is None:
        _grc, _gen, _gerr = _hv_run('bash', _hv, '--stdout-from-index')
        if _grc != 0:
            _hv_skip = f'생성기가 {_grc} 로 끝났다: ' + ' '.join((_gerr or '').split())[:160]
    if _hv_skip is None:
        _irc, _idx, _ierr = _hv_run('git', '-C', _hv_root, 'show', ':README.md')
        if _irc != 0:
            _hv_skip = '인덱스에 README.md 가 없다'
    _gl = _gen.splitlines()
    if _hv_skip is None and len(_gl) < 2:
        _hv_skip = '생성 결과가 두 줄 미만이다 — 마커를 특정할 수 없다'
    if _hv_skip is None:
        _b, _e2 = _gl[0], _gl[-1]
        _s0, _s1 = _idx.find(_b), _idx.find(_e2)
        if not (_s0 >= 0 and _s1 > _s0):
            _hv_skip = f'인덱스 README 에 마커가 없다 ({_b.strip()[:40]})'
        else:
            _have = _idx[_s0:_s1 + len(_e2)].splitlines()
            if _have != _gl:
                import difflib
                _d = [x for x in difflib.unified_diff(
                    _have, _gl, 'README.md 의 블록 (인덱스)',
                    'make-harness-view.sh --stdout-from-index', lineterm='', n=0)][:40]
                print("게이트 기록 거부 — 커밋될 README 의 하네스 뷰가 뒤처졌다")
                for _l in _d: print("  " + _l)
                print("  make-harness-view.sh --write-from-index 로 재생성하고 마커 블록만")
                print("  스테이징한 뒤(git add -p README.md) 1번부터 다시 해라 (인덱스가 바뀌므로")
                print("  재분류가 필요하다).")
                print("  **인자 없이 재생성하지 마라** — 그 모드는 워킹트리 입력을 읽으므로, 입력에")
                print("  미스테이징 수정이 있으면 커밋되지 않을 내용이 README 에 들어가 거부가 반복된다.")
                print("  **README 를 통째로 add 하지 마라** — 재생성은 마커 밖 본문을 워킹트리에서")
                print("  그대로 다시 쓰므로, 통째로 담으면 거기 있던 미스테이징 수정까지 커밋된다.")
                _log('record', 'refused', reason='harness-view-stale', detail=_d[:20])
                sys.exit(1)
    if _hv_skip:
        print("참고 — 하네스 뷰를 판정하지 않았다: " + _hv_skip)

not_sel = classify.get('notSelected') or {}
extra = [l for l in lanes if l not in selected and l not in not_sel]
# 대상 아닌 lane 을 더 돌린 것은 막지 않는다 — 더 본 것이 해로울 이유가 없다. 다만 남긴다.
procedure = {
    'classificationId': classify.get('classificationId'),
    'contentDigest': cd_decl,
    'required': sorted(required),
    'recorded': sorted(lanes),
    'extraLanes': sorted(extra),
    'evidence': evidence or None,
    'evidenceSource': tdir or None,
    'complete': True,
    'limits': ('출력 내용의 정당성은 검증하지 않는다 (실행 사실·순서·판정 승격까지만)'
               if tdir else
               '전사를 넘기지 않아 실행 사실·순서·판정 승격이 검증되지 않았다 — lane 존재 여부만 봤다'),
}

def _plan():
    # 실패를 NONE 으로 바꾸지 않는다 — 결속된 계획이 "없음" 으로 기록되면 역추적이 끊긴다.
    try:
        p = json.loads(os.environ.get('PLANJSON') or '')
    except Exception:
        p = None
    if not isinstance(p, dict) or 'status' not in p:
        return {'status': 'UNREADABLE', 'reason': 'plan.sh resolve 실패'}
    return p

r = os.environ['R']
try:
    with open(r) as f: data = json.load(f)
except Exception:
    data = {}
# 영수증은 **브랜치별**이다. 한 파일에 kind 하나씩만 두면 같은 레포의 다른 세션이 서로를
# 밀어낸다 (worktree 도 .git 을 공유한다) — 세 세션이 동시에 막힌 원인이다.
data.setdefault('schema', 2)
data.setdefault('branches', {})
_cut = int(os.environ['TS']) - 86400
# 만료분은 정리한다 (24h 뒤 어차피 무효). **`pr` 만은 지우지 않고 축약해 남긴다** — 왜 이
# 키가 낡지 않는지는 classify.sh 의 `_branch_has_pr_gate` docstring 에 있다. 통째로 남기면
# `classification`·`lanes` 까지 영구 보존돼 브랜치당 수 KB 가 쌓이므로, 판정에 필요한
# "통과한 적이 있다" 한 조각만 남기고 본문은 버린다. `verify` 는 ts 만료를 따로 거부하므로
# 축약된 기록이 PR 게이트 통과로 재사용되지는 않는다.
for _b in list(data['branches']):
    _e = data['branches'][_b]
    for _k in [k for k, v in _e.items() if int((v or {}).get('ts', 0)) < _cut]:
        if _k == 'pr':
            _e[_k] = {'ts': int((_e[_k] or {}).get('ts', 0)), 'pruned': True}
        else:
            del _e[_k]
    if not _e:
        del data['branches'][_b]
# ── 추적 요약: 머지 보고의 "claim N개 중 M개 닫힘" (docs/cycle-trace.md § 5-5) ──────────
# 분모는 계획의 claim 목록(plan.sh claims)이고, 각 claim 의 판정은 **전사의** tracer 출력에서만 읽는다
# — lanes 인자는 호출자가 고칠 수 있다. tracer 가 빠뜨린 claim 은 닫힌 것이 아니라 "보고 없음" 이다.
# 닫힘 = 세 축이 전부 FOUND 이거나 해당 없음(NA). MANUAL 은 사람이 확인할 때까지 열린 것으로 센다.
_CLOSED = ('FOUND', 'NA')
def _trace_summary():
    if os.environ['KIND'] != 'pr':
        return None
    try:
        pc = json.loads(os.environ.get('PLANCLAIMS') or '{}')
    except Exception:
        pc = {}
    if pc.get('status') != 'FOUND':
        return {'plan': pc.get('status') or 'UNREADABLE'}
    out = {'plan': 'FOUND', 'planId': pc.get('planId'), 'approval': pc.get('approval'), 'total': len(pc.get('ids') or [])}
    to = lane_outputs.get('requirements-tracer')
    if not isinstance(to, dict) or not isinstance(to.get('claims'), list):
        out['closed'] = None
        out['reason'] = '전사를 넘기지 않았다' if not tdir else '전사의 추적 출력에 claims 가 없다'
        return out
    by = {c['id']: c for c in to['claims'] if isinstance(c, dict) and isinstance(c.get('id'), str)}
    opened = []
    for cid in pc.get('ids') or []:
        c = by.get(cid)
        if c is None:
            opened.append({'id': cid, 'why': '보고 없음'}); continue
        bad = [f"{ax} {c.get(ax)}" for ax in ('impl', 'verify', 'validate') if c.get(ax) not in _CLOSED]
        if bad:
            opened.append({'id': cid, 'why': ', '.join(bad)})
    out.update({'closed': out['total'] - len(opened), 'open': opened,
                'unknown': sorted(set(by) - set(pc.get('ids') or []))})
    return out

data['branches'].setdefault(os.environ['BRANCH'], {})[os.environ['KIND']] = {
    'indexTree': os.environ['IT'],      # 커밋될 내용 (신뢰 경계의 기준점)
    # 에이전트가 본 상태 = 분류가 lane 에 넘긴 스냅숏 트리 (#8 R13). 커밋 모드는 indexTree 와 같다
    #  (위 index-changed). 워킹트리에서 계산한 값은 남기지 않는다 — lane 은 워킹트리를 보지 않는다.
    'seenTree': (classify.get('snapshot') or {}).get('tree') or None,
    'head': os.environ['HEAD_SHA'],
    'branch': os.environ['BRANCH'],
    'ts': int(os.environ['TS']),
    # 이 기록을 만든 엔진 (lib.sh pf_engine_version). 못 읽으면 null — 판정에 쓰지 않는다.
    'engineVersion': os.environ.get('ENGINE_VER') or None,
    'lanes': lanes,
    'classification': classify,   # 어떤 근거로 이 lane 들을 골랐는가
    'procedure': procedure,       # 그 근거가 요구한 절차를 실제로 밟았는가
    'plan': _plan(),              # 어떤 계획을 근거로 한 변경인가 (없으면 명시)
    'trace': _trace_summary(),    # PR 게이트: 계획 claim 의 닫힘 (머지 보고가 읽는다)
}
with open(r, 'w') as f: f.write(_json_out(data, indent=2))

# ── QA 기록: 커밋될 트리에 묶는다 (docs/cycle-trace.md § 5-3) ────────────────
# 영수증은 lane 마다 status·짧은 reason 만 남아, PR 시점의 추적이 "무엇을 밟았나" 를 볼 수 없었다.
# 시나리오는 **전사에서 관찰한 구조화 출력**에서만 가져온다 — lanes 인자는 호출자가 고칠 수 있다.
# 덮임(계획 항목 중 어떤 참조가 시나리오에 달렸나)은 코드가 센다. 참조 문자열은 plan.sh 가 만든다
# — CONTRACT: qa-ref-is-one-function.
qa_written = None
qa_skip = None
_qo = lane_outputs.get('qa-runner') if os.environ['KIND'] == 'commit' else None
# 자리를 못 구하면 쓰지 않는다 — 빈 값으로 이으면 프로세스 cwd 에 기록이 생긴다.
if isinstance(_qo, dict) and isinstance(_qo.get('scenarios'), list) and not os.environ.get('COMMON_DIR'):
    qa_skip = 'git common dir 를 구하지 못했다'
elif isinstance(_qo, dict) and isinstance(_qo.get('scenarios'), list):
    try:
        _pq = json.loads(os.environ.get('PLANQA') or '{}')
    except Exception:
        _pq = {}
    _planned = [i.get('ref') for i in (_pq.get('items') or []) if isinstance(i, dict) and i.get('ref')]
    _sc = [x for x in _qo['scenarios'] if isinstance(x, dict)]
    def _refs(pred):
        return sorted({r for x in _sc if pred(x) for r in (x.get('claimRefs') or []) if isinstance(r, str)})
    _passed = _refs(lambda x: x.get('result') == 'PASS')
    _failed = _refs(lambda x: x.get('result') == 'FAIL')
    _notrun = _refs(lambda x: x.get('result') == 'NOT_RUN')
    _cov = {'planned': _planned,
            'passed': [x for x in _planned if x in _passed],
            'failed': [x for x in _planned if x in _failed],
            'notRun': [x for x in _planned if x in _notrun and x not in _passed and x not in _failed],
            'missing': [x for x in _planned if x not in _passed + _failed + _notrun],
            # 계획에 없는 참조 — 오타이거나 다른 계획의 것이다. 덮임으로 세지 않는다.
            'unknown': sorted(set(_passed + _failed + _notrun) - set(_planned))}
    # CONTRACT: qa-record-path — 읽는 쪽은 classify.sh `_trace_inputs`. 자리를 바꾸면 둘 다 바꾼다.
    _qdir = os.path.join(os.environ['COMMON_DIR'], 'claude-preflight.qa')
    _qpath = os.path.join(_qdir, os.environ['IT'] + '.json')
    _qrec = {'schema': 1, 'indexTree': os.environ['IT'], 'head': os.environ['HEAD_SHA'] or None,
             'branch': os.environ['BRANCH'], 'ts': int(os.environ['TS']),
             'planId': _pq.get('planId'), 'verdict': _qo.get('verdict'),
             'reviewer': (lane_outputs.get('qa-reviewer') or {}).get('verdict'),
             'scenarios': _sc, 'coverage': _cov, 'source': tdir}
    # 영수증은 이미 위에서 써졌다. 여기서 죽으면 커밋은 통과되는데 `record` 는 실패로 끝나 신호가 갈린다
    # — QA 기록의 실패는 사유로만 남기고 기록 결과를 뒤집지 않는다.
    try:
        os.makedirs(_qdir, exist_ok=True)
        with open(_qpath + '.tmp', 'w') as f: f.write(_json_out(_qrec, indent=2))
        os.replace(_qpath + '.tmp', _qpath)
        qa_written = _qpath
    except OSError as _e:
        qa_skip = f'QA 기록을 쓰지 못했다: {_qpath} ({_e})'
# ── vault 대기 목록: PR 게이트의 드리프트를 막지 않고 적재한다 (docs/design.md § vault 대기 목록) ──
# 영수증을 **쓴 뒤**에 한다 — 여기서 무엇이 실패해도 위의 판정·거부 사유는 이미 정해졌다(I4).
# 적재 실패는 기록을 거부하지 않는다. 대신 보고와 관측 로그에 미기록 건수와 사유를 남긴다 —
# 드리프트를 막지 않게 된 지금 대기 목록이 유일한 보존 장치라, 조용히 잃으면 안 된다(R3).
# 드리프트는 **전사의 구조화 출력**(vault-sync 의 drifts[])에서만 읽는다 — QA 기록과 같은 규칙이다.
# vault 대기 목록 스크립트는 카테고리 규칙이다(#47 D4 — vault-sync·등록 조회와 같은 자리). 엔진은 카테고리 이름을
# 모르므로 분류가 고른 카테고리 디렉터리에서 `vault-queue.sh` 를 찾는다. 없으면 None — 부르는 쪽이 사유를 남긴다.
VQS = None

def _queue_script(cl):
    c = (cl or {}).get('category')
    if not isinstance(c, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]*', c):
        return None
    # PF_CATS 는 카테고리 루트 목록이다(lib.sh pf_category_roots — 엔진 다음 오버레이). 이름이 겹치면 분류가 이미 거부했다.
    p = next((q for q in (os.path.join(r, c, 'vault-queue.sh') for r in os.environ['PF_CATS'].split(':') if r)
              if os.path.isfile(q)), os.path.join(os.environ['PF_CATS'].split(':')[0], c, 'vault-queue.sh'))
    return p if os.access(p, os.X_OK) else None

def _vq(*args, inp=None):
    try:
        if not VQS:
            return 1, {'error': 'queue-unavailable', 'reason': f"카테고리 {classify.get('category')} 에 vault-queue.sh 가 없다"}
        p = subprocess.run([VQS, *args], input=inp, capture_output=True, text=True, timeout=60)
        try:
            return p.returncode, json.loads(p.stdout or '{}')
        except Exception:
            return p.returncode, {'error': 'queue-output', 'reason': (p.stdout or p.stderr or '').strip()[:200]}
    except Exception as _e:
        return 1, {'error': 'queue-unavailable', 'reason': str(_e)[:200]}

def _vault_queue():
    if os.environ['KIND'] != 'pr':
        return None
    vl = classify.get('vaultLink') or {}
    slug = vl.get('repo')
    if vl.get('status') != 'REGISTERED' or not slug:
        return None          # 미등록·EXEMPT·SELF·UNKNOWN 은 대기 목록 대상이 아니다 — 파일도 만들지 않는다
    global VQS
    VQS = _queue_script(classify)
    res = {'repo': slug}
    _vs = lanes.get('vault-sync')
    _vst = (_vs.get('status') if isinstance(_vs, dict) else _vs) or ''
    if _vst and _vst not in ('SKIPPED', 'NOT_APPLICABLE'):
        o = lane_outputs.get('vault-sync') if tdir else None
        if not tdir:
            res.update(written=0, unrecorded=None, reason='no-transcripts')
        elif not isinstance(o, dict) or not isinstance(o.get('drifts'), list):
            res.update(written=0, unrecorded=None, reason='no-drifts-output')
        else:
            src = vl.get('source') or {}
            items = [{'note': d.get('note') or vl.get('note'), 'field': d.get('field'), 'current': d.get('current'),
                      'proposed': d.get('proposed'), 'evidence': d.get('evidence') or {}, 'kind': d.get('kind'),
                      'findingId': d.get('id'), 'summary': d.get('summary'), 'branch': os.environ.get('BRANCH'),
                      'baseline': src.get('sha') if src.get('mode') == 'remote' else None,
                      'recordedAt': int(os.environ['TS'])}
                     for d in o['drifts'] if isinstance(d, dict)]
            if items:
                rc, r = _vq('add', slug, '-', '--now', os.environ['TS'], inp=_json_out(items))
                if rc == 0:
                    res.update(written=len(items), added=r.get('added'), replaced=r.get('replaced'), total=r.get('total'))
                else:
                    res.update(written=0, unrecorded=len(items), reason=r.get('error') or 'queue-failed',
                               detail=r.get('reason'))
            else:
                res.update(written=0)
    # 경고(R7) — 네트워크 없이 대기 목록과 이 체크아웃의 영수증만 읽는다.
    rc, w = _vq('warn', slug, '--receipt', os.environ['R'], '--now', os.environ['TS'])
    if rc == 0 and w.get('warn'):
        res['warn'] = {k: w.get(k) for k in ('count', 'oldestDate', 'ageDays', 'mergedApprox')}
    elif rc != 0:
        res['warnError'] = w.get('reason') or w.get('error')
    return res

try:
    vq = _vault_queue()
except Exception as _e:   # 대기 목록 처리의 예외가 기록 결과를 뒤집지 않는다
    vq = {'repo': (classify.get('vaultLink') or {}).get('repo'), 'written': 0, 'unrecorded': None,
          'reason': 'queue-exception', 'detail': str(_e)[:200]}
skipped = [k for k, v in lanes.items() if (v.get('status') if isinstance(v, dict) else v) != 'PASS']
_waived = [k for k, v in lanes.items() if isinstance(v, dict) and v.get('waived')]
# 이름만 남기면 나중에 못 센다 — 기록 43건에서 lane 결함의 발생 횟수를 세려다 전부 '?' 였다.
# 사유는 160자로 잘라 담는다.
_detail = {}
for _k, _v in lanes.items():
    if isinstance(_v, dict):
        _e = {'status': _v.get('status')}
        if _v.get('reason'): _e['reason'] = str(_v['reason'])[:160]
        if _v.get('waived'): _e['waived'] = True; _e['originalStatus'] = _v.get('originalStatus')
        _detail[_k] = _e
    else:
        _detail[_k] = {'status': _v}
_log('record', 'recorded',
     required=procedure['required'], recorded=procedure['recorded'],
     extraLanes=procedure['extraLanes'], notRun=sorted(skipped), waived=_waived,
     laneDetail=_detail,
     evidence={k: {'calls': v['calls'], 'errors': v['errors'], 'live': v.get('live', 0),
                   'originReads': v.get('originReads', 0)}
               for k, v in (evidence or {}).items()} or None,
     plan=_plan().get('status'),
     files=len(((classify.get('files') or {}).get('all')) or []),
     worktreeDiff=(len(wt_diff) if wt_diff is not None else None),
     classificationId=classify.get('classificationId'),
     **({'vaultQueue': vq} if vq else {}))
_p = _plan()
print(f"recorded: {os.environ['KIND']} gate — indexTree {os.environ['IT'][:8]}"
      + (f" · plan {_p.get('planId') or _p['status']}" if _p['status'] != 'NONE' else " · plan 없음")
      + (f" · lanes {len(lanes)}개" if lanes else " · lanes 미기록(권장하지 않음)")
      + (f" · 미실행 {', '.join(skipped)}" if skipped else ""))
if vq:
    _REASON = {'lock-timeout': None, 'io-error': '대기 목록에 쓰지 못했다', 'no-transcripts': '전사를 넘기지 않아 드리프트를 읽지 못했다',
               'no-drifts-output': '전사의 vault-sync 출력에 drifts 가 없다'}
    if vq.get('reason'):
        _why = vq.get('detail') if vq['reason'] == 'lock-timeout' else (_REASON.get(vq['reason']) or vq.get('detail') or '')
        _n = vq.get('unrecorded')
        print(f"⚠️ vault 대기 목록: 드리프트 {('?' if _n is None else _n)}건이 대기 목록에 기록되지 않음 — {vq['reason']}"
              + (f" ({_why})" if _why else '') + f" · {vq['repo']}")
    elif vq.get('written'):
        print(f"vault 대기 목록: {vq['repo']} 드리프트 {vq['written']}건 적재 (새 {vq.get('added')} · 갱신 {vq.get('replaced')} · 총 {vq.get('total')})"
              " — 노트 반영은 일괄 반영 진입점(vault-batch-sync)에서 한다")
    if vq.get('warn'):
        _w = vq['warn']
        print(f"⚠️ vault 미반영 {_w['count']}건 ({vq['repo']}) — 가장 오래된 기록 {_w['oldestDate']} ({_w['ageDays']}일 전) · "
              f"그 뒤 PR 게이트 기록 {_w['mergedApprox']}건 (머지 수 근사 — 이 체크아웃의 로컬 게이트 기록으로 센다). "
              "vault-batch-sync 로 일괄 반영해라 (기준: 머지 3건 또는 7일)")
if qa_written:
    _c = _qrec['coverage']
    print(f"QA 기록: {qa_written}"
          + (f" · 계획 항목 {len(_c['planned'])}개 중 통과 {len(_c['passed'])} · 실패 {len(_c['failed'])}"
             f" · 미실행 {len(_c['notRun'])} · 덮이지 않음 {len(_c['missing'])}" if _c['planned'] else " · 계획 항목 없음")
          + (f" · 계획에 없는 참조 {', '.join(_c['unknown'])}" if _c['unknown'] else ""))
elif os.environ['KIND'] == 'commit' and ((lanes.get('qa-runner') or {}).get('status') if isinstance(lanes.get('qa-runner'), dict)
                                         else lanes.get('qa-runner')) not in (None, 'SKIPPED', 'NOT_APPLICABLE'):
    # 남지 않은 이유를 말한다 — 조용히 없으면 PR 시점에 "QA 를 안 했다" 와 구분되지 않는다.
    print("QA 기록 없음 — " + (qa_skip or ("전사를 넘기지 않았다 (시나리오는 전사에서만 읽는다)" if not tdir
                                          else "전사의 QA 출력에 scenarios 가 없다")))
# 막지 않되 보인다 (#8 R18·D4) — 차이가 없으면 아무것도 출력하지 않는다.
if wt_diff:
    print(f"참고 — 인덱스와 워킹트리 내용이 다른 경로 {len(wt_diff)}개 (이번 커밋에는 인덱스 쪽이 들어간다):")
    for f in wt_diff[:20]: print(f"    {_disp(f)}")
    if len(wt_diff) > 20: print(f"    … 외 {len(wt_diff) - 20}개")
    print("  고친 뒤 `git add` 를 잊은 내 파일이 있으면 add 하고 classify.sh 부터 다시 실행해라 (분류 뒤 인덱스가 바뀌면 재분류).")
PY
    ;;
report)
    # 머지 확인을 요청할 때 함께 보이는 한 덩어리 (SKILL § 0). 판정하지 않고 기록된 것을 말한다.
    # 브랜치를 넘길 수 있다 — 머지 뒤 base 로 돌아온 다음에도 머지한 브랜치의 기록을 보인다.
    # 그때 "기록 뒤 커밋" 비교도 **그 브랜치의 끝**과 한다 — 체크아웃의 HEAD 와 비교하면 base 커밋이라
    # 늘 거짓 경고가 난다. 로컬 브랜치가 없으면 끝을 모르므로 비교하지 않는다(모르는 것을 단정하지 않는다).
    [ "$kind" = pr ] || { echo "usage: receipt.sh report pr <dir> [branch] — 머지 보고는 PR 게이트 기록만 읽는다" >&2; exit 2; }
    _tip="${4:+refs/heads/$4}"
    R="$receipt" DIR="$dir" CUR_HEAD="$(git -C "$dir" rev-parse --verify -q "${_tip:-HEAD}" 2>/dev/null)" \
    PF_CATS="$(pf_category_roots)" \
    BRANCH="${4:-$(pf_branch "$dir")}" python3 - <<'PY'
import json, os, re, subprocess
try:
    data = json.load(open(os.environ['R']))
except Exception:
    data = {}
e = ((data.get('branches') or {}).get(os.environ['BRANCH']) or {}).get('pr')
if not e:
    print("머지 보고: 이 브랜치에 PR 게이트 기록이 없다 — PR 게이트를 먼저 돌려라"); raise SystemExit(0)
lines = []
t = e.get('trace') or {}
if t.get('plan') == 'FOUND':
    head = f"계획 {t.get('planId')} ({'승인됨' if t.get('approval') == 'APPROVED' else '미승인' if t.get('approval') == 'NONE' else t.get('approval')})"
    if t.get('closed') is None:
        lines.append(f"{head}: claim {t.get('total')}개 — 닫힘을 셀 수 없다 ({t.get('reason')})")
    else:
        op = t.get('open') or []
        lines.append(f"{head}: claim {t.get('total')}개 중 {t.get('closed')}개 닫힘"
                     + (" · 열림: " + ", ".join(f"{o['id']}({o['why']})" for o in op) if op else "")
                     + (f" · 계획에 없는 보고: {', '.join(t['unknown'])}" if t.get('unknown') else ""))
else:
    adv = (e.get('classification') or {}).get('planAdvisory')
    lines.append(("계획 없음" + (" — 고위험 변경이다" if adv else "")) if t.get('plan') in (None, 'NONE')
                 else f"계획 상태 {t.get('plan')} — 추적하지 못했다")
# 기록에 없는 것을 말하지 않는다. "실행됨" 의 기준은 record 의 `ran` 과 같다 — 기록된 lane 상태가
# SKIPPED·NOT_APPLICABLE 이 아닐 때만. 분류에 선택됐다는 것만으로는 실행이 아니다.
#   분류 사유 있음 → 그 사유 · 실행 상태 → 실행됨(상태) · 건너뜀 상태 → 건너뜀(사유) · 아무것도 없음 → 기록 없음
cls = e.get('classification') or {}
qa = (cls.get('notSelected') or {}).get('qa-runner')
_ql = (e.get('lanes') or {}).get('qa-runner')
_qs = (_ql.get('status') if isinstance(_ql, dict) else _ql) or ''
if qa:
    _qline = qa.split(' ')[0]
elif _qs and _qs not in ('SKIPPED', 'NOT_APPLICABLE'):
    _qline = f'이 PR 게이트에서 실행됨 ({_qs})'
elif _qs:
    _qline = f"건너뜀 ({(_ql.get('reason') if isinstance(_ql, dict) else '') or _qs})"
else:
    _qline = '기록 없음'
lines.append("QA: " + _qline)
# vault 미반영 N건 — 등록 레포만. N 은 **보고 시점** 대기 목록의 항목 수다(반영 중 포함 — 반영 vault PR 이
# 머지돼야 빠진다). 미등록·EXEMPT·SELF·UNKNOWN 은 대기 목록 대상이 아니라 줄을 내지 않는다.
_vl = cls.get('vaultLink') or {}
if _vl.get('status') == 'REGISTERED' and _vl.get('repo'):
    try:
        _c = cls.get('category')
        _s = (next((q for q in (os.path.join(r, _c, 'vault-queue.sh') for r in os.environ['PF_CATS'].split(':') if r)
                    if os.path.isfile(q)), '')
              if isinstance(_c, str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', _c) else '')
        _p = subprocess.run([_s, 'count', _vl['repo']], capture_output=True, text=True, timeout=30)
        _n = _p.stdout.strip() if _p.returncode == 0 and _p.stdout.strip().isdigit() else None
    except Exception:
        _n = None
    lines.append(f"vault 미반영 {_n}건 ({_vl['repo']}) — 일괄 반영: vault-batch-sync" if _n is not None
                 else f"vault 미반영: 대기 목록을 읽지 못했다 ({_vl['repo']})")
if os.environ.get('CUR_HEAD') and e.get('head') and os.environ['CUR_HEAD'] != e['head']:
    lines.append(f"⚠️ PR 게이트 기록({e['head'][:8]}) 뒤에 커밋이 있다(현재 {os.environ['CUR_HEAD'][:8]}) — 위 내용은 그 기록 시점이다")
print("\n".join(lines))
PY
    ;;
verify)
    # 영수증이 없으면 트리를 굳힐 이유가 없다. 로깅은 파이썬이 하되(가장 흔한 deny 라
    # 로그에 남아야 한다) write-tree 부수효과는 만들지 않는다 — deny 마다 .git/objects 에
    # 도달 불가 객체가 하나씩 쌓였다.
    if [ -f "$receipt" ]; then it=$(index_tree); else it=""; fi
    branch=$(pf_branch "$dir")
    head=$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null || echo '')
    KIND="$kind" OKMODES="$(pf_ok_modes "$kind")" IT="$it" BRANCH="$branch" HEAD_SHA="$head" R="$receipt" DIR="$dir" REPO_TOP="$repo_top" python3 - <<'PY'
import json, os, sys, time

# CONTRACT: json-out-is-one-function — 위 record 블록과 같은 이유다 (비UTF-8 경로).
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

def _log(outcome, **kw):
    try:
        rec = {'ts': int(time.time()), 'event': 'verify', 'outcome': outcome,
               'kind': os.environ.get('KIND'), 'repo': os.environ.get('REPO_TOP') or os.environ.get('DIR'),
               'branch': os.environ.get('BRANCH')}
        rec.update(kw)
        path = os.path.expanduser(os.environ.get('PF_LOG') or '~/.claude/preflight-log.jsonl')
        with open(path, 'a') as f:
            f.write(_json_out(rec) + '\n')
    except Exception:
        pass

# CONTRACT: deny-hints-name-no-reason
# 거부 문구는 **무엇을 하라**(분류부터 다시)만 말한다 — 어느 사유로 거부될지는 조작자가
# 다음에 무엇을 하느냐에 달려 예측할 수 없다. 실측(2026-09-11): incomplete-lanes 2 ·
# recorded 3 · 후속 없음 1, 예측했던 stale-classification 은 0.
# 재현: verify·denied 중 '인덱스 트리 불일치' 를 잡고 **같은 repo 의** 다음 record 를 센다.

def _deny(reason, **kw):
    print(reason); _log('denied', reason=reason, **kw); sys.exit(1)

# CONTRACT: no-receipt-is-logged
# 파일 부재를 셸에서 먼저 끊으면 로그에 닿지 못한다 — 실사용에서 가장 흔한 deny 가 통째로
# 안 보였다. 파이썬까지 내려보내 _deny 로 처리한다.
if not os.path.exists(os.environ['R']):
    _deny("게이트 실행 기록 없음 — classify.sh 부터 게이트를 돌려라")
try:
    with open(os.environ['R']) as f: data = json.load(f)
except Exception:
    _deny("게이트 기록을 읽을 수 없음")
kind = os.environ['KIND']; branch = os.environ['BRANCH']
if 'branches' not in data:
    _deny("구 버전 게이트 기록 (브랜치별 스키마 이전) — classify.sh 부터 게이트를 다시 돌려라")
rec = (data['branches'].get(branch) or {}).get(kind)
if not rec:
    others = [b for b, e in data['branches'].items() if kind in e and b != branch]
    hint = f" (기록이 있는 다른 브랜치: {', '.join(others[:3])})" if others else ""
    _deny(f"이 브랜치의 {kind} 게이트 기록이 없다{hint}. classify.sh 부터 게이트를 돌려라")
if 'indexTree' not in rec:
    _deny("구 버전 게이트 기록 (스키마 v1 — indexTree 없음) — classify.sh 부터 게이트를 다시 돌려라")
if time.time() - rec.get('ts', 0) > 86400:
    _deny(f"게이트 기록이 오래됨 ({int((time.time()-rec.get('ts',0))/3600)}시간 전) — classify.sh 부터 게이트를 다시 돌려라")

OK = {'PASS', 'SKIPPED', 'NOT_APPLICABLE'}
for name, v in (rec.get('lanes') or {}).items():
    st = v.get('status') if isinstance(v, dict) else v
    if st not in OK: _deny(f"lane[{name}]={st} — 통과하지 못한 게이트")
    if isinstance(v, dict) and v.get('waived'):
        print(f"  · lane[{name}] 은 {v.get('originalStatus')} 를 사람이 승인해 통과: {v.get('reason')}")

# record 를 거치지 않고 영수증 파일을 직접 써 넣는 경로가 있다. 기록 시점 검사만으로는
# 그걸 못 잡으므로, 훅이 읽는 이 자리에서 완전성을 한 번 더 본다.
cl = rec.get('classification') or {}
if not cl:
    _deny("분류 근거가 없는 기록 — receipt.sh record 를 거치지 않았다")
# 저장된 분류가 **이 기록**의 것인가 — record 의 결속을 여기서 다시 본다(#2). 필수 lane 집합을
#  저장된 분류에서 뽑으므로, 이 검사가 그 계산보다 앞서야 한다: kind=pr 칸에 commit 분류가 있으면
#  pr-quality·vault-sync 가 필수 집합에 애초에 없어 아래 완전성 검사가 자기일관적으로 통과한다.
#  모드 허용 규칙은 record 와 같은 출처다 — CONTRACT: ok-modes-is-one-function (lib.sh).
#  head·branch 는 기록 시점의 런타임 값(rec.head)과 대조한다. rec.head 가 비면(커밋 없는 레포)
#  record 도 요구하지 않으므로 여기서도 요구하지 않는다.
if cl.get('mode') not in (os.environ.get('OKMODES') or '').split():
    _deny(f"기록의 분류가 다른 모드의 것이다 ({cl.get('mode') or '없음'} → {kind}) — classify.sh 부터 게이트를 다시 돌려라",
          code='mode-mismatch')
_rh = rec.get('head') or ''
if _rh and cl.get('head') != _rh:
    _deny("기록의 분류가 다른 커밋 위의 것이다 — classify.sh 부터 게이트를 다시 돌려라", code='stale-head')
if _rh and cl.get('branch') != branch:
    _deny("기록의 분류가 다른 브랜치의 것이다 — classify.sh 부터 게이트를 다시 돌려라", code='branch-mismatch')
req = list(cl.get('selected') or {})
for chain in (cl.get('sequential') or []):
    req += [l for l in chain if l not in req]
gap = [l for l in req if l not in (rec.get('lanes') or {})]
if gap:
    _deny("분류가 요구한 lane 이 기록에 없다: " + ', '.join(gap), missing=gap)

if kind == 'commit':
    if rec.get('indexTree') != os.environ['IT']:
        _deny("커밋될 내용이 게이트 통과 시점과 다르다 (인덱스 트리 불일치) — classify.sh 부터 게이트를 다시 돌려라")
else:
    # 영수증이 브랜치별이라 "남의 브랜치 기록" 은 위에서 이미 걸러진다. 남는 건 커밋 변경뿐이다.
    if rec.get('head') != os.environ['HEAD_SHA']:
        _deny("PR 게이트 통과 후 커밋이 바뀌었다 — classify.sh 부터 다시 돌려라")
_log('allowed', lanes=sorted((rec.get('lanes') or {})),
     waived=[k for k, v in (rec.get('lanes') or {}).items() if isinstance(v, dict) and v.get('waived')],
     gateAgeSec=int(time.time() - rec.get('ts', 0)))
sys.exit(0)
PY
    ;;
*) echo "usage: receipt.sh {record|verify|report} [commit|pr] [dir] [lanes-json]" >&2; exit 2 ;;
esac
