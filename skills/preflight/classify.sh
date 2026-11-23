#!/bin/bash
# preflight classify — 무엇이 바뀌었는지로 lane 을 결정론적으로 고른다.
#
# 왜 스크립트인가: lane 선택을 LLM 판단에 두면 같은 변경에 대해 실행마다 다른 lane 이 돈다.
# 특히 "공개 타입 표면"(@types/tsconfig.build.json 의 include 가 전이적으로 닿는 소스)은
# import 그래프로 정확히 **계산되는** 값이지 추론할 값이 아니다.
#
# usage: classify.sh <dir> [commit|pr|all] [--qa] [--review] [--body-file=<PR 본문 초안>] [--msg-file=<커밋 메시지 초안>]
#   stdout : 분류 JSON
#   또한 <gitdir>/claude-preflight.classify.json 에 같은 내용을 쓴다 (receipt 가 자동으로 읽는다).
#   쓰기를 마치면 쓴 바이트(stdout 과 같다)의 sha256 을 stderr 에 `classify-sha256: <hex>` 한 줄로 낸다 —
#   큰 분류를 데이터 스크립트로 넘길 때(SKILL.md pf_gate_args → preflight.js classification-load) 이 값으로 내용을 대조한다.
# usage: classify.sh <dir> category      — 카테고리 조회(category.sh 가 부른다). 읽기 전용, commit 모드 입력.
#
# 카테고리: 대상 레포의 성격별 규칙은 categories/<이름>/rules.py 에 있고 이 파일은 카테고리 이름을 모른다.
#   선언은 categories/categories.json 이다. 둘 이상에 걸리거나 적재에 실패하면 분류하지 않고 끝난다(exit 3).
#
# 판정 한계 — 숨기지 말고 남긴다:
#   codeLogicChange 는 diff 의 추가·삭제 라인이 전부 주석/공백인지로 보는 휴리스틱이다.
#   판단이 안 서면 **true 로 기울인다** — lane 을 덜 도는 쪽이 아니라 더 도는 쪽이 안전하다.
set -uo pipefail

dir="${1:-$PWD}"; mode="${2:-commit}"; qa=0; review=0; body_file=''; msg_file=''
for _flag in "${@:3}"; do
    case "$_flag" in
        --qa) qa=1 ;;
        --review) review=1 ;;
        # PR 본문만 고친 라운드도 라운드다 — 본문 초안을 받아야 집계에 보인다 (round 이벤트 전용).
        --body-file=?*) body_file="${_flag#--body-file=}" ;;
        # 커밋 메시지 초안 — 사실 주장 검사(claimCheck)만 읽는다. PR 모드는 커밋에서 직접 읽는다.
        --msg-file=?*) msg_file="${_flag#--msg-file=}" ;;
        # 빈 인자도 거부한다. 인자가 2개면 이 루프는 돌지 않으므로, 빈 문자열이 오는 것은
        # 호출자가 `commit "$MAYBE_REVIEW"` 처럼 **미설정 변수를 넘긴** 경우뿐이다 — 조용히
        # 봐주면 리뷰를 붙였다고 믿는데 안 도는, 이 플래그의 최악 실패 모드가 그대로 산다.
        *) echo "알 수 없는 플래그: '$_flag' (쓸 수 있는 것: --qa, --review, --body-file=<경로>, --msg-file=<경로>)" >&2; exit 2 ;;
    esac
done
case "$mode" in commit|pr|all|category) ;; *) echo "mode 는 commit|pr|all|category 이다: $mode" >&2; exit 2 ;; esac
[ "$mode" = category ] && [ $# -gt 2 ] && { echo "category 조회는 플래그를 받지 않는다: ${*:3}" >&2; exit 2; }

gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || { echo "not a git repo: $dir" >&2; exit 1; }
out="$gitdir/claude-preflight.classify.json"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" GITDIR="$gitdir" ENGINE_VER="$(pf_engine_version)" OVERLAY="$(pf_overlay_dir)" \
PF_BRANCH="$(pf_branch "$dir")" DIR="$dir" MODE="$mode" QA="$qa" REVIEW="$review" OUT="$out" BODY_FILE="$body_file" MSG_FILE="$msg_file" python3 - <<'PY'
import json, os, posixpath, re, shlex, subprocess, sys, time
from pathlib import Path

DIR = os.environ['DIR']; MODE = os.environ['MODE']; QA = os.environ['QA'] == '1'
REVIEW = os.environ['REVIEW'] == '1'

# `-z` 로 원시 바이트가 들어오므로 UTF-8 이 아닌 파일명(Linux 체크아웃에서 가능하다)에서
# strict 디코딩이 분류기를 통째로 죽인다. surrogateescape 는 그 바이트를 보존하고,
# argv 로 git 에 되넘길 때 원래 바이트로 복원된다.
_DEC = {'encoding': 'utf-8', 'errors': 'surrogateescape'}

# CONTRACT: json-out-is-one-function — 정본은 lib.sh. JSON 을 쓰는 자리는 전부 여기를 지난다.
def _json_out(obj, **kw):
    s = json.dumps(obj, ensure_ascii=False, **kw)
    try:
        s.encode('utf-8')
    except UnicodeEncodeError:
        s = json.dumps(obj, ensure_ascii=True, **kw)
    return s

def git(*a):
    p = subprocess.run(['git', '-C', DIR, *a], capture_output=True, **_DEC)
    return p.stdout if p.returncode == 0 else ''

def git_z(*a):
    """NUL 구분(`-z`) 목록. lib.sh 의 CONTRACT: git-paths-read-with-z.

    여기서만 다른 실패 모드: 닫는 따옴표 때문에 확장자·최상위 폴더 판정(`is_code`·
    `is_vault_doc`)이 빗나가 lane 선택이 통째로 비었다.
    """
    return [x for x in git(*a).split('\0') if x]

root = git('rev-parse', '--show-toplevel').strip()
if not root:
    print(_json_out({'error': 'not a git repo'})); sys.exit(1)
R = Path(root)
_head_p = subprocess.run(['git', '-C', DIR, 'rev-parse', '--verify', '-q', 'HEAD'],
                         capture_output=True, text=True)
has_head = _head_p.returncode == 0
# 이 분류가 어느 커밋 위의 것인가 — record 가 대조한다. 근거는 receipt.sh 의 stale-head 검사.
head_sha = (_head_p.stdout or '').strip() if has_head else ''

# ── base 브랜치 해석 (PR 모드의 변경 범위, 두 모드의 테스트 기준선). origin/HEAD 를 진실원으로 쓴다 —
#    레포마다 develop/master 가 갈리므로 이름을 코드에 박지 않는다.
def resolve_base():
    ref = git('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD').strip()
    if ref.startswith('refs/remotes/'):
        return ref[len('refs/remotes/'):]
    for cand in ('origin/develop', 'origin/master', 'origin/main'):
        if git('rev-parse', '--verify', '--quiet', cand).strip():
            return cand
    return ''

base_ref, base_merge, base_err = '', '', ''
if MODE == 'pr' and has_head:
    base_ref = resolve_base()
    if not base_ref:
        base_err = 'origin/HEAD 도 origin/develop|master|main 도 없다 — 첫 커밋부터 HEAD 까지 전부를 본다'
    else:
        base_merge = git('merge-base', base_ref, 'HEAD').strip()
        if not base_merge:
            base_err = f'{base_ref} 와 HEAD 의 merge-base 를 못 구했다 (fetch 누락?) — 첫 커밋부터 HEAD 까지 전부를 본다'

# ── 검사 대상(스냅숏): 커밋 모드는 **커밋될 인덱스**, PR 모드는 **base..HEAD 의 커밋** (#8 D1).
#    워킹트리에만 있는 수정과 인덱스에 없는 미추적 파일은 커밋되지 않으므로 대상이 아니다 —
#    다른 세션의 미스테이징 파일이 이 커밋의 lane 선택을 바꾸지 않는다. 미추적 파일은 개수만 싣는다(D2).
#    `DIFF` 는 "base 대 스냅숏" 비교 인자다 — 변경 목록·로직 판정·QA 줄 수가 전부 이것을 쓴다.
# base 를 못 구하면 PR 이 무엇을 담는지 모른다 — 덜 보는 쪽(빈 집합)이 아니라 더 보는 쪽(빈 트리부터
# 전부)으로 떨어진다. 커밋 모드의 기준은 늘 HEAD 다.
EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
diff_from = base_merge if base_merge else (EMPTY_TREE if MODE == 'pr' and has_head else 'HEAD')
DIFF = [diff_from, 'HEAD'] if MODE == 'pr' else ['--cached', 'HEAD']
if has_head:
    changed = sorted(set(git_z('diff', *DIFF, '--no-renames', '--name-only', '-z')))
else:
    changed = sorted(set(git_z('ls-files', '-z'))) if MODE != 'pr' else []
untracked_count = len(git_z('ls-files', '--others', '--exclude-standard', '-z'))   # worktree-listing-ok: 개수만 싣는다(D2) — 경로는 버린다

# 스냅숏의 파일 목록과 내용. 내용 판정(R6)은 워킹트리(`R / 경로`)가 아니라 여기서 읽는다 —
# 인덱스와 워킹트리가 다를 때 커밋될 쪽으로 판정해야 한다. 파일을 풀어 쓰지 않고 블롭을 읽는다.
_SNAP_REV = 'HEAD' if MODE == 'pr' else ''          # '' 는 인덱스(`:경로`)다
SNAP = set(git_z('ls-tree', '-r', '--name-only', '-z', 'HEAD') if MODE == 'pr' and has_head
           else [] if MODE == 'pr' else git_z('ls-files', '-z'))
# 회귀 명령 안의 스냅숏 경로 자리. 워크플로가 snapshot.sh 로 만든 경로로 바꿔 넣는다(preflight.js 와 같은 값).
SNAP_TOKEN = '<스냅숏>'
def snap_has(rel):
    return rel in SNAP
def snap_read(rel):
    return git('cat-file', 'blob', f'{_SNAP_REV}:{rel}') if rel in SNAP else None
def snap_under(prefix, suffixes):
    """prefix/ 아래(깊이 무관)에서 suffixes 로 끝나는 스냅숏 파일이 있는가."""
    return any(f.startswith(prefix + '/') and f.endswith(suffixes) for f in SNAP)

def _vgit(vd, *a, timeout=30):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    p = subprocess.run(['git', '-C', vd, *a], capture_output=True, env=env, timeout=timeout, **_DEC)
    return p.returncode, p.stdout, p.stderr.strip()

# ── 카테고리 (#47). 레포 성격별 규칙은 categories/<이름>/rules.py 에 있고, 엔진(이 파일)은 이름을 모른다.
# 선언(categories/categories.json)과 디렉터리가 어긋나면 분류하지 않는다 — 디렉터리 하나가 설치에서 빠지면
# 그 레포가 조용히 "카테고리 없음" 이 되어 관례·QA·등록 검사가 빠진다(더 도는 쪽 원칙, I7).
# 소속 판정은 rules.py 의 match(ctx) 다: 근거 신호 목록을 내고, 비었으면 비소속이다. 둘 이상이면 오류다.
# 그 밖의 규칙은 전부 선택 사항이고, 소속 카테고리에 없으면 엔진이 "카테고리 비해당" 사유로 남긴다:
#   vault_docs(ctx, files) · ALL_MODE_FORCED · DEP_KEY_EXTRA · convention(ctx, lane) · vault_link(ctx) ·
#   VAULT_SYNC · qa_meta(ctx) · QA_HINT{'commit','pr'} · suites(ctx, changed) · vault_dir_fallback(ctx) ·
#   SECRET_SCAN('auto'|'always', 없으면 'always') · SECRET_SENSITIVE_EXTRA(민감 경로 glob 튜플 — secret-scan.sh 가 읽는다)
# 절차 요구는 categories/<이름>/procedures.json 이다 — 조회(category 모드)가 낸다.
# 이 판정은 category 모드(조회)와 분류가 **같은 코드**로 내린다 — 두 곳에서 갈리지 않게.
# 카테고리 루트는 둘일 수 있다: 엔진의 categories/ 와 오버레이의 categories/(lib.sh pf_overlay_dir).
# 루트마다 선언과 디렉터리가 맞아야 하고, 이름이 루트 사이에서 겹치면 적재 실패다(어느 쪽 규칙인지 모른다).
# 선언의 `fallback`(선택, 전체에서 하나)은 어느 카테고리에도 신호가 없을 때만 소속되는 기본 카테고리다 —
# match 로 모든 레포에 걸게 하면 다른 카테고리와 늘 겹친다(겹침은 풀지 않는다). fallback 의 match 는 부르지 않는다.
import importlib.util, types
sys.dont_write_bytecode = True            # 설치본 categories/ 아래에 __pycache__ 를 만들지 않는다
CATROOT = Path(os.environ['SELFDIR']) / 'categories'
OVERLAY = os.environ.get('OVERLAY', '')
CATROOTS = [CATROOT]
CAT_FALLBACK = None

def _cat_fail(msg):
    print(f'카테고리 적재 실패 — {msg}. 분류하지 않는다 (설치본의 skills/preflight/categories 를 확인해라).',
          file=sys.stderr)
    sys.exit(3)

def _load_decl(root):
    global CAT_FALLBACK
    decl = root / 'categories.json'
    if not root.is_dir():
        _cat_fail(f'{root} 가 없다')
    try:
        dj = json.loads(decl.read_text())
        names = dj['categories']
    except Exception as e:
        _cat_fail(f'선언 {decl} 을 읽지 못했다 ({type(e).__name__}: {e})')
    if not (isinstance(names, list) and names and all(isinstance(n, str) and n for n in names)
            and len(set(names)) == len(names)):
        _cat_fail(f'선언 {decl} 의 categories 는 비지 않은 고유 이름 목록이어야 한다')
    if set(dj) - {'categories', 'fallback'}:
        _cat_fail(f'선언 {decl} 의 키는 categories·fallback 뿐이다')
    if 'fallback' in dj:
        if dj['fallback'] not in names:
            _cat_fail(f'선언 {decl} 의 fallback {dj["fallback"]!r} 는 같은 선언의 카테고리가 아니다')
        if CAT_FALLBACK is not None:
            _cat_fail(f'fallback 이 둘이다 ({CAT_FALLBACK}, {dj["fallback"]}) — 전체에서 하나만 둔다')
        CAT_FALLBACK = dj['fallback']
    try:
        dirs = sorted(e.name for e in root.iterdir() if e.is_dir())
    except Exception as e:
        _cat_fail(f'{root} 를 읽지 못했다 ({e})')
    extra = sorted(set(dirs) - set(names))
    if extra:
        _cat_fail(f'선언되지 않은 카테고리 디렉터리가 있다: {", ".join(extra)}')
    return [(n, root / n) for n in names]

def _load_categories():
    if OVERLAY:
        if not Path(OVERLAY).is_dir():
            _cat_fail(f'오버레이 {OVERLAY} 가 디렉터리가 아니다 (PF_OVERLAY_DIR 또는 config.json 의 overlayDir)')
        if (Path(OVERLAY) / 'categories').exists():
            CATROOTS.append(Path(OVERLAY) / 'categories')
    pairs = []
    for root in CATROOTS:
        pairs += _load_decl(root)
    seen = [n for n, _ in pairs]
    dup = sorted({n for n in seen if seen.count(n) > 1})
    if dup:
        _cat_fail(f'카테고리 이름이 엔진과 오버레이에서 겹친다: {", ".join(dup)}')
    cats = []
    for i, (n, d) in enumerate(pairs):
        if not d.is_dir():
            _cat_fail(f'선언된 카테고리 {n} 의 디렉터리가 없다')
        try:
            spec = importlib.util.spec_from_file_location(f'pf_category_{i}', d / 'rules.py')
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:
            _cat_fail(f'{n}/rules.py 를 적재하지 못했다 ({type(e).__name__}: {e})')
        if not callable(getattr(mod, 'match', None)):
            _cat_fail(f'{n}/rules.py 에 match(ctx) 가 없다')
        try:
            procs = json.loads((d / 'procedures.json').read_text())['procedures']
            assert isinstance(procs, list) and all(isinstance(x, dict) and x.get('id') and x.get('text') for x in procs)
        except Exception as e:
            _cat_fail(f'{n}/procedures.json 을 읽지 못했다 ({type(e).__name__}: {e})')
        cats.append((n, d, mod, procs))
    return cats

def _vault_dir():
    # vault 위치를 정하는 곳은 여기 하나다 — 연결 판정과 설계 문서 드리프트가 같은 vault 를 본다.
    # 환경변수·config.json 이 없을 때의 폴백은 소속 카테고리의 규칙이다(vault_dir_fallback).
    vd = os.environ.get('VAULT_DIR') or ''
    if not vd:
        cfg = Path(os.environ.get('SELFDIR', '.')) / 'config.json'
        try:
            vd = json.loads(cfg.read_text()).get('vaultDir') or ''
        except Exception:
            vd = ''
    if not vd and _rule('vault_dir_fallback'):
        vd = _rule('vault_dir_fallback')(ctx) or ''
    return vd

ctx = types.SimpleNamespace(root=R, dir=DIR, mode='commit' if MODE == 'category' else MODE, qa=QA,
                            selfdir=os.environ['SELFDIR'], catdir=None, snap_token=SNAP_TOKEN,
                            snap_has=snap_has, snap_read=snap_read, snap_under=snap_under,
                            git=git, vgit=_vgit, vault_dir=_vault_dir)
CATS = _load_categories()
_hits = []
for _n, _d, _mod, _procs in CATS:
    if _n == CAT_FALLBACK:
        continue
    try:
        _ev = _mod.match(types.SimpleNamespace(**{**vars(ctx), 'catdir': _d}))
    except Exception as e:
        _cat_fail(f'{_n}/rules.py match() 가 죽었다 ({type(e).__name__}: {e})')
    if _ev:
        _hits.append((_n, _d, _mod, _procs, [str(x) for x in _ev]))
if len(_hits) > 1:
    print('카테고리 판정이 겹친다 — 대상 레포는 카테고리 하나에만 속해야 한다: '
          + ', '.join(h[0] for h in _hits) + '. 분류하지 않는다.', file=sys.stderr)
    for _h in _hits:
        print(f'  {_h[0]}: ' + '; '.join(_h[4]), file=sys.stderr)
    sys.exit(3)
if not _hits and CAT_FALLBACK:
    _hits = [(_n, _d, _mod, _procs, ['fallback — 다른 카테고리의 신호가 없다'])
             for _n, _d, _mod, _procs in CATS if _n == CAT_FALLBACK]
CAT_NAME, _CAT_DIR, CAT, _CAT_PROCS, CAT_EVIDENCE = _hits[0] if _hits else (None, None, None, [], [])

# ── 프로필 (#47 셋째 층). 레포 하나에 붙는 설정 — profiles/<owner>/<repo>.json(소문자), 키는 origin 슬러그다.
# 프로필의 카테고리는 신호 추론을 **고정**한다: 둘이 다르면(신호가 다른 카테고리·신호 없음) 분류·조회가 exit 3 이다.
# 신호가 바뀌어 레포가 조용히 다른 카테고리나 "카테고리 없음" 이 되면 그 카테고리의 검사가 빠진다(D7 과 같은 실패).
# 프로필은 겹침을 풀지 않는다 — 겹침 판정은 위에서 이미 끝났다(레포당 카테고리 하나).
# 규칙 조정(adjustments)은 더 도는 쪽만 둔다: 지금 종류는 force-lane 하나다. 승인일·근거가 없으면 적재하지 않는다.
# 파일 하나라도 틀리면 어느 레포도 분류하지 않는다 — 선언·디렉터리 어긋남과 같은 처리다(D7).
# engineVersion 은 프로필을 만든 엔진 버전(MAJOR.MINOR)이다. 같은 MAJOR 이고 프로필 MINOR ≤ 엔진 MINOR 일 때만 적재한다 —
# 어긋난 프로필도 "틀린 파일" 과 같이 전체를 멈춘다(근거: DECISIONS.md 「프로필–엔진 버전 결속」).
PROFROOT = Path(os.environ['SELFDIR']) / 'profiles'
# 오버레이의 profiles/ 도 읽는다. 표시 경로는 둘 다 profiles/<rel> 이고, 같은 슬러그가 두 루트에 있으면 적재 실패다.
PROFROOTS = [PROFROOT] + ([Path(OVERLAY) / 'profiles'] if OVERLAY else [])
PROFILE_KEYS = {'repo', 'category', 'engineVersion', 'adjustments'}
VERSION_RE = r'\d+\.\d+'   # lib.sh pf_engine_version 과 같은 형식
ADJ_KEYS = {'id', 'kind', 'lane', 'modes', 'approved', 'evidence'}
FORCEABLE_LANES = ('code-reviewer', 'test-runner', 'crossrepo-impact')   # mode=all 이 전제 없이 강제하는 lane 과 같다

def _prof_fail(msg):
    print(f'프로필 적재 실패 — {msg}. 분류하지 않는다 (skills/preflight/profiles 를 확인해라).', file=sys.stderr)
    sys.exit(3)

def _prof_engine_check(rel, pv):
    rel = f'profiles/{rel}'
    ev = os.environ.get('ENGINE_VER', '')
    if not (isinstance(pv, str) and re.fullmatch(VERSION_RE, pv)):
        _prof_fail(f'{rel} 의 engineVersion {pv!r} 는 MAJOR.MINOR 문자열이 아니다')
    if not ev:
        _prof_fail(f'엔진 버전(skills/preflight/ENGINE_VERSION)을 읽지 못해 {rel} 의 호환을 판정할 수 없다 — '
                   f'설치본에 MAJOR.MINOR 한 줄이 있어야 한다')
    (pM, pm), (eM, em) = (tuple(map(int, v.split('.'))) for v in (pv, ev))
    if pM < eM:
        _prof_fail(f'{rel} 은 엔진 {pv} 로 만들어졌고 지금 엔진은 {ev} 다 — MAJOR 가 올라 프로필 계약이 바뀌었다. '
                   f'DECISIONS.md 에서 엔진 {eM}.0 의 계약 변경을 보고 프로필을 고친 뒤 engineVersion 을 "{ev}" 로 올려라')
    if (pM, pm) > (eM, em):
        _prof_fail(f'{rel} 은 엔진 {pv} 로 만들어졌는데 지금 엔진은 {ev} 다 — 프로필이 이 엔진에 없는 계약을 기대한다. '
                   f'엔진(설치본 skills/preflight)을 {pv} 이상으로 갱신해라')

def _load_profiles(cat_names):
    profs = {}
    for root in PROFROOTS:
        _load_profile_root(root, cat_names, profs)
    return profs

def _load_profile_root(PROFROOT, cat_names, profs):
    if not PROFROOT.exists():
        return
    if not PROFROOT.is_dir():
        _prof_fail(f'{PROFROOT} 가 디렉터리가 아니다')
    for p in sorted(PROFROOT.rglob('*')):
        if p.is_dir():
            continue
        rel = p.relative_to(PROFROOT).as_posix()
        # 숨김 파일(.DS_Store 등)은 프로필이 아니다 — Finder 가 만든 파일 하나로 모든 분류가 멈추지 않게
        if rel == 'README.md' or p.name.startswith('.'):
            continue
        if not re.fullmatch(r'[^/]+/[^/]+\.json', rel):
            _prof_fail(f'{rel} — 프로필 자리는 profiles/<owner>/<repo>.json 이다')
        try:
            d = json.loads(p.read_text())
        except Exception as e:
            _prof_fail(f'{rel} 을 읽지 못했다 ({type(e).__name__}: {e})')
        if not isinstance(d, dict) or set(d) - PROFILE_KEYS or not {'repo', 'category', 'engineVersion'} <= set(d):
            _prof_fail(f'{rel} 의 키는 repo·category·engineVersion(필수)·adjustments 뿐이다')
        repo = d['repo']
        if not (isinstance(repo, str) and re.fullmatch(r'[^/\s]+/[^/\s]+', repo)) or rel != repo.lower() + '.json':
            _prof_fail(f'{rel} 의 repo {repo!r} 가 파일 자리와 다르다 — 자리는 repo 를 소문자로 쓴 <owner>/<repo>.json')
        if d['category'] not in cat_names:
            _prof_fail(f'{rel} 의 category {d["category"]!r} 는 선언된 카테고리가 아니다 ({", ".join(cat_names)})')
        _prof_engine_check(rel, d['engineVersion'])
        adj = d.get('adjustments', [])
        if not isinstance(adj, list):
            _prof_fail(f'{rel} 의 adjustments 는 목록이어야 한다')
        ids = set()
        for a in adj:
            if not (isinstance(a, dict) and set(a) == ADJ_KEYS):
                _prof_fail(f'{rel} 의 조정 항목 키는 {", ".join(sorted(ADJ_KEYS))} 이다')
            if not (isinstance(a['id'], str) and a['id']) or a['id'] in ids:
                _prof_fail(f'{rel} 의 조정 id {a["id"]!r} 가 비었거나 겹친다')
            ids.add(a['id'])
            if a['kind'] != 'force-lane':
                _prof_fail(f'{rel} {a["id"]} 의 kind {a["kind"]!r} — 지금 받는 종류는 force-lane 뿐이다')
            if a['lane'] not in FORCEABLE_LANES:
                _prof_fail(f'{rel} {a["id"]} 의 lane {a["lane"]!r} — 강제할 수 있는 lane 은 {", ".join(FORCEABLE_LANES)}')
            if not (isinstance(a['modes'], list) and a['modes'] and all(isinstance(m, str) for m in a['modes'])
                    and set(a['modes']) <= {'commit', 'pr'}
                    and len(set(a['modes'])) == len(a['modes'])):
                _prof_fail(f'{rel} {a["id"]} 의 modes 는 commit·pr 중 하나 이상의 목록이다')
            if not (isinstance(a['approved'], str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', a['approved'])):
                _prof_fail(f'{rel} {a["id"]} 의 approved 는 승인일(YYYY-MM-DD)이다')
            if not (isinstance(a['evidence'], str) and a['evidence'].strip()):
                _prof_fail(f'{rel} {a["id"]} 의 evidence(실측 명령·근거)가 비었다')
        if repo.lower() in profs:
            _prof_fail(f'{rel} 이 엔진과 오버레이 양쪽에 있다 — 프로필은 한 곳에만 둔다')
        profs[repo.lower()] = {'path': f'profiles/{rel}', 'repo': repo, 'category': d['category'],
                               'engineVersion': d['engineVersion'], 'adjustments': adj}

def _origin_slug():
    m = re.search(r'[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$', git('remote', 'get-url', 'origin').strip())
    return f'{m.group(1)}/{m.group(2)}' if m else ''

PROFILES = _load_profiles([c[0] for c in CATS])
ORIGIN_SLUG = _origin_slug()
PROFILE = PROFILES.get(ORIGIN_SLUG.lower()) if ORIGIN_SLUG else None
if PROFILE and PROFILE['category'] != CAT_NAME:
    print(f'프로필과 신호 추론이 어긋난다 — {PROFILE["path"]} 은 {PROFILE["category"]}, 신호는 '
          f'{CAT_NAME or "카테고리 없음"} 이다. 분류하지 않는다. 신호가 맞으면 프로필을, 프로필이 맞으면 레포를 고쳐라.',
          file=sys.stderr)
    if CAT_NAME:
        print(f'  {CAT_NAME}: ' + '; '.join(CAT_EVIDENCE), file=sys.stderr)
    sys.exit(3)
if PROFILE:
    CATEGORY_BASIS = f'프로필 {PROFILE["path"]} 의 {CAT_NAME} — 신호와 일치'
elif ORIGIN_SLUG:
    CATEGORY_BASIS = f'신호 추론 — {ORIGIN_SLUG} 의 프로필 없음'
else:
    CATEGORY_BASIS = '신호 추론 — origin 리모트가 없어 프로필을 찾지 않았다'
PROFILE_OUT = ({'path': PROFILE['path'], 'repo': PROFILE['repo'], 'engineVersion': PROFILE['engineVersion'],
                'adjustments': PROFILE['adjustments']}
               if PROFILE else None)
ctx.catdir = _CAT_DIR
def _rule(name):
    return getattr(CAT, name, None) if CAT is not None else None
def _na(what):
    """소속 카테고리에 그 규칙이 없을 때 남기는 사유."""
    return f'category-not-applicable — {what} 은(는) 카테고리 {CAT_NAME or "없음"} 의 규칙이 아니다'

# 조회: 카테고리·근거 신호·절차 요구만 내고 끝난다. 아무것도 쓰지 않고 vault 를 조회하지 않는다(I6).
if MODE == 'category':
    print(_json_out({'repo': str(R), 'category': CAT_NAME,
                     'evidence': {CAT_NAME: CAT_EVIDENCE} if CAT_NAME else {},
                     'procedures': _CAT_PROCS, 'profile': PROFILE_OUT, 'origin': ORIGIN_SLUG or None,
                     'basis': 'classify.sh commit 모드 입력 — 소속 판정은 인덱스 스냅숏, 워킹트리 표식은 워킹트리. '
                              f'카테고리: {CATEGORY_BASIS}'},
                    indent=2))
    sys.exit(0)

# ── 파일 → 분류
# tsc/jest 가 돌 수 있는 것 — test-runner 의 대상이다
TESTABLE_EXT = ('.ts', '.tsx', '.js', '.jsx')
# 사람이 리뷰해야 하는 소스 — 셸 스크립트도 코드다. 이 레포가 그 증거다
# .py 는 리뷰 대상이지만 test-runner 대상은 아니다 — test-runner 는 tsc/jest 만 돈다
CODE_EXT = TESTABLE_EXT + ('.sh', '.bash', '.mjs', '.cjs', '.py')
def is_code(f):
    return f.endswith(CODE_EXT) and not f.endswith('.d.ts') and not f.startswith('@types/')

code_files  = [f for f in changed if is_code(f)]
test_files  = [f for f in code_files if f.endswith(TESTABLE_EXT)]
# vault 문서 판정은 카테고리 규칙이다 — 소속 카테고리에 없으면 vault-linter 대상도 없다.
vault_files = list(_rule('vault_docs')(ctx, changed)) if _rule('vault_docs') else []
types_files = [f for f in changed if f.startswith('@types/')]

# package.json 은 version/dependencies 가 바뀐 경우에만 타입/의존성 lane 이다. 카테고리가 줄 패턴을 더할 수 있다.
DEP_KEY = re.compile('|'.join([r'^[+-]\s*"(version|dependencies|devDependencies|peerDependencies)"',
                               *(_rule('DEP_KEY_EXTRA') or ())]))
for f in changed:
    if f == 'package.json' or f.endswith('/package.json'):
        d = git('diff', *DIFF, '--no-renames', '-U0', '--', f) if has_head else ''
        if not has_head or any(DEP_KEY.search(l) for l in d.splitlines()):
            types_files.append(f)

# ── 코드 변경이 실제 로직인가 (휴리스틱, 판단 불가면 true)
_C_LIKE = ('//', '/*', '*', '*/')
_HASH = ('#',)
def _commentish(f):
    # `#` 를 전역으로 넣으면 JS 비공개 필드(`#priv = 1`)를 주석으로 오인해 로직 변경을 놓친다.
    return _HASH if f.endswith(('.sh', '.bash', '.py', '.yml', '.yaml', '.toml', '.env')) else _C_LIKE
def logic_changed(f):
    if not has_head:
        return True
    d = git('diff', *DIFF, '--no-renames', '-U0', '--', f)
    if not d:
        return True                      # diff 로 못 보면 도는 쪽
    for l in d.splitlines():
        if l[:3] in ('+++', '---') or not l or l[0] not in '+-':
            continue
        body = l[1:].strip()
        if not body or body.startswith(_commentish(f)):
            continue
        return True
    return False

# ── 공개 타입 표면: @types/tsconfig.build.json 의 include 에서 전이 폐포
def _strip_jsonc(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'(^|\s)//[^\n]*', '', s)

def _glob_re(pat):
    """Path.glob 과 같은 뜻의 정규식: `**/` 는 0개 이상의 디렉터리, `*`·`?` 는 한 단계 안."""
    out, i = '', 0
    while i < len(pat):
        if pat.startswith('**/', i): out += '(?:.*/)?'; i += 3
        elif pat.startswith('**', i): out += '.*'; i += 2
        elif pat[i] == '*': out += '[^/]*'; i += 1
        elif pat[i] == '?': out += '[^/]'; i += 1
        elif pat[i] == '[':
            j = pat.find(']', i)
            if j < 0: out += re.escape(pat[i]); i += 1
            else: out += pat[i:j + 1]; i = j + 1
        else: out += re.escape(pat[i]); i += 1
    return re.compile(out + r'\Z')

def _norm(rel):
    """레포 루트 기준 상대경로로 정규화. 루트 밖이면 None."""
    n = posixpath.normpath(rel)
    return None if n.startswith('../') or n == '..' or n.startswith('/') else n

def _expand(base, pat):
    full = _norm(posixpath.join(base, pat))
    if full is None:
        return []
    if not any(c in pat for c in '*?['):
        return [full] if snap_has(full) else []
    rx = _glob_re(full)
    return [f for f in SNAP if rx.match(f)]

IMPORT = re.compile(r"""(?:from|import|require\()\s*['"](\.[^'"]+)['"]""")
SUFFIXES = ('', '.ts', '.tsx', '.d.ts', '/index.ts', '/index.tsx')

def public_surface():
    tc = '@types/tsconfig.build.json'
    if not snap_has(tc):
        return None, 'no-@types-build-config'
    try:
        cfg = json.loads(_strip_jsonc(snap_read(tc) or ''))
    except Exception as e:
        return None, f'tsconfig-parse-failed:{e}'
    stack = []
    for g in (cfg.get('include') or []):
        stack += _expand('@types', g)
    if not stack:
        return None, 'tsconfig-include-matched-nothing'
    seen = set()
    while stack:
        p = stack.pop()
        if p in seen or not snap_has(p):
            continue
        seen.add(p)
        txt = snap_read(p) or ''
        for rel in IMPORT.findall(txt):
            cand = _norm(posixpath.join(posixpath.dirname(p), rel))
            if cand is None:
                continue                    # 레포 밖은 무시
            for suf in SUFFIXES:
                if snap_has(cand + suf):
                    stack.append(cand + suf); break
    return seen, None

surface, surface_err = public_surface()
surface_hits = sorted(set(changed) & surface) if surface else []

# ── 테스트가 있는가 (없으면 test-runner 는 tsc 만)
def has_tests():
    if snap_has('package.json'):
        try:
            if (json.loads(snap_read('package.json') or '{}').get('scripts') or {}).get('test'):
                return True
        except Exception:
            pass
    return any(snap_under(d, ('.spec.ts', '.test.ts', '.spec.js', '.test.js'))
               for d in ('src', 'test', 'tests', '__tests__'))

# ── eslint 설정이 스냅숏에 있는가. 미추적 설정 파일은 커밋되지 않으므로 없는 것이다.
def has_eslint():
    return any(snap_has(n) for n in
               ('.eslintrc.js', '.eslintrc.json', '.eslintrc', '.eslintrc.yml', 'eslint.config.js', 'eslint.config.mjs'))

# ── vault 연결 프로젝트로 등록됐는가. 조회는 소속 카테고리의 규칙이다(vault_link) — 없으면 조회하지 않는다.
# NOT_APPLICABLE 은 "조회 비적용" 이다 — receipt.sh 의 통과 목록에 이 값이 명시돼 있다.
def vault_link():
    if _rule('vault_link'):
        return _rule('vault_link')(ctx)
    return {'status': 'NOT_APPLICABLE', 'reason': _na('vault 등록 조회')}

vlink = vault_link()
linked = vlink['status'] == 'REGISTERED'

def _branch_has_pr_gate():
    """이 브랜치가 **PR 게이트를 통과한 적이 있는가.**

    PR 생성 여부가 아니다 — 읽는 `branches[b]['pr']` 는 `receipt.sh record pr` 가 쓰고,
    훅은 `verify` 만 부르므로 `gh pr create` 가 실제로 실행됐는지는 어디에도 남지 않는다.
    PR 게이트만 돌려 보고 만들지 않은 브랜치도 여기 걸린다. 방향이 **더 도는 쪽**이라
    그대로 둔다 (PreToolUse 훅에는 '생성 성공 후' 라는 자리가 없다).

    이 표식이 필요한 이유: 훅이 거는 자리는 커밋과 PR 생성 둘뿐이고 CI 가 없어 PR 게이트는
    **한 번**뿐이다. 그 뒤 쌓는 커밋(= 리뷰 지적을 반영하는 커밋)을 덮는 것은 커밋 게이트밖에
    없다.

    **만료를 두지 않는다.** PR 은 며칠씩 열려 있고, 낡았다는 이유로 리뷰를 멈추면 오래된
    PR 일수록 안 보게 된다 — 판단이 안 서면 더 도는 쪽으로 기우는 이 파일의 원칙 그대로다.
    그래서 `receipt.sh` 의 24h 정리도 이 키만은 (축약해서) 남긴다. 그 예외가 사라지면 여기도
    조용히 깨지므로 둘은 같이 움직인다 — 회귀 스위트가 record 를 태워 고정한다.
    """
    try:
        _d = json.loads((Path(os.environ.get('GITDIR', str(R / '.git'))) / 'claude-preflight.json').read_text())
        _b = os.environ.get('PF_BRANCH', '')
        return bool(((_d.get('branches') or {}).get(_b) or {}).get('pr'))
    except Exception:
        return False        # 기록을 못 읽으면 PR 이전으로 본다 — `--review` 가 여전히 연다

# ── lane 선택
selected, notSelected, meta = {}, {}, {}
_post_pr = _branch_has_pr_gate()

# ── 시크릿 검사: 1차 판정은 결정론 스캔(secret-scan.sh)이다. 근거는 DECISIONS.md 「시크릿 검사 결정론 우선」.
# 카테고리 rules.py 의 SECRET_SCAN 이 'auto' 일 때만 스캔이 CLEAN 이면 secret-scanner 를 건너뛴다.
# 상수가 없거나 'always'(또는 알 수 없는 값)면 지금처럼 늘 선택한다 — 스캔은 돌리고 결과를 기록만 한다.
# mode=all 은 'always' 로 본다(대상이 없어도 도는 모드다). 스캔이 죽으면 SCAN_ERROR 로 보고 선택한다(도는 쪽).
# 값은 어디에도 싣지 않는다 — 스캔 출력이 패턴 이름·파일·줄 번호뿐이다.
# CONTRACT: secret-scan-recheck-at-record — receipt.sh record 가 같은 대상으로 다시 스캔해 status·patternsVersion 을 대조한다.
# CONTRACT: secret-scan-mode-rule — secret-scan.sh 의 categoryMode 와 같은 규칙이다(기록 단계가 그 값으로 모드를 다시 구한다).
_ss_rule = _rule('SECRET_SCAN')
SECRET_SCAN_MODE = 'auto' if (_ss_rule == 'auto' and MODE != 'all') else 'always'
def _secret_scan():
    import tempfile
    _tool = os.path.join(os.environ['SELFDIR'], 'secret-scan.sh')
    try:
        with tempfile.NamedTemporaryFile('wb', prefix='pf-secret-files.', delete=False) as _fh:
            _fh.write(b''.join(f.encode('utf-8', 'surrogateescape') + b'\0' for f in changed))
            _lst = _fh.name
        argv = [_tool, DIR, 'pr' if MODE == 'pr' else 'commit', '--files-from', _lst]
        if MODE == 'pr':
            argv += ['--from', diff_from]
        if CAT_NAME:
            argv += ['--category', CAT_NAME]
        try:
            p = subprocess.run(argv, capture_output=True, timeout=120, **_DEC)
        finally:
            os.unlink(_lst)
        d = json.loads(p.stdout) if p.returncode == 0 else None
        if not (isinstance(d, dict) and d.get('status') in ('CLEAN', 'HITS', 'SENSITIVE_PATH', 'SCAN_ERROR')):
            raise ValueError((p.stderr or '').strip()[-160:] or f'rc={p.returncode}')
    except Exception as e:
        d = {'status': 'SCAN_ERROR', 'reason': f'secret-scan.sh 실패 ({type(e).__name__}: {e})'[:200],
             'patternsVersion': None, 'scannedLines': 0, 'hits': [], 'hitsTruncated': 0, 'sensitivePaths': []}
    d['mode'] = SECRET_SCAN_MODE
    d['tool'] = _tool
    return d
secret_scan = _secret_scan()
if secret_scan['status'] == 'CLEAN' and SECRET_SCAN_MODE == 'auto':
    notSelected['secret-scanner'] = (
        f"secret-scan-clean — 결정론 스캔 0건(patterns v{secret_scan.get('patternsVersion')}, "
        f"{secret_scan.get('scannedLines')}줄), 민감 경로 변경 없음")
else:
    selected['secret-scanner'] = changed
    meta['secret-scanner'] = {'scan': {k: secret_scan.get(k) for k in
                                       ('status', 'patternsVersion', 'scannedLines', 'hits', 'hitsTruncated',
                                        'sensitivePaths', 'reason', 'mode') if secret_scan.get(k) is not None}}
if code_files:
    logic = [f for f in code_files if logic_changed(f)]
    if not logic:
        notSelected['code-reviewer'] = 'code-change-is-comment-or-format-only'
    elif MODE in ('pr', 'all') or REVIEW or _post_pr:
        # `all` 을 여기서 함께 받는다. 아래 강제 블록에 맡기면 payload 가 `logic` 이 아니라
        # `changed` 로 가서, 같은 모드가 플래그 유무로 리뷰 대상 집합이 달라진다.
        selected['code-reviewer'] = logic
        if _post_pr and MODE == 'commit' and not REVIEW:
            meta['code-reviewer'] = {'forcedBy':
                'pr-gate-recorded — 이 브랜치는 PR 게이트를 통과한 적이 있다. PR 게이트는 '
                '한 번뿐이므로 그 이후 커밋은 커밋 게이트가 리뷰한다 (플래그 불필요).'}
    else:
        # 리뷰의 기본 자리는 PR 게이트이고, PR 생성 이후 구간은 위 `_post_pr` 가 덮는다.
        notSelected['code-reviewer'] = (
            'no-review-flag — **리뷰를 받을 커밋이면 `--review` 로 다시 돌려라.** '
            '이 브랜치는 아직 PR 게이트를 통과한 적이 없다 — 통과한 뒤로는 플래그 없이도 리뷰한다. '
            '커밋마다 돌리지 않는 것은 비용 결정이지 면제가 아니다.')

    if test_files:
        selected['test-runner'] = test_files
    else:
        notSelected['test-runner'] = 'no-testable-file-change — tsc/jest 가 돌 수 있는 파일이 없다'
    meta['test-runner'] = {'tscOnly': not has_tests(), 'eslintConfig': has_eslint()}
else:
    notSelected['code-reviewer'] = 'no-code-change'
    notSelected['test-runner'] = 'no-code-change'

# ── 레포 자신의 회귀 스위트 — 돌릴지는 분류기가 정한다(test-runner 가 고르지 않는다). 대상 판정·명령은
# 카테고리 규칙(suites)이다. CONTRACT: suites-decided-by-classifier
_suites = list(_rule('suites')(ctx, changed)) if _rule('suites') else []
if _suites:
    if 'test-runner' not in selected:
        selected['test-runner'] = sorted({f for s in _suites for f in s['why']})
        notSelected.pop('test-runner', None)
    _tm = meta.setdefault('test-runner', {})
    _tm.setdefault('tscOnly', not has_tests())
    _tm.setdefault('eslintConfig', has_eslint())
    _tm['suites'] = _suites

xr = sorted(set(types_files) | set(surface_hits))
if xr:
    selected['crossrepo-impact'] = xr
    meta['crossrepo-impact'] = {'publicTypeSurfaceHits': surface_hits,
                                'declaredTypeFiles': sorted(set(types_files))}
else:
    notSelected['crossrepo-impact'] = surface_err or 'no-public-type-surface-change'

# vault 문서가 무엇인지는 카테고리 규칙이 정한다. 규칙이 없는 카테고리에서는 vault 문서가 없는 것이다 — 사유는 같다.
if vault_files:
    selected['vault-linter'] = vault_files
else:
    notSelected['vault-linter'] = 'no-vault-doc-change'

branch = os.environ.get('PF_BRANCH', '')   # lib.sh pf_branch — 첫 커밋 전 브랜치에서도 이름을 준다
# CONTRACT: plan-resolve-is-one-function — 계획을 찾는 규칙은 plan.sh 에만 있다.
# 실패하면 UNREADABLE 이다. NONE 으로 떨어지면 결속된 약속이 "계획 없음" 으로 사라진다.
_pr = subprocess.run([os.path.join(os.environ['SELFDIR'], 'plan.sh'), 'resolve', DIR],
                     capture_output=True, **_DEC)
try:
    plan = json.loads(_pr.stdout) if _pr.returncode == 0 else None
except Exception:
    plan = None
if not isinstance(plan, dict) or 'status' not in plan:
    plan = {'status': 'UNREADABLE', 'path': None,
            'reason': f"plan.sh resolve 실패(rc={_pr.returncode}): {(_pr.stderr or '').strip()[:200]}"}

# ── 추적 입력 (docs/cycle-trace.md § 4-3 · 5-4) ─────────────────────────────
# tracer 가 스스로 찾으면 "어느 커밋의 QA 를 봤나" 가 갈린다. 결정론으로 모아 넘긴다.
# QA 기록의 자리는 receipt.sh 가 쓰는 `<common-dir>/claude-preflight.qa/<tree>.json` 이다
# — CONTRACT: qa-record-path (쓰는 쪽 receipt.sh · 읽는 쪽 여기. meta-test 가 왕복을 고정한다).
# 커밋의 tree 는 그 커밋을 만들 때의 indexTree 와 같다.
def _trace_inputs(plan):
    out = {'approval': plan.get('approval')}
    _cd = git('rev-parse', '--git-common-dir').strip()
    common = os.path.realpath(_cd if os.path.isabs(_cd) else os.path.join(DIR, _cd)) if _cd else ''
    commits = git('rev-list', '--reverse', f'{base_merge}..HEAD').split() if (base_merge and has_head) else []
    records = []
    for c in commits:
        tree = git('rev-parse', f'{c}^{{tree}}').strip()
        f = os.path.join(common, 'claude-preflight.qa', tree + '.json') if (common and tree) else ''
        if f and os.path.isfile(f):
            try:
                d = json.loads(Path(f).read_text(errors='surrogateescape'))
            except Exception as e:
                records.append({'commit': c[:12], 'path': f, 'error': f'{type(e).__name__}: {e}'}); continue
            records.append({'commit': c[:12], 'path': f, 'verdict': d.get('verdict'),
                            'planId': d.get('planId'), 'coverage': d.get('coverage') or {}})
    # 계획 항목별 상태는 **가장 늦은 커밋**의 기록이 정한다 — 앞 커밋에서 통과했어도 뒤에서 실패하면 실패다.
    # 참조 목록은 plan.sh 가 만든다 — CONTRACT: qa-ref-is-one-function.
    _pq = subprocess.run([os.path.join(os.environ['SELFDIR'], 'plan.sh'), 'qa', DIR], capture_output=True, **_DEC)
    try:
        refs = [i['ref'] for i in json.loads(_pq.stdout).get('items', [])] if _pq.returncode == 0 else []
    except Exception:
        refs = []
    status = {r: 'MISSING' for r in refs}
    for rec in records:
        # 참조 문자열(R1/qa#1)은 계획마다 다시 매겨진다. 다른 계획으로 쓴 기록을 세면 지금 계획의
        # 같은 이름 항목이 남의 증거로 닫힌다 — 세지 않고 tracer 에 그 사실만 보인다.
        if rec.get('planId') != plan.get('planId'):
            rec['ignored'] = 'other-plan'
            continue
        cov = rec.get('coverage') or {}
        for key, st in (('passed', 'PASS'), ('failed', 'FAIL'), ('notRun', 'NOT_RUN')):
            for r in cov.get(key) or []:
                if r in status:
                    status[r] = st
    out['qaRecords'] = records
    out['qaCoverage'] = status
    out['designDoc'] = _design_drift(plan)
    return out

# 설계 문서가 계획 승인 뒤 바뀌었나. 막지 않는다 — 계획이 따라갔는지 사람에게 묻는 재료다.
# vault 를 특정할 수 없거나 sha 를 모르면 UNKNOWN 이다(vault 연결 판정의 UNKNOWN 과 같은 이유).
def _design_drift(plan):
    try:
        d = json.loads(Path(plan['path']).read_text(errors='surrogateescape'))
    except Exception:
        return None
    dd = d.get('designDoc') if isinstance(d, dict) else None
    if not isinstance(dd, dict) or not dd.get('path'):
        return None
    # UNRESOLVED 는 특정할 수 없음(vault·sha 모름), FAILED 는 조회가 죽음 — vault 연결 판정과 같은 구분이다.
    res = {'path': dd.get('path'), 'sha': dd.get('sha'), 'status': 'UNKNOWN', 'lookup': 'UNRESOLVED'}
    vd = _vault_dir()
    if not vd or not dd.get('sha'):
        res['reason'] = 'vault 위치 또는 설계 문서 sha 를 모른다'; return res
    # 분류기가 이미 원격 기준선을 잡았으면 그것으로 본다 — 로컬 vault 는 원격보다 수백 커밋 뒤처질 수 있다.
    _src = (vlink.get('source') or {}) if isinstance(vlink, dict) else {}
    tip = _src.get('sha') if _src.get('mode') == 'remote' else 'HEAD'
    res['against'] = tip if tip != 'HEAD' else 'HEAD (vault 워킹트리 — 낡았을 수 있다)'
    rc, out, err = _vgit(vd, 'log', '--format=%h', f"{dd['sha']}..{tip}", '--', dd['path'])
    if rc != 0:
        res['lookup'] = 'FAILED'
        res['reason'] = (err or '').strip().splitlines()[-1][:160] if err else f'git log rc={rc}'; return res
    later = out.split()
    res.pop('lookup')
    res.update({'status': 'CHANGED' if later else 'CURRENT', 'commits': later[:10]})
    return res

if MODE in ('pr', 'all'):
    selected['pr-quality'] = []
    # 재발견 방지 — 전사 실측에서 명령 13개 중 절반이 branch·base 중복 조회였다.
    _chk = os.path.join(os.environ['SELFDIR'], 'pr-format-check.sh')
    meta['pr-quality'] = {'branch': branch, 'base': base_ref or None, 'checker': _chk}
    # 검사기의 rule 목록 — 워크플로가 이 lane 의 지적 id 어휘로 쓴다. 못 읽으면 어휘 없이 종전대로 돈다.
    try:
        _r = subprocess.run([_chk, '--rules'], capture_output=True, text=True, timeout=20)
        meta['pr-quality']['checkerRules'] = json.loads(_r.stdout) if _r.returncode == 0 else None
    except Exception:
        meta['pr-quality']['checkerRules'] = None
    if not _rule('VAULT_SYNC'):
        notSelected['vault-sync'] = _na('vault-sync 선택')
    elif linked:
        selected['vault-sync'] = [vlink['note']]
        # 노트는 vaultDir 상대경로다. 어느 기준선에서 읽어야 하는지를 같이 넘긴다 —
        # lane 이 워킹트리를 열면 분류기가 원격에서 본 것과 다른 노트를 판정한다.
        meta['vault-sync'] = {'vaultSource': vlink['source']}
    else:
        notSelected['vault-sync'] = f"{vlink['status']}: {vlink.get('reason', '')}"
    # 약속(plan)과 증거(구현·테스트·QA)를 잇는 lane. 계획이 없으면 추적할 claim 이 없다 —
    # 없는 약속을 지어내 판정하는 것이 이 lane 의 최악이므로, 그때는 돌리지 않고 사유를 남긴다.
    if plan['status'] == 'FOUND':
        selected['requirements-tracer'] = [plan['path']]
        meta['requirements-tracer'] = {'plan': plan, **_trace_inputs(plan)}
    elif plan['status'] == 'NONE':
        notSelected['requirements-tracer'] = 'no-plan-artifact (change-planner 미실행 — 추적할 claim 이 없다)'
    elif plan['status'] == 'DANGLING':
        notSelected['requirements-tracer'] = f"plan-dangling:{plan.get('planId')} — {plan.get('reason')}"
    else:
        notSelected['requirements-tracer'] = f"plan-unreadable:{plan.get('reason')}"
else:
    notSelected['pr-quality'] = 'commit-gate-not-pr'
    notSelected['vault-sync'] = 'commit-gate-not-pr'
    notSelected['requirements-tracer'] = 'commit-gate-not-pr'

# QA 는 배포된 것을 검사한다 — 배포 전에는 강제할 수 없다.
# 권장: 배포 → 커밋 게이트 `--qa` → 커밋. QA 결과가 indexTree 로 커밋될 내용에 묶인다.
# PR 게이트는 강제하지 않고 사유만 남긴다 (강제 기간 면제율 10/10, 그중 2건은 게이트 전체 우회).
sequential = []

def _commit_gate_qa():
    """직전 커밋 게이트 영수증에 QA 가 통과로 남아 있는가."""
    try:
        _d = json.loads((Path(os.environ.get('GITDIR', str(R / '.git'))) / 'claude-preflight.json').read_text())
        # 스키마 2 는 브랜치별이다. 최상위 `commit` 은 스키마1 잔재이고 24h 정리가 `branches` 만
        # 훑어 영원히 남는다 — 다른 브랜치의 일주일 전 기록으로 QA 를 생략하게 된다.
        rec = ((_d.get('branches') or {}).get(branch) or {}).get('commit') or {}
        if int(rec.get('ts', 0)) < int(time.time()) - 86400:
            return None                      # 만료된 통과는 통과가 아니다
    except Exception:
        return None
    lanes = rec.get('lanes') or {}
    got = {}
    for lane in ('qa-runner', 'qa-reviewer'):
        v = lanes.get(lane)
        st = v.get('status') if isinstance(v, dict) else v
        if st == 'PASS' and not (isinstance(v, dict) and v.get('waived')):
            got[lane] = rec.get('indexTree', '')[:8]
    # 순차 체인은 둘 다 통과했을 때만 통과다. 하나만 PASS 인 영수증(reviewer FAIL 등)이
    # 24h 동안 남아 다음 라운드의 생략 근거가 되면 안 된다.
    return got if len(got) == 2 else None

def _qa_targets():
    """변경에서 **결정론으로** 뽑는 QA 대상. qa-runner 가 이걸 다시 찾지 않게 한다.

    실측(2026-09-09, 전사 43건): qa-runner 의 도구호출 평균 90회 중 **62%가 코드·설정 탐색**이고
    실제 HTTP 요청은 17%뿐이었다. 레포가 뭘 하는 곳인지, 뭐가 바뀌었는지를 매번 처음부터
    알아내는 데 시간을 쓴다. 여기서 계산해 넘기면 그 62%가 사라진다.
    """
    mods, apis = set(), []
    for f in _qa_prod:
        m = re.match(r'src/modules/([^/]+)/', f)
        if m: mods.add(m.group(1))
        m = re.match(r'src/cores/([^/]+)/', f)
        if m: mods.add(f'cores:{m.group(1)}')
        if re.search(r'(^|/)api-[^/]+\.ts$|^src/api/[^/]+\.ts$', f): apis.append(f)
    # **이번 변경이 무엇인가** — qa-runner 가 git log/status/show/diff 로 다시 알아내던 것.
    # 실측(2026-09-11, 전사 37건): 비-HTTP 호출 1422회 중 63.6%가 그 재발견이었고,
    # reviewer 의 blocking 139건 중 32.4%가 "변경을 아예 실행하지 않았다" 였다.
    # 무엇을 건드렸는지 모른 채 찾다가 정작 그것을 안 건드리는 형태다.
    # 함수 이름은 **추측하지 않는다.** git 의 `@@` 컨텍스트는 TS 에서 앞 함수 헤더를 집어
    # 바뀌지 않은 함수를 가리킨다(실측). 틀린 지목은 안 주느니만 못하다 — 바뀐 **줄 자체**를 준다.
    # 설정 계열은 **줄 본문을 싣지 않는다.** QA 에 필요한 건 '설정이 바뀌었다' 이지 값이 아니고,
    # 추적되는 env/*.yml 에는 URL·키가 섞여 있다 — 분류 산출물은 디스크에 남고 프롬프트로 간다.
    _redact = _is_config
    lines, stat, trunc = {}, {}, 0
    if has_head:
        if len(_qa_prod) > 20: trunc = len(_qa_prod) - 20   # 잘린 사실은 소비자에게 전달한다
        for f in _qa_prod[:20]:               # 상한: 넘기는 값이 커지면 그 자체가 비용이다
            # 스냅숏 diff 라 스테이징된 신규 파일은 전부 추가 줄로 나오고, 미스테이징 줄은 안 나온다.
            d = git('diff', *DIFF, '--no-renames', '-U0', '--', f)
            # 신규 판정은 **base 에 있었나**로 한다. 신규 엔드포인트는 QA 가 안 밟기 쉽다.
            _new = subprocess.run(['git', '-C', DIR, 'cat-file', '-e', f'{diff_from}:{f}'],
                                  capture_output=True).returncode != 0
            add, dele, keep, dropped = 0, 0, [], 0
            for ln in d.splitlines():
                sign = '+' if ln.startswith('+') and not ln.startswith('+++') else \
                       '-' if ln.startswith('-') and not ln.startswith('---') else None
                if not sign: continue
                if sign == '+': add += 1
                else: dele += 1
                t = ln[1:].strip()
                if t and not _redact(f):
                    if len(keep) < 12: keep.append(f'{sign} ' + (t[:120] + '…' if len(t) > 120 else t))
                    else: dropped += 1
            if dropped: keep.append(f'… ({dropped}줄 생략)')
            if not keep and _redact(f) and (add or dele):
                keep = ['(설정 파일 — 값은 싣지 않는다)']   # 비었다가 아니라 뺐다는 사실을 남긴다
            if keep: lines[f] = keep
            if add or dele: stat[f] = ('new ' if _new else '') + f'+{add}/-{dele}'
    return {'modules': sorted(mods), 'apiFiles': sorted(apis),
            'changedLines': lines, 'diffStat': stat,
            **({'truncatedFiles': trunc} if trunc else {}),
            **({'commits': _c[:5], **({'truncatedCommits': True} if len(_c) > 5 else {})}
               if has_head and (_c := git('log', '--oneline', '-6', f'{diff_from}..HEAD').splitlines())
               else {})}

# QA 는 **배포된 동작**을 검사한다. 배포 산출물이 안 바뀌면 검사할 것이 없다.
#   - 배포 산출물 변경 없음(문서·테스트만) 또는 주석·포맷만 → 생략
# "테스트만 바뀌었으면 직전 QA 통과를 근거로 생략" 은 **아직 없다** — 게이트 간 결속을
# contentDigest 로 할 수 없어서다(docs/backlog.md). 결속이 생기기 전에는 건너뛰지 않는다.
# **배포 산출물 집합** — 정의는 여기 하나뿐이고 QA 관련 전부가 이것을 쓴다.
# 확장자를 안 가리면 docs/*.md 까지 "배포 동작 변경" 으로 잡혀 문서만 고친 변경에도
# dev 로 라이브 요청이 나간다.
# 설정 집합의 정의는 **여기 하나**다 — 나뉘면 값 비노출과 배포 판정이 갈려 줄 본문이 샌다.
CONFIG_EXT = ('.yml', '.yaml', '.json', '.toml', '.env')
CONFIG_FILES = ('Dockerfile',)
_is_config = lambda f: f.endswith(CONFIG_EXT) or f.startswith('env/') or \
                       ('/' not in f and f in CONFIG_FILES)
DEPLOYED_EXT = CODE_EXT + CONFIG_EXT
_is_deployed = lambda f: (f.endswith(DEPLOYED_EXT) or '/' not in f and f in CONFIG_FILES) \
                         and not f.startswith(('docs/', 'wiki/'))
_qa_prod = [f for f in changed if _is_deployed(f) and logic_changed(f)] if QA else []
_qa_skip = None
if QA and not _qa_prod:
    _dep = [f for f in changed if _is_deployed(f)]
    _qa_skip = ('변경 없음' if not changed
                else '배포 산출물 변경 없음 (문서·테스트만)' if not _dep
                else '배포 산출물이 주석·포맷만 바뀌었다')
if QA and _qa_skip:
    notSelected['qa-runner'] = notSelected['qa-reviewer'] = (
        f'qa-skipped-no-behavior-change — {_qa_skip}.')
elif QA:
    sequential.append(['qa-runner', 'qa-reviewer'])
    # 빈 목록을 주면 워크플로가 "파일이 아니라 메타를 본다" 로 안내해 탐색을 유발한다.
    # 변경된 code 파일을 그대로 준다 — 무엇을 검증할지의 출발점이다.
    selected['qa-runner'] = _qa_prod
    selected['qa-reviewer'] = _qa_prod
    _t = _qa_targets()
    if base_merge: _t['base'] = base_merge
    # 배포 엔드포인트(devBaseUrl)는 카테고리 규칙이다 — dev 배포가 있는 카테고리만 준다.
    if _rule('qa_meta'):
        _t.update(_rule('qa_meta')(ctx))
    if linked:
        _t['repoNote'] = vlink.get('note')   # 레포가 무엇을 하는 곳인지 — 코드에서 재구성하지 않는다
    # 결속된 계획이 QA 로 닫으라고 한 항목. 실행자는 시나리오마다 이 참조를 달고, 심사자는 빠진 것을 본다.
    # 참조 문자열은 plan.sh 가 만든다 — CONTRACT: qa-ref-is-one-function.
    if plan['status'] == 'FOUND':
        _pq = subprocess.run([os.path.join(os.environ['SELFDIR'], 'plan.sh'), 'qa', DIR],
                             capture_output=True, **_DEC)
        try:
            _pqd = json.loads(_pq.stdout) if _pq.returncode == 0 else None
        except Exception:
            _pqd = None
        _t['planQa'] = ({'planId': _pqd.get('planId'), 'items': _pqd.get('items') or []}
                        if isinstance(_pqd, dict) and _pqd.get('status') == 'FOUND'
                        else {'planId': plan.get('planId'), 'items': [], 'error': (_pq.stderr or '').strip()[:200] or 'plan-qa-failed'})
    meta['qa-runner'] = dict(_t); meta['qa-reviewer'] = dict(_t)
    # PR 모드에서도 `--qa` 는 먹는다 — 막지 않고 자리만 알려준다.
    # (스크립트는 즉시 갱신되지만 SKILL.md 는 세션에 고정돼, 옛 판본을 든 세션이 여기로 온다)
    if MODE == 'pr':
        _done = _commit_gate_qa()
        _placement = {'placement': (
            'qa-at-pr-gate — QA 의 자리는 커밋 게이트(`--qa`)다. 거기서 돌리면 결과가 '
            'indexTree 로 커밋될 내용에 묶이는데, PR 게이트는 이미 커밋된 뒤라 묶이지 않는다.'
            + (f" 게다가 커밋 게이트에서 이미 통과했다 (indexTree {list(_done.values())[0]}) — 중복 실행이다."
               if _done else ''))}
        meta.setdefault('qa-runner', {}).update(_placement)
        meta.setdefault('qa-reviewer', {}).update(_placement)
else:
    if MODE == 'pr' and code_files:
        done = _commit_gate_qa()
        if done:
            reason = f"qa-done-at-commit-gate (커밋 영수증 indexTree {list(done.values())[0]})"
        else:
            reason = (_rule('QA_HINT') or {}).get('pr') or _na('dev 배포 안내')
    elif MODE != 'pr' and code_files:
        # dev 배포 안내는 카테고리 규칙이다(D8) — 배포가 없는 레포에 "배포했으면" 을 띄우지 않는다.
        reason = (_rule('QA_HINT') or {}).get('commit') or _na('dev 배포 안내')
    else:
        reason = 'no-dev-deploy-flag' if MODE != 'pr' else 'pr-gate-no-code-change'
    notSelected['qa-runner'] = reason
    notSelected['qa-reviewer'] = reason

# **mode=all 강제보다 앞이어야 한다.** 강제 뒤의 selected 를 읽으면 `/preflight all` 이
# 무엇이든 고위험으로 만든다 — 플래그가 위험으로 읽히는 같은 결함이다.
# 계획이 있었으면 좋았을 변경인가. 강제하지 않고 **세기만** 한다 —
# change-planner 는 호출 경로가 없어 0회였다(dormant, 2026-09-10 실측 · record 이벤트 187건
# 중 required 포함 0회 · plan FOUND 0건). 분모는 로그가 자라면 바뀌므로 질의와 날짜를 함께 적는다.
# 되살릴 근거가
# 실제로 쌓이는지 보려면 "고위험인데 계획 없음" 의 빈도가 필요하다.
# 정의는 여기 하나뿐이다. 흩어 두면 리포트와 로그가 다른 것을 세게 된다.
# 위험은 **변경 자체**의 성질이어야 한다. qa lane 을 신호로 쓰면 "사용자가 `--qa` 를 붙였다"
# (= 배포했다)가 고위험으로 읽혀, 쌓이는 advisory 가 위험도가 아니라 --qa 사용 빈도의
# 대리 지표가 된다 — 계획이 필요했는지를 재려는 목적과 어긋난다.
# `lanes` 에는 lane 이름만 담는다. 표면 변경은 신호가 아니라 라벨이다 —
# surface_hits 가 있으면 `xr` 분기가 crossrepo-impact 를 이미 selected 로 넣어 risk 를 바꾸지 못하고,
# 라벨은 laneMeta['crossrepo-impact'] 에 이미 있다. 신호처럼 보이는데 아무것도 세지 않는 항목은 뺀다.
HIGH_RISK_LANES = ('crossrepo-impact',)
_risk_hits = sorted(l for l in HIGH_RISK_LANES if l in selected)
risk = 'high' if _risk_hits else 'normal'
plan_advisory = ({'risk': risk, 'plan': plan['status'], 'lanes': _risk_hits}
                 if risk == 'high' and plan['status'] != 'FOUND' else None)

# 프로필의 force-lane 조정: 그 레포·그 모드에서 대상이 없어도 lane 을 돌린다. mode=all 은 아래에서 어차피 강제한다.
# 관례 판정이 강제된 lane 에도 실리도록 관례 판정보다 **앞**에 둔다(mode=all 강제와 같은 자리).
if PROFILE and MODE in ('commit', 'pr'):
    for _a in PROFILE['adjustments']:
        if MODE in _a['modes'] and _a['lane'] in notSelected:
            meta.setdefault(_a['lane'], {})['forcedBy'] = (
                f"profile {PROFILE['path']} {_a['id']} (승인 {_a['approved']}, 원래 사유: {notSelected.pop(_a['lane'])})")
            selected[_a['lane']] = changed

# mode=all: 대상이 아예 없는 lane 도 강제로 돈다 (qa/vault-sync 는 전제 조건이 있어 제외).
# 카테고리가 강제 lane 을 더할 수 있다(ALL_MODE_FORCED).
if MODE == 'all':
    for lane in ('code-reviewer', 'test-runner', 'crossrepo-impact', *(_rule('ALL_MODE_FORCED') or ())):
        if lane in notSelected:
            meta.setdefault(lane, {})['forcedBy'] = f"mode=all (원래 사유: {notSelected.pop(lane)})"
            selected[lane] = changed

# 관례 판정(관례 문서·관례 검사기)은 카테고리 규칙이다(convention). 대상이 아닌 레포에 관례 판정을 시키면
# "문서 없음·기준 없음" 만 나온다. 규칙이 없으면 conventionScope 에 사유를 둔다 — 키가 없으면 preflight.js 가
# 관례 판정 생략을 지시하지 않아 리뷰어가 `$VAULT_DIR` 로 관례 문서를 스스로 찾는다.
# mode=all 강제 선택 **뒤**에 둔다 — 앞에 두면 강제로 붙은 lane 은 이 값을 못 받는다.
# code-reviewer·test-runner 가 **같은 판정**을 쓰도록 여기 한 곳에서만 준다.
for _lane in ('code-reviewer', 'test-runner'):
    if _lane in selected:
        _cm = meta.setdefault(_lane, {})
        if _rule('convention'):
            _cm.update(_rule('convention')(ctx, _lane))
        else:
            _cm['conventionScope'] = _na('사내 관례 판정')

# diff 를 읽는 lane 에 검사 범위를 준다. 안 주면 lane 이 스스로 base 를 고르고, origin/master
# 와의 merge-base 를 잡아 이미 머지된 커밋을 이번 변경으로 리뷰한다 (2026-09-15 한 API 레포
# 실측: code-reviewer·crossrepo-impact 가 c4b256d 를 기준 삼아 PR #89~#92 를 지적했다).
# PR 게이트는 커밋 이후에 돌아 `--cached`·`diff HEAD` 가 늘 비어 있기도 하다 (44줄 PR 이 0줄로 PASS).
#
# CONTRACT: `MODE == 'pr'` 로만 건다. base 해석(`if MODE == 'pr' and has_head:`)이 pr 에만
#  걸리므로 다른 모드는
#  base_merge 가 항상 '' 이고, 그러면 diffRange=None 이 나가 preflight.js 가 lane 에
#  '브랜치 전체 커밋을 보라'를 넣는다 — 없애려던 오탐을 그 모드에 새로 만든다.
#  **None 과 키 부재는 다르다** — commit·all 은 키를 주지 않는 것이 맞다(HEAD 기준이 곧 범위다).
# CONTRACT: lane 선택이 **끝난 뒤**에 둔다. `_lane in selected` 로 거르므로, 앞에 두면 그
#  시점에 아직 selected 에 없는 lane 이 키를 못 받는다.
if MODE == 'pr':
    _range = ({'diffRange': base_merge} if base_merge
              else {'diffRange': None, 'reason': base_err or 'base 미해석'})
    for _lane in ('secret-scanner', 'code-reviewer', 'test-runner', 'crossrepo-impact'):
        if _lane in selected:
            meta[_lane] = {**meta.get(_lane, {}), **_range}

# CONTRACT: tracer-after-reviewer
# 계획의 `how: review` 항목은 code-reviewer 보고로만 닫힌다(agents/requirements-tracer.md). 두 lane 이
# 같은 배치에서 병렬로 돌면 tracer 프롬프트에 그 보고가 없어 review 항목이 매 라운드 MISSING 으로
# 남는다(2026-11-03 한 백엔드 레포 PR, 1·2라운드 연속). 그래서 이 체인을 sequential 에 넣는다 —
# preflight.js 가 tracer 를 reviewer 뒤에 띄우고, 영수증이 전사로 그 순서를 검사한다.
# CONTRACT: tracer-after-test-runner
# `how: test` 도 같은 부류다 — tracer 정의는 "test-runner 결과와 대조" 하라는데 그 보고가 프롬프트에
# 없었다. 테스트 항목이 있으면 [test-runner, requirements-tracer] 를 같은 방식으로 건다.
# 항목이 없으면 체인을 만들지 않는다 — tracer 가 기다릴 이유가 없다(test-runner 는 기준선까지 기다려 느리다).
# 참조 목록은 plan.sh 가 만든다 — CONTRACT: qa-ref-is-one-function.
# lane 선택이 **끝난 뒤**에 둔다 — mode=all 강제 선택으로 붙은 lane 도 체인에 들어가야 한다.
def _plan_items(how):
    _pr = subprocess.run([os.path.join(os.environ['SELFDIR'], 'plan.sh'), how, DIR],
                         capture_output=True, **_DEC)
    try:
        _prd = json.loads(_pr.stdout) if _pr.returncode == 0 else None
    except Exception:
        _prd = None
    return ({'planId': _prd.get('planId'), 'items': _prd.get('items') or []}
            if isinstance(_prd, dict) and _prd.get('status') == 'FOUND'
            else {'planId': plan.get('planId'), 'items': [],
                  'error': (_pr.stderr or '').strip()[:200] or f'plan-{how}-failed'})

def _chain_items(how, up, key, miss):
    """tracer 에 계획 항목을 싣고, 앞 lane 이 돌면 그 lane 에도 싣는다. 체인을 걸지 여부를 돌려준다."""
    _items = _plan_items(how)
    # CONTRACT: tracer-plan-refs-only
    # tracer 프롬프트는 항목의 ref 와 개수만 쓴다(preflight.js). what·claim 까지 실으면 같은 목록이 분류
    # JSON 에 두 번 들어간다 — 2026-11-13 PR 분류 224,595 바이트 중 ~47KB 가 그 중복이었다. 전문은 앞 lane 만 받는다.
    _tr = {**_items, 'items': [{'ref': i['ref']} for i in _items['items']]}
    # 앞 lane 이 안 돌면 tracer 는 그 사유를 받아 항목을 MISSING 으로 둔다 — 지어내지 않게 한다.
    if up not in selected:
        _tr[miss] = notSelected.get(up) or 'not-selected'
    meta['requirements-tracer'] = {**meta.get('requirements-tracer', {}), key: _tr}
    if not (_items['items'] and up in selected):
        return False
    meta[up] = {**meta.get(up, {}), key: _items}
    return True

def _review_item_files():
    """계획 리뷰 항목이 이름으로 가리키는 변경 파일을 리뷰어 대상에 더한다.

    리뷰어는 받은 파일만 본다. 대상은 코드 파일(`logic`)이라, 리뷰 항목이 문서(예: DECISIONS.md 의 표)를
    가리키면 리뷰어가 "배정 밖" 으로 seen=false 를 내고 tracer 가 그 항목을 매번 MISSING 으로 연다.
    항목의 what·claim 에 변경 파일의 경로나 파일명이 그대로 있을 때만 더한다 — 해석하지 않는 문자열 대조다.
    파일명이 같은 변경 파일이 여럿이면 모두 더한다(덜 보는 쪽이 아니라 더 보는 쪽)."""
    items = ((meta.get('code-reviewer') or {}).get('planReview') or {}).get('items') or []
    have = set(selected.get('code-reviewer') or [])
    added = {}
    for f in changed:
        if f in have:
            continue
        pats = [re.escape(f), r'(?<![\w.-])' + re.escape(os.path.basename(f)) + r'(?![\w-])']
        refs = [i['ref'] for i in items
                if any(re.search(p_, f"{i.get('what') or ''}\n{i.get('claim') or ''}") for p_ in pats)]
        if refs:
            added[f] = refs
    if added:
        selected['code-reviewer'] = list(selected['code-reviewer']) + sorted(added)
        meta['code-reviewer'] = {**meta.get('code-reviewer', {}), 'planReviewFiles': added}

# 체인은 리터럴로 적는다 — lane-contract-check.sh 가 이 줄을 agents/*.md 의 needs 와 대조한다.
if 'requirements-tracer' in selected:
    if _chain_items('review', 'code-reviewer', 'planReview', 'reviewerNotSelected'):
        sequential.append(['code-reviewer', 'requirements-tracer'])
        _review_item_files()
    if _chain_items('test', 'test-runner', 'planTest', 'testRunnerNotSelected'):
        sequential.append(['test-runner', 'requirements-tracer'])

# CONTRACT: mutations-run-in-gate
# "변이 확인" 테스트 항목은 코드를 바꿔 실행해야 닫힌다. test-runner 는 원본을 고치지 않으므로
# 명세(plan.sh mutations)가 있으면 mutate.sh 를 **회귀 명령으로 확정**한다 — 기록 단계가 전사에서 그 실행을
# 센다(suite-not-run). 실행 자리는 test-runner 의 격리 worktree 다(원본 경로면 mutate.sh 가 거부한다).
# 명세가 없거나 틀렸으면 회귀 명령을 넣지 않고 그 사실을 tracer 에 넘긴다 — 변이 항목은 MISSING 이다.
if 'requirements-tracer' in selected and 'test-runner' in selected:
    _mr = subprocess.run([os.path.join(os.environ['SELFDIR'], 'plan.sh'), 'mutations', DIR],
                         capture_output=True, **_DEC)
    try:
        _mu = json.loads(_mr.stdout) if _mr.returncode == 0 else None
    except Exception:
        _mu = None
    if not isinstance(_mu, dict):
        _mu = {'status': 'ERROR', 'refs': [], 'reason': (_mr.stderr or '').strip()[:200] or 'plan-mutations-failed'}
    # 명세가 없어도 경로는 넘긴다 — 변이 항목이 MISSING 이 되면 어디에 명세를 두면 되는지가 보고에 남는다.
    if _mu.get('status') != 'NONE' or _mu.get('path'):
        _pt = meta.setdefault('requirements-tracer', {}).setdefault('planTest', {'items': []})
        _pt['mutations'] = {k: _mu.get(k) for k in ('status', 'path', 'cmd', 'refs', 'errors', 'reason') if _mu.get(k) is not None}
    if _mu.get('status') == 'FOUND' and _mu.get('refs'):
        _tm = meta.setdefault('test-runner', {})
        _tm['mutations'] = {'path': _mu['path'], 'refs': _mu['refs'], 'cmd': _mu.get('cmd')}
        _tm.setdefault('suites', []).append({
            'name': 'mutation', 'marker': 'mutate.sh',
            'cmd': f"bash {shlex.quote(os.path.join(os.environ['SELFDIR'], 'mutate.sh'))} --origin {shlex.quote(DIR)} "
                   f"{shlex.quote(_mu['path'])} <격리 worktree>",
            'why': _mu['refs']})

# 검사 대상의 다이제스트(lib.sh pf_index_digest — 정의는 거기 하나다). PR 모드는 base..HEAD.
def _index_digest(base=''):
    _p = subprocess.run(['bash', '-c', '. "$1/lib.sh"; pf_index_digest "$2" "$3"', '_',
                         os.environ['SELFDIR'], DIR, base], capture_output=True, text=True)
    return _p.stdout.strip() if _p.returncode == 0 else ''
cdigest = _index_digest(diff_from) if MODE == 'pr' else _index_digest()
# 분류가 본 인덱스 — record 가 다시 구해 대조한다(사유 `index-changed`, #8 R5). PR 모드는 인덱스를 안 본다.
index_tree = git('write-tree').strip() if MODE != 'pr' else ''
# 인덱스를 트리로 굳히지 못하면(미병합 항목 등) 검사 대상을 정할 수 없다 — 워킹트리로 대체하지 않고
# 분류를 실패시킨다(#8 I4). artifact 를 남기지 않으므로 record 도 기록하지 않는다.
if MODE != 'pr' and not index_tree:
    print('분류 실패 — 인덱스를 트리로 만들지 못했다(미병합 항목이 있는가?). 충돌을 해결하고 다시 분류해라.', file=sys.stderr)
    sys.exit(1)

# ── 스냅숏(#8 P2): lane 이 내용을 읽고 명령을 돌릴 체크아웃. 분류기는 **무엇을** 풀지만 정한다 —
#    만들고 대조하고 지우는 것은 워크플로가 snapshot.sh 로 한다(분류기를 여러 번 돌려도 부수효과가 없다).
#    tree: 커밋 모드는 인덱스 트리, PR 모드는 HEAD 트리(D1). checkout: 명령을 돌릴 lane(test-runner)이
#    있을 때만 체크아웃을 만든다 — 나머지 lane 은 트리 참조(`git show <tree>:<경로>`)로 읽는다.
#    baseline: tsc/jest 기준선을 잴 커밋. 스냅숏에 package.json 이 있을 때만 의미가 있다.
snap_tree = index_tree if MODE != 'pr' else (git('rev-parse', '--verify', '-q', 'HEAD^{tree}').strip() if has_head else '')
_needs_checkout = 'test-runner' in selected
# 기준선은 두 모드 모두 merge-base 다 — "이 브랜치가 새로 깨뜨린 것" 을 재려면 브랜치의 앞선 커밋이 만든 회귀도
# 비교 대상에 들어가야 한다. 커밋 모드는 base 를 따로 구하고, 못 구하면(origin 없음 등) HEAD 로 떨어진다.
def _baseline_commit():
    if MODE == 'pr':
        return base_merge or None
    if not has_head:
        return None
    _b = resolve_base()
    return (git('merge-base', _b, 'HEAD').strip() if _b else '') or head_sha or None
_baseline_ref = _baseline_commit() if _needs_checkout and snap_has('package.json') else None
snapshot_info = {
    'tree': snap_tree,
    'checkout': _needs_checkout,
    'baseline': _baseline_ref,
    'mutation': bool(((meta.get('test-runner') or {}).get('mutations'))),
    'tool': os.path.join(os.environ['SELFDIR'], 'snapshot.sh'),
    'token': SNAP_TOKEN,
}
classification_id = f'{branch}-{cdigest[:12]}'

def _pf_log(what, rec):
    """관측 로그에 한 줄 남긴다. **판정에는 개입하지 않는다.**

    lib.sh 의 PF_LOG 주석이 못박은 대로 — 못 써도 게이트 동작은 조금도 달라지지 않아야 한다.
    그래서 전부 삼키되 **조용히는 아니다**: 계측기가 죽은 것을 못 보면 없는 데이터를
    있다고 믿게 된다. 이 파일의 관측 이벤트는 전부 여기를 지난다 — 자리마다 열면
    실패 처리가 갈린다.
    """
    try:
        import time as _t
        _p = os.path.expanduser(os.environ.get('PF_LOG') or '~/.claude/preflight-log.jsonl')
        with open(_p, 'a') as _f:
            _f.write(_json_out({'ts': int(_t.time()), **rec}) + '\n')
    except Exception as _e:
        print(f'{what} 로그 실패: {_e}', file=sys.stderr)

# CONTRACT: advisory-logged-at-classify
# 여기서 남긴다. record 는 게이트를 통과해야 불리므로(FAIL 라운드에는 호출 자체가 없다)
# 거기 두면 "고위험 무계획" 이 아니라 "그중 고쳐진 것" 을 세게 된다 — 계획이 가장 아쉬웠을
# 라운드가 통째로 빠진다. 분류기는 라운드마다 돈다. 판정에는 개입하지 않는다.
# **집계할 때는 repo+branch 로 dedupe 한다.** 한 변경이 N 라운드 돌면 이벤트도 N 개인데,
# classificationId 는 contentDigest 기반이라 라운드마다 바뀌어 합쳐지지 않는다 —
# 그대로 세면 '계획이 필요했던 변경 수' 가 아니라 '게이트 라운드 수' 가 된다.
if plan_advisory:
    _pf_log('plan_advisory',
            {'event': 'plan_advisory', 'outcome': 'observed',
             'kind': MODE, 'repo': str(R), 'branch': branch,
             'risk': risk, 'plan': plan['status'], 'lanes': _risk_hits,
             'classificationId': classification_id})

# CONTRACT: round-logged-at-classify
# 위 advisory 와 **같은 논거다.** record 는 게이트를 통과해야 불리므로(FAIL 라운드에는 호출
# 자체가 없다) 거기 두면 통과한 라운드만 남는다 — 그런데 세려는 값이 정확히 "이 변경에
# 몇 라운드가 들었는가" 이고, 실패한 라운드가 안 보이면 그 값은 셀 수 없다. 분류기는
# 라운드마다 돌고 통과 여부를 모르므로 편향이 없다. 판정에는 개입하지 않는다.
#
# **집계는 `repo`+`branch`+`head` 로 묶고 `roundDigest` 로 라운드를 센다** (PR 은 `repo`+`branch`).
# 한 변경이 N 라운드 돌면 이벤트도 N 개인데, 그대로 세면 '변경 수' 가 아니라 '이벤트 수' 다.
# contentDigest 는 라운드마다 바뀌므로(고치면 내용이 바뀐다) **묶음 안의 서로 다른 값 개수**가
# 곧 라운드 수이고, 내용이 그대로인 재실행은 같은 값이라 하나로 합쳐진다.
# head 까지 묶는 이유: 커밋하면 head 가 바뀌므로 묶음이 **다음 커밋** 으로 갈린다 —
# 브랜치로만 묶으면 한 브랜치의 커밋 7개가 한 덩어리가 되어 커밋당 라운드 수가 안 나온다.
#
# `paths` 는 "무엇만 바뀐 라운드인가" 로 거르려고 넣는다(backlog 의 `agents/*.md` 항목).
# 상한을 두되 `files` 에 **자르기 전 개수**를 함께 남긴다 — `len(paths) == files` 일 때만
# "이것만 바뀌었다" 를 주장할 수 있고, 그렇지 않으면 모르는 것이 모른다고 보인다.
_PATHS_CAP = 100
# 라운드를 가르는 값. 커밋 모드는 contentDigest 그대로다. PR 모드는 PR 게이트가 실제로 보는 것 —
# merge-base..HEAD 의 커밋(= PR 모드 contentDigest) + PR 본문 — 으로 만든다.
# 묶음 키와 세는 방법의 정본은 docs/backlog.md 의 세는 명령이다.
def _round_digest():
    """(roundDigest, 이벤트에 덧붙일 필드). 무엇으로 셌는지를 roundBasis 로 남긴다 — 집계가 조용히
    줄어드는 갈래(merge-base 미해석·본문 읽기 실패)를 사후에 가를 수 있어야 한다."""
    import hashlib
    if MODE != 'pr':
        return cdigest, {}
    extra = {}
    body = os.environ.get('BODY_FILE') or ''
    bd = ''
    if body:
        try:
            bd = hashlib.sha1(Path(body).read_bytes()).hexdigest()
            extra['bodyDigest'] = bd
        except Exception as e:
            # 고정값으로 두면 본문을 고친 라운드가 전부 합쳐진다 — 못 읽었다는 사실을 남긴다.
            extra['bodyError'] = f'{type(e).__name__}: {e}'[:160]
    bdig = cdigest if base_merge else ''
    if bdig:
        extra['roundBasis'] = 'branch'
        basis = bdig
    else:
        # merge-base 를 못 구하면 브랜치 내용을 모른다 — 그때 contentDigest 는 빈 트리부터 HEAD 까지라
        # 브랜치의 PR 범위가 아니다. 그래서 head 로 가른다 — 커밋마다 새 라운드다(같은 커밋 위 재분류는
        # 여전히 합쳐진다).
        extra['roundBasis'] = 'head-fallback'
        basis = f'head:{head_sha}'
    return hashlib.sha1(f"{basis}:{bd}".encode()).hexdigest(), extra
_rdig, _rextra = _round_digest()
_pf_log('round',
        {'event': 'round', 'outcome': 'classified',
         'kind': MODE, 'repo': str(R), 'branch': branch, 'head': head_sha,
         'contentDigest': cdigest, 'roundDigest': _rdig, **_rextra,
         'classificationId': classification_id,
         'lanes': sorted(selected), 'files': len(changed), 'paths': changed[:_PATHS_CAP]})

# ── 사실 주장 검사 (claim-check ①②). lane 이 아니라 분류기가 직접 돈다 — 결정론이라 LLM 이 필요 없다.
# 판정에 개입하지 않는다(경고층): 4축 실측 전이다. 근거는 DECISIONS.md 2026-11-06.
# 문서도 분류와 같은 대상을 본다(#8) — 커밋 모드는 스테이징된 내용(`--cached`), PR 모드는 HEAD(`--to HEAD`).
# 워킹트리에만 있는 수정·미추적 문서는 커밋되지 않으므로 검사하지 않는다.
# 대상: 바뀐 .md · PR 모드의 커밋 메시지(merge-base..HEAD) · PR 본문 초안 · 커밋 메시지 초안.
def _claim_check():
    _chk = os.path.join(os.environ['SELFDIR'], 'claim-verify.sh')
    docs = [f for f in changed if f.lower().endswith('.md')]
    body = os.environ.get('BODY_FILE') or ''
    msg = os.environ.get('MSG_FILE') or ''
    commits = f'{base_merge}..HEAD' if MODE == 'pr' and base_merge else ''
    if not (docs or body or msg or commits):
        return {'status': 'NOT_APPLICABLE', 'reason': '바뀐 문서·커밋 메시지·PR 본문이 없다', 'checker': _chk}
    argv = [_chk, '--json', '--repo', DIR, '--from', diff_from if has_head else 'HEAD']
    if not docs or not has_head: argv.append('--no-docs')
    argv += ['--to', 'HEAD'] if MODE == 'pr' else ['--cached']
    if commits: argv += ['--commits', commits]
    if body: argv += ['--body-file', body]
    if msg: argv += ['--msg-file', msg]
    try:
        p = subprocess.run(argv, capture_output=True, timeout=120, **_DEC)
        d = json.loads(p.stdout) if p.returncode == 0 else None
    except Exception as e:
        return {'status': 'ERROR', 'reason': f'{type(e).__name__}: {e}'[:200], 'checker': _chk}
    if not isinstance(d, dict):
        return {'status': 'ERROR', 'reason': (p.stderr or '').strip()[-200:] or f'rc={p.returncode}', 'checker': _chk}
    # 분류 산출물은 프롬프트로 간다 — 지적은 상한을 두고 자른 개수를 남긴다
    fs = d.get('findings') or []
    return {'status': d.get('status'), 'counts': d.get('counts'), 'findings': fs[:50],
            'truncated': max(0, len(fs) - 50), 'scanned': d.get('scanned'), 'limits': d.get('limits'),
            'checker': _chk, 'remeasure': _remeasure_select(argv[2:])}

# ── 재측정 대상 (claim-check ③). 고르는 것은 결정론 코드다 — 규칙 줄을 지우거나 바꾼 변경의 비율·백분율·부재 주장.
# lane 이 아니다(selected 밖). 워크플로가 대상이 있을 때만 재측정 에이전트를 한 번 부르고 결과를 참고로만 낸다.
# 인자는 ② 와 같다 — 같은 문서·커밋·본문을 본다. 근거는 DECISIONS.md 2026-11-12.
def _remeasure_select(argv):
    _tool = os.path.join(os.environ['SELFDIR'], 'claim-remeasure.sh')
    try:
        p = subprocess.run([_tool, 'select', *argv], capture_output=True, timeout=120, **_DEC)
        d = json.loads(p.stdout) if p.returncode == 0 else None
    except Exception as e:
        return {'status': 'ERROR', 'reason': f'{type(e).__name__}: {e}'[:200], 'targets': [], 'tool': _tool}
    if not isinstance(d, dict):
        return {'status': 'ERROR', 'reason': (p.stderr or '').strip()[-200:] or f'rc={p.returncode}', 'targets': [], 'tool': _tool}
    return {'status': 'TARGETS' if d.get('targets') else 'NONE', 'targets': d.get('targets') or [],
            'ruleLines': d.get('ruleLines') or [], 'excludedCountOnly': d.get('excludedCountOnly', 0),
            'registry': d.get('registry') or [], 'errors': d.get('errors') or [], 'tool': _tool}
claim_check = _claim_check()

_payload_obj = {
    'repo': str(R),
    'mode': MODE,
    'branch': branch,
    # 이 분류가 **어느 작업 상태에 대한 것인가**. record 가 이 값을 다시 계산해 대조한다.
    'classificationId': classification_id,
    'contentDigest': cdigest,
    # 분류 호출마다 새로 뽑는 꼬리 — preflight.js 가 재측정 스냅숏 폴더 이름을 실행마다 다르게 하는 데 쓴다.
    #  워크플로 스크립트는 Math.random()/Date.now() 를 쓸 수 없으므로(resume 이 깨진다) 난수는 여기서 만든다.
    #  args 에 실려 들어가므로 resume 은 같은 값을 다시 받는다. 판정·결속에는 쓰지 않는다.
    'runNonce': os.urandom(6).hex(),
    # `--qa` 로 분류했는가. record 가 이 값으로 `--qa` 예외(커밋될 경로의 워킹트리 = 인덱스)를 건다(#8 R19).
    #  record 인자로는 끌 수 없다 — 지우면 스키마 검사가, qa lane 과 어긋나면 결속 검사가 거부한다.
    'qa': QA,
    # 분류가 본 인덱스 트리(커밋 모드). record 가 다시 구해 대조한다 — 사유 `index-changed`.
    'indexTree': index_tree,
    # 인덱스에 없는 미추적 파일 수. 정보일 뿐 판정에 쓰지 않는다(#8 D2).
    'untrackedCount': untracked_count,
    # lane 이 읽을 스냅숏 — 무엇을 풀지(트리)와 체크아웃이 필요한지. 경로는 워크플로가 만든다.
    'snapshot': snapshot_info,
    'hasHead': has_head,
    'head': head_sha,
    'plan': plan,
    # 대상 레포의 카테고리(categories/<이름>). 어느 카테고리에도 속하지 않으면 null 이다.
    'category': CAT_NAME,
    # 카테고리를 무엇으로 정했나(프로필 일치·신호 추론)와 적용된 프로필(없으면 null).
    'categoryBasis': CATEGORY_BASIS,
    'profile': PROFILE_OUT,
    'vaultLink': vlink,          # 작업이 랜딩할 때 vault 노트를 유지하려면 등록이 전제다
    'files': {
        'all': changed,
        'code': code_files,
        'vault': vault_files,
        'types': sorted(set(types_files)),
        'publicTypeSurface': surface_hits,
    },
    'selected': selected,
    'notSelected': notSelected,
    'sequential': sequential,
    'laneMeta': meta,
    # PR 모드가 무엇을 기준으로 diff 했는가. 폴백했으면 그 사유가 baseError 에 남는다.
    'base': {'ref': base_ref, 'mergeBase': base_merge, 'diffFrom': diff_from, 'error': base_err},
    'risk': risk,
    'planAdvisory': plan_advisory,
    'claimCheck': claim_check,   # 판정에 개입하지 않는다 — preflight.js 가 참고로 보고한다
    # 결정론 시크릿 스캔 결과(값 없음). record 가 같은 대상으로 다시 스캔해 status·patternsVersion 을 대조한다.
    'secretScan': secret_scan,
    'limits': {
        'codeLogicChange': 'diff 의 추가·삭제 라인이 전부 주석/공백이면 로직 미변경으로 본다 (휴리스틱, 불확실하면 변경으로 판정)',
        'prBaseDiff': (
            'PR 모드는 origin/HEAD 로 해석한 base 와의 merge-base 부터 HEAD 까지의 커밋만 본다 — '
            '스테이징·미스테이징·미추적 변경은 PR 에 들어가지 않으므로 대상이 아니다. '
            '로컬 base 브랜치가 낡아도 origin 기준이라 영향받지 않지만, origin 을 fetch 하지 않았으면 '
            'merge-base 가 뒤처져 변경 집합이 과대해진다.'
            if MODE == 'pr' else 'commit 모드는 HEAD 대 인덱스(커밋될 내용)를 본다 — 워킹트리에만 있는 변경과 미추적 파일은 대상이 아니다'),
        'publicTypeSurface': surface_err or (
            f'@types/tsconfig.build.json 기준 **로컬 상대 import 폐포** {len(surface)}개 파일. '
            'tsc 의 module resolution 과 같지 않다 — paths/baseUrl alias, 패키지 import 는 따라가지 않는다. '
            '정확한 표면이 필요해지면 tsc --listFiles 로 바꿔라.'),
    },
}
payload = _json_out(_payload_obj, indent=2)

print(payload)

# provenance artifact — receipt 가 이 파일을 읽어 "왜 이 lane 을 골랐나" 를 함께 기록한다.
# 쓰기를 마치면 쓴 바이트의 sha256 을 stderr 한 줄로 낸다(R31). stdout JSON 에 넣지 않는다 — 파일이 자기 해시를
# 담을 수 없다. 파일 옆에 따로 두지 않는다 — 다른 세션이 둘을 함께 덮어쓰면 대조가 무의미해진다.
# 쓰기가 실패하면 내지 않는다 — 호출자가 낡은 파일을 이번 분류로 넘기지 못하게.
import hashlib
_bytes = (payload + '\n').encode('utf-8', 'surrogateescape')
try:
    Path(os.environ['OUT']).write_bytes(_bytes)
except Exception as e:
    print(f'classify artifact 기록 실패: {e}', file=sys.stderr)
else:
    print(f'classify-sha256: {hashlib.sha256(_bytes).hexdigest()}', file=sys.stderr)
PY
