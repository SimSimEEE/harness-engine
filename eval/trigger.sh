#!/bin/bash
# trigger eval — 스킬 description 이 불러야 할 요청에서 불리고, 경계 요청에서는 안 불리는지 잰다.
#
# 왜 필요한가: preflight 는 훅이 강제하지만 plan·house-grid-setup 은 모델이 description 만 보고
# 고른다. description 을 고친 뒤 호출이 나아졌는지(또는 엉뚱한 요청까지 끌어오는지)는 같은 요청
# 묶음을 새 세션에 다시 던져 보는 것 말고는 알 방법이 없다. SKILL.md 는 세션에 고정되므로
# 지금 세션 안에서 확인할 수도 없다 — 매 요청을 `claude -p` 새 세션으로 돈다.
#
# usage:
#   trigger.sh run <out> [--k=N] [--jobs=J] [--model=M] [--match=RE] [--settings=FILE] [skill...]
#       <케이스 루트>/<skill>.json 의 should·near 요청을 k 번씩 새 세션에 던진다.
#       <out> 은 비어 있어야 한다. skill 을 안 주면 케이스 파일이 있는 스킬 전부.
#       --match 는 케이스 id 정규식(re.search) — 새로 넣은 케이스만 돌릴 때 쓴다.
#       --settings 는 세션마다 claude --settings 로 덧붙일 설정 — 설치 전 훅을 붙여 잴 때 쓴다.
#   trigger.sh score <out> [--min-agree=R] [--json]
#       should 는 대상 스킬 호출이 정답, near 는 미호출이 정답. 정답률이 R(기본 1.0) 미만인
#       스킬이 있으면 exit 1. 실행 오류(인증 만료·한도 등)가 하나라도 있으면 판정하지 않고 exit 2.
#
# 측정 대상은 **설치된** 스킬(~/.claude/skills/<skill>)이다 — CLI 는 체크아웃이 아니라 그걸 읽는다.
# run 은 설치본과 이 체크아웃의 description 해시를 meta.json 에 남기고, 다르면 경고한다.
#
# 안전: 세션마다 내장 도구를 Read·Grep·Glob·Skill 로 줄이고(Bash·Edit·Write 없음), MCP 쓰기 tool 을
# 막고, 권한 모드를 default 로 고정한다(사용자 설정이 auto 여도 -p 에서는 허용 목록 밖이 거부된다).
# 대상 판정은 첫 몇 턴의 Skill 호출만 보므로 --max-turns 를 작게 둔다.
#
# 환경변수 (오버레이 레포가 감싸 부를 때 쓴다 — 케이스 파일에는 조직 용어가 들어가므로 엔진에 두지 않는다):
#   TRIGGER_CASES_DIR    케이스 루트. 기본 <이 체크아웃>/eval/triggers
#   TRIGGER_SOURCE_ROOTS 스킬 정본 체크아웃 목록(콜론 구분) — 설치본과 description 해시를 대조할 때
#                        skills/<skill>/SKILL.md 를 이 순서로 찾는다. 기본 <이 체크아웃>
#   TRIGGER_DENY_TOOLS   세션에서 더 막을 도구 이름(공백 구분) — 외부에 쓰는 MCP tool 등
#
# 비용: 2026-11-06 claude-opus-5-5 로 40건 1회 $23.05 (건당 약 $0.58 — 대부분 세션 시작 맥락).
# description 을 고쳤을 때만 그 스킬 하나를 돌린다.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SELF")"
INSTALLED="${CLAUDE_HOME:-$HOME/.claude}/skills"
MAX_TURNS=3
BUDGET_USD=1
CASES="${TRIGGER_CASES_DIR:-$ROOT/eval/triggers}"
SOURCES="${TRIGGER_SOURCE_ROOTS:-$ROOT}"
# shellcheck disable=SC2206
DENY_TOOLS=(${TRIGGER_DENY_TOOLS:-})
src_skill() {  # 스킬 정본 SKILL.md 경로 — 없으면 빈 값
  local r; local IFS=:
  for r in $SOURCES; do [ -f "$r/skills/$1/SKILL.md" ] && { printf '%s' "$r/skills/$1/SKILL.md"; return; }; done
}

usage() { sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cmd="${1:-}"; shift || true
case "$cmd" in run|score) ;; *) usage ;; esac
out="${1:-}"; [ -n "$out" ] || usage
shift

desc_sha() {  # SKILL.md frontmatter 의 description 만 해시한다 — 본문 수정은 호출에 영향이 없다
  python3 - "$1" <<'PY'
import hashlib, re, sys
t = open(sys.argv[1], encoding='utf-8').read()
m = re.match(r'---\n(.*?)\n---', t, re.S)
fm = m.group(1) if m else ''
d = re.search(r'^description:(.*?)(?=^\S|\Z)', fm, re.S | re.M)
print(hashlib.sha256((d.group(1) if d else '').encode()).hexdigest()[:12])
PY
}

if [ "$cmd" = run ]; then
  k=1; jobs=4; model=""; match=""; extra=""; skills=()
  for a in "$@"; do
    case "$a" in
      --k=*) k="${a#--k=}" ;;
      --jobs=*) jobs="${a#--jobs=}" ;;
      --model=*) model="${a#--model=}" ;;
      --match=*) match="${a#--match=}" ;;
      --settings=*) extra="${a#--settings=}"; [ -f "$extra" ] || { echo "없는 설정 파일: $extra" >&2; exit 2; }; extra="$(cd "$(dirname "$extra")" && pwd -P)/$(basename "$extra")" ;;
      --*) echo "모르는 옵션: $a" >&2; exit 2 ;;
      *) skills+=("$a") ;;
    esac
  done
  if [ ${#skills[@]} -eq 0 ]; then
    for f in "$CASES"/*.json; do [ -f "$f" ] && skills+=("$(basename "$f" .json)"); done
  fi
  if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    echo "<out> 이 비어 있지 않다: $out — 다른 측정과 섞이지 않게 새 디렉터리를 써라" >&2; exit 2
  fi
  mkdir -p "$out"; out="$(cd "$out" && pwd -P)"
  command -v claude >/dev/null || { echo "claude CLI 가 없다" >&2; exit 2; }

  # 작업 목록: 줄마다 skill<TAB>kind<TAB>id<TAB>rep<TAB>cwd<TAB>prompt
  : > "$out/jobs.tsv"
  for s in "${skills[@]}"; do
    cases="$CASES/$s.json"
    [ -f "$cases" ] || { echo "없는 케이스: $cases" >&2; exit 2; }
    [ -f "$INSTALLED/$s/SKILL.md" ] || { echo "설치되지 않은 스킬: $INSTALLED/$s" >&2; exit 2; }
    python3 - "$cases" "$k" "$s" "$match" >> "$out/jobs.tsv" <<'PY' || exit 2
import json, os, re, sys
c = json.load(open(sys.argv[1], encoding='utf-8')); k = int(sys.argv[2]); s = sys.argv[3]; mt = sys.argv[4]
if c.get('skill') != s: sys.exit(f"케이스 파일의 skill({c.get('skill')}) 이 파일 이름({s}) 과 다르다")
cwd = os.path.expanduser(os.environ.get('TRIGGER_CWD_' + s.upper().replace('-', '_')) or c.get('cwd') or '~')
if not os.path.isdir(cwd): sys.exit(f"cwd 가 없다: {cwd} — TRIGGER_CWD_{s.upper().replace('-', '_')} 로 바꿔라")
ids = set()
for kind in ('should', 'near'):
    for it in c.get(kind, []):
        if it['id'] in ids: sys.exit(f"중복 id: {it['id']}")
        ids.add(it['id'])
        if '\t' in it['prompt'] or '\n' in it['prompt']: sys.exit(f"prompt 에 탭·줄바꿈: {it['id']}")
        if mt and not re.search(mt, it['id']): continue
        for r in range(1, k + 1):
            print('\t'.join([s, kind, it['id'], str(r), cwd, it['prompt']]))
PY
    a="$(desc_sha "$INSTALLED/$s/SKILL.md")"; _src="$(src_skill "$s")"
    if [ -n "$_src" ]; then b="$(desc_sha "$_src")"; else b="(정본 없음)"; fi
    [ "$a" = "$b" ] || echo "경고: $s 설치본 description($a) 이 정본 체크아웃($b) 과 다르다 — 측정은 설치본 기준" >&2
    printf '%s\t%s\t%s\n' "$s" "$a" "$b" >> "$out/desc.tsv"
  done

  python3 - "$out" "$k" "$model" "$(claude --version 2>/dev/null)" "$MAX_TURNS" "$extra" <<'PY'
import json, sys, datetime
out, k, model, ver, mt, extra = sys.argv[1:7]
d = {}
for l in open(f'{out}/desc.tsv', encoding='utf-8'):
    s, a, b = l.rstrip('\n').split('\t'); d[s] = {'installed': a, 'checkout': b}
json.dump({'k': int(k), 'model': model or None, 'cli': ver, 'maxTurns': int(mt), 'settings': extra or None,
           'startedAt': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
           'description': d}, open(f'{out}/meta.json', 'w'), ensure_ascii=False, indent=2)
PY
  n=$(wc -l < "$out/jobs.tsv" | tr -d ' ')
  echo "실행 $n 건 (jobs=$jobs) → $out" >&2

  export OUT="$out" MODEL="$model" EXTRA="$extra" MAX_TURNS BUDGET_USD DENY="${DENY_TOOLS[*]}"
  one() {
    IFS=$'\t' read -r s kind id rep cwd prompt <<< "$1"
    mkdir -p "$OUT/$s"
    f="$OUT/$s/$kind-$id-r$rep"
    margs=(); [ -n "$MODEL" ] && margs=(--model "$MODEL"); [ -n "$EXTRA" ] && margs+=(--settings "$EXTRA")
    [ -n "$DENY" ] && margs+=(--disallowedTools $DENY)
    # shellcheck disable=SC2086
    ( cd "$cwd" && claude -p "$prompt" --output-format stream-json --verbose \
        --permission-mode default --tools "Read,Grep,Glob,Skill" \
        --max-turns "$MAX_TURNS" --max-budget-usd "$BUDGET_USD" --no-session-persistence \
        "${margs[@]}" < /dev/null > "$f.jsonl" 2> "$f.err" )
    echo "$?" > "$f.exit"
    printf '.' >&2
  }
  export -f one
  # -I 는 쓰지 않는다 — BSD xargs 는 -I 치환 인자를 255 바이트로 자른다(한국어 프롬프트는 글자당 3바이트).
  tr '\n' '\0' < "$out/jobs.tsv" | xargs -0 -n1 -P "$jobs" bash -c 'one "$1"' _
  echo >&2
  exec "$SELF/trigger.sh" score "$out"
fi

# score
min=1.0; asjson=0
for a in "$@"; do
  case "$a" in
    --min-agree=*) min="${a#--min-agree=}" ;;
    --json) asjson=1 ;;
    *) echo "모르는 인자: $a" >&2; exit 2 ;;
  esac
done
[ -f "$out/jobs.tsv" ] || { echo "run 결과가 아니다: $out" >&2; exit 2; }
python3 - "$out" "$min" "$asjson" <<'PY'
import json, os, sys
from collections import defaultdict
out, mn, asjson = sys.argv[1], float(sys.argv[2]), sys.argv[3] == '1'

def parse(path, target):
    """대상 스킬 호출 여부, 대신 쓴 도구, 오류 사유."""
    hit, used, err, init = False, [], None, False
    try: lines = open(path, encoding='utf-8').read().splitlines()
    except OSError: return None, [], 'no-output'
    for l in lines:
        try: o = json.loads(l)
        except ValueError: continue
        t = o.get('type')
        if t == 'system' and o.get('subtype') == 'init':
            init = True
            if target not in (o.get('skills') or []): err = 'skill-not-loaded'
        elif t == 'assistant':
            for c in o.get('message', {}).get('content', []):
                if c.get('type') != 'tool_use': continue
                name = c.get('name', '')
                if name == 'Skill':
                    sk = (c.get('input') or {}).get('skill', '')
                    used.append('Skill:' + sk)
                    if sk.split(':')[-1] == target: hit = True
                else:
                    used.append(name)
        elif t == 'result':
            # 턴 상한(error_max_turns)은 오류가 아니라 관측 창의 끝이다 — 판정은 "N 턴 안에 불렀나"다.
            # 2026-11-06 실측: should 20건 전부 첫 턴에 Skill 을 불렀다. 안 부른 채 상한에 닿은 것은
            # 탐색(Grep·Read)을 이어 가던 경우였다.
            # 인증 만료·한도 초과는 응답이 "성공"으로 끝나기도 한다 — 본문으로 가른다
            txt = str(o.get('result', ''))
            if o.get('subtype') == 'error_max_turns':
                pass
            elif o.get('is_error') or 'Failed to authenticate' in txt or 'usage limit' in txt.lower():
                if not hit: err = err or ('api-error: ' + txt[:80])
    if not init: err = err or 'no-init'
    return hit, used, err

jobs = [l.rstrip('\n').split('\t') for l in open(f'{out}/jobs.tsv', encoding='utf-8') if l.strip()]
rows, errors = [], []
for s, kind, cid, rep, cwd, prompt in jobs:
    f = f'{out}/{s}/{kind}-{cid}-r{rep}'
    hit, used, err = parse(f + '.jsonl', s)
    if err:
        errors.append({'skill': s, 'id': cid, 'rep': rep, 'error': err}); continue
    ok = hit if kind == 'should' else not hit
    rows.append({'skill': s, 'kind': kind, 'id': cid, 'rep': int(rep), 'hit': hit, 'ok': ok,
                 'used': used, 'prompt': prompt})

agg = defaultdict(lambda: {'should': [0, 0], 'near': [0, 0]})
for r in rows:
    a = agg[r['skill']][r['kind']]; a[1] += 1; a[0] += r['ok']
summary = {}
for s, a in agg.items():
    tot = a['should'][1] + a['near'][1]
    summary[s] = {'should': f"{a['should'][0]}/{a['should'][1]}", 'near': f"{a['near'][0]}/{a['near'][1]}",
                  'agree': round((a['should'][0] + a['near'][0]) / tot, 3) if tot else None}
fails = [r for r in rows if not r['ok']]
res = {'summary': summary, 'fails': fails, 'errors': errors, 'meta': json.load(open(f'{out}/meta.json'))}
if asjson:
    print(json.dumps(res, ensure_ascii=False, indent=2))
else:
    print(f"{'skill':<20} {'should(호출)':>12} {'near(미호출)':>12} {'agree':>7}")
    for s, v in summary.items():
        print(f"{s:<20} {v['should']:>12} {v['near']:>12} {v['agree']!s:>7}")
    for r in fails:
        what = '안 불림' if r['kind'] == 'should' else '잘못 불림'
        print(f"  ✗ {r['skill']} {r['kind']} {r['id']} r{r['rep']} {what} — 대신: {', '.join(r['used'][:4]) or '도구 없음'}")
        print(f"      {r['prompt']}")
    for e in errors:
        print(f"  ! {e['skill']} {e['id']} r{e['rep']} 실행 오류: {e['error']}")
if errors:
    print(f"실행 오류 {len(errors)}건 — 판정하지 않는다", file=sys.stderr); sys.exit(2)
if not rows:
    print("판정할 실행이 없다", file=sys.stderr); sys.exit(2)
sys.exit(1 if any(v['agree'] is not None and v['agree'] < mn for v in summary.values()) else 0)
PY
