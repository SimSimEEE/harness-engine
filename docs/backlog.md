# 백로그 — 게이트가 남긴 참고

**참고(`blocking: false`)는 다음 라운드로 끌고 가지 않는다.** 고치면 새 코드가 생기고, 새 코드는
새 검토 표면이라 또 참고가 나온다 — 무한 회귀다. 여기 쌓아 두고 별도 커밋으로 한 번에 처리한다.

판단 근거: 이 하네스를 처음 커밋할 때 첫 커밋에 6라운드, 두 번째에 4라운드가 들었고 그중 절반이
blocking 없이 끝났다. 게이트가 요구한 것이 아니라 참고를 쫓아서 돈 라운드다.

---

## 열림

### flip score 의 드리프트 검사가 prepare·score 사이의 재링크를 못 잡는다
위치: `skills/preflight/eval/flip.sh` score 의 드리프트 계산.

prepare 가 기록한 실경로(`agentSources[l].source`)를 다시 해시하므로, 그 사이 설치본 링크가 다른 정의로 바뀌면 워크플로는
새 정의로 도는데 드리프트는 없다고 나온다.

→ 닫는 방법: 링크 경로(`AGENTS_DIR/<lane>.md`)도 기록하고 score 때 그 실경로가 기록과 다르면 경고한다.

**먼저 셀 것**: 측정 도중 설치를 바꾼 적이 있는지(없으면 우선순위 낮음).

**실측 (2026-11-25)**: 남아 있는 lane 측정 디렉터리(회귀 스위트 임시 디렉터리 제외)는 4개, 모두 prepare 에서 마지막 결과까지 3~7분.
그 구간 안에 설치본 agents 링크가 바뀐 적은 0회(링크 재설정은 측정이 없던 시각에 한 번), 엔진·오버레이 체크아웃이 그 구간에 받은
갱신 중 `agents/` 를 바꾼 것도 0. → 우선순위 낮음 유지. 측정 중 설치를 바꾸는 운영이 생기면 다시 센다.

### unittest 확정 명령이 두 패턴에 걸리는 파일을 두 번 돌린다
`classify.sh` 의 Python 테스트 블록은 unittest 레포에서 디렉터리마다 패턴별로 discover 명령을 하나씩 낸다 — 한 디렉터리에
`test_a.py` 와 `b_test.py` 가 같이 있으면 `-p 'test_*.py'` 와 `-p '*_test.py'` 두 명령이다. 같은 디렉터리에 `test_c_test.py` 처럼
두 패턴에 모두 걸리는 파일이 있으면 그 파일의 테스트는 두 명령에서 한 번씩, 두 번 돈다. 판정은 틀리지 않는다(같은 테스트를
두 번 돌릴 뿐) — 비용과 출력 중복만 생긴다. pytest 경로는 디렉터리를 인자로 넘기므로 해당 없다.

재현: 위 세 파일을 한 디렉터리(TestCase 형, pytest 신호 없음)에 두고 `.py` 로직을 바꿔 분류 → `python-tests:<dir>:test_*.py`·
`python-tests:<dir>:*_test.py` 두 명령, 둘 다 `test_c_test.py` 를 수집한다.

→ 닫는 방법 후보: 두 패턴이 다 있는 디렉터리는 `*_test.py` 쪽 명령에서 `test_` 로 시작하는 파일을 빼는 패턴(`[!t]*_test.py` 류)으로
좁히거나, 두 패턴을 한 번에 수집하는 단일 명령으로 바꾼다 — `marker` 문자열이 바뀌므로 기록 단계 대조(py(f)) 회귀를 함께 고친다.

**먼저 셀 것**: 게이트를 지나는 Python 레포에서 (1) 두 패턴 파일이 한 디렉터리에 같이 있는 디렉터리 수, (2) 그중 두 패턴에 모두 걸리는
파일이 있는 디렉터리 수 — `git ls-files '*.py'` 를 디렉터리별로 묶어 센다.

지금 고치지 않는 이유: 관찰상 로컬의 Python 테스트 레포에서 (2) 에 해당하는 디렉터리를 찾지 못했다 — 실제로 비용이 생기는 레포가 없다(2026-11-25).


### `_nocode` 는 블록 주석을 걸러내지 않는다
`skills/preflight/meta-test/lib.sh` 의 `_nocode` 와 `CONTRACT: structural-guards-count-occurrences`

제외 패턴이 `^[[:space:]]*(#|//)` 라 `/* … */` 안의 줄과 JSDoc 의 ` * ` 줄은 그대로 세어진다.
계약의 한계 열거에는 행말 주석과 문자열만 적혀 있어 이 갈래가 빠졌다.

지금 살아 있는 사례는 없다 — 아래 첫 명령이 0 이고, 나머지 대상은 셸·python 이라 블록 주석
문법 자체가 없다. 위험은 **fail-open 쪽**이다: `-ge N` 가드에서 과다계수는 통과시키므로,
임계에 걸려 있는 항목이면 블록 주석 안의 언급 하나가 진짜 호출부 삭제를 되메운다.

```bash
grep -cE '^[[:space:]]*(/\*|\*)' skills/preflight/preflight.js          # 현재 0
printf 'a\n/* json.dumps( */\n * json.dumps(\n' \
  | grep -vE '^[[:space:]]*(#|//)' | grep -oE 'json\.dumps?\(' | wc -l   # 2 — 걸러지지 않는다
```

→ 닫는 방법: 제외 패턴에 `/\*`·`\*/`·`^[[:space:]]*\*` 를 더하거나, 최소한 한계 열거에
"블록 주석·JSDoc 안의 줄은 세어진다" 를 적어 `preflight.js` 에 JSDoc 을 넣는 사람이 알게 한다.
**먼저 셀 것**: `-ge N` 가드 중 실측이 임계와 같은 것의 개수 — 여유가 있으면 되메움이 닿지 않는다.

이관: 2026-11-26 오버레이 백로그에서.

### 훅 deny 폴백이 레포 밖 파서의 관용에 기대고 있다
`hooks/preflight-gate.sh` 의 `pf_deny`

폴백이 짝 없는 surrogate 를 `\udcXX` 로 이스케이프해 내보내고, 주석은 "JSON 으로 유효하고
소비자가 되돌린다" 고 단언한다. 그 소비자는 Claude Code 의 훅 러너로 **이 레포 밖이고 근거가
레포 안에 없다.** 짝 없는 surrogate 이스케이프는 python·JS 파서는 받지만 거부하거나 U+FFFD 로
치환하는 파서도 있다. 거부되면 deny 응답이 버려지고 훅은 뒤이어 `exit 0` 하므로 커밋이 그냥
통과한다 — `pf_deny` 위 주석(`CONTRACT: hook-deny-must-reach-stdout`)이 스스로 적어 둔 실패 모드다.
현재 가드는 훅 자신의 stdout 에 `"deny"` 문자열이 있는지만 보므로 이 갈래를 잡지 못한다.

내보내는 형태 (2026-11-26 확인 — 폴백은 `ensure_ascii=True` 라 한글도 `\uXXXX` 로 나간다):

```bash
PF_DENY_REASON="경로: /x/$(printf '\xff')" python3 -c '
import json, os, sys
d={"hookSpecificOutput":{"permissionDecisionReason":os.environ["PF_DENY_REASON"]}}
s=json.dumps(d, ensure_ascii=False)
try: s.encode("utf-8")
except UnicodeEncodeError: s=json.dumps(d, ensure_ascii=True)
sys.stdout.buffer.write(s.encode("utf-8","surrogateescape")+b"\n")'
# {"hookSpecificOutput": {"permissionDecisionReason": "경로: /x/\udcff"}}
```

→ 닫는 방법: 소비자 계약에 기대지 않는 형태로 바꾼다 — `dumps` 전에 reason 을
`.encode('utf-8','backslashreplace').decode('utf-8')` 로 정규화하면 surrogate 가 애초에 남지
않아 `ensure_ascii=False` 가 늘 성공하고 폴백 갈래 자체가 사라진다. 경로가 `\xff` 로 보이는
것은 사람이 읽는 데 문제되지 않는다. **먼저 셀 것**: 이 갈래에 도달하려면 비UTF-8 경로가
필요하다 — 게이트가 도는 환경 중 그런 경로가 가능한 것(Linux 체크아웃)의 비율.

이관: 2026-11-26 오버레이 백로그에서.

### `_disp` 가 경로 출력 집합의 일부만 덮는다
`skills/preflight/receipt.sh` · `lib.sh` 의 `CONTRACT: json-out-is-one-function`

`lib.sh` 는 "사람에게 보이는 경로는 `backslashreplace` 로 이스케이프한다" 를 집합 전체에
걸리는 계약으로 선언했지만, `receipt.sh` 에는 `_disp` 를 거치지 않고 전사 디렉터리 경로(`tdir`)를
그대로 끼워 출력하는 자리가 **4곳** 있다(2026-11-26 아래 명령 출력). 영향은 fail-closed 다 —
`print` 의 `UnicodeEncodeError` 는 잡히지 않아 스크립트가 0 아닌 코드로 죽고 `record` 가 남지 않는다.
게이트는 뚫리지 않고 거부 사유 문구만 사라진다.

```bash
python3 - <<'PY'
import re, io
t = io.open('skills/preflight/receipt.sh', encoding='utf-8').read().split('\n')
for i,l in enumerate(t,1):
    if 'print(' in l and '_disp(' not in l and re.search(r'\{[a-z_]*(dir|path|tdir)\b[^}]*\}', l):
        print(i, l.strip())
PY
```

→ 닫는 방법: 그 자리들의 보간을 `_disp()` 로 감싼다. 집합 전체를 보장하려면 개수 표 옆에
"경로를 보간하는 `print` 는 전부 `_disp` 를 지난다" 는 구조 가드를 하나 더 둔다.
**먼저 셀 것**: `transcripts-unreadable` 거부의 빈도 — 0 이면 그 문구가 사라져도 아무도
못 본다는 뜻이고, 가드를 새로 두는 비용이 더 크다.

이관: 2026-11-26 오버레이 백로그에서.

### stdout 의 인코딩 오류 처리는 로케일에 달려 있다
`skills/preflight/*.sh`·`hooks/preflight-gate.sh` 의 python 블록 전부

`sys.stdout.errors` 는 환경이 정한다. `LANG` 이 비어 있으면 `surrogateescape` 라 인코딩 불가 문자를
그냥 흘려보내지만, `LANG=en_US.UTF-8` 이면 `strict` 가 되어 죽는다.
**즉 같은 코드가 환경에 따라 다르게 실패한다** — 로컬에서 초록불인 것이 CI·클라우드 세션에서
빨간불일 수 있고, 그 반대도 된다. 파일 write 는 어느 쪽이든 `strict` 다.

재현 (2026-11-26, `LANG` 이 빈 macOS 에서 첫 줄 `surrogateescape`, 둘째 줄 `strict`):

```bash
python3 -c 'import sys; print(sys.stdout.errors)'
LANG=en_US.UTF-8 python3 -c 'import sys; print(sys.stdout.errors)'
```

지금 경로를 싣는 자리는 전부 로케일에 기대지 않도록 고쳐 뒀다(`_json_out` 폴백,
`sys.stdout.buffer.write(..., "surrogateescape")`). 남은 것은 **새로 추가되는 python 블록이
같은 실수를 반복하는 것**을 막을 장치가 없다는 점이다 — 레포 안에 `PYTHONIOENCODING` 을 세우는 자리는 없다.

→ 닫는 방법: 각 블록 앞에 `PYTHONIOENCODING=utf-8:surrogateescape` 를 세워 환경차를 없애면
개별 폴백이 필요 없어진다. **먼저 셀 것**: 게이트가 도는 환경의 `LANG` 분포. 전부 비어
있으면 지금 상태로 충분하고, 클라우드 세션이 UTF-8 로케일이면 그쪽이 먼저다.

```bash
python3 -c "
import json
rs=[json.loads(l) for l in open('$HOME/.claude/preflight-log.jsonl') if l.strip()]
print(len({r.get('repo') for r in rs}), 'repos', len(rs), 'events')"
```

이관: 2026-11-26 오버레이 백로그에서.

### 라운드 집계 규칙의 산문이 세 곳에 있다
`skills/preflight/classify.sh` 의 `CONTRACT: round-logged-at-classify` 주석 ·
`skills/preflight/SKILL.md` § 관측 로그 · 이 파일의 「기준을 고치는 비용」 항목(닫힘 절)

집계 규칙의 **설명**이 세 곳에 따로 적혀 있다 — 묶음 키가 `repo`+`branch`+`head` 인 것,
라운드를 다이제스트의 가짓수로 세는 것, `paths` 상한과 `files` 의 관계. "두 곳에 같은 글을 두면
갈린다" 를 근거로 SKILL→backlog 포인터를 메타테스트로 못박았는데, 정작 이 규칙에는 그 원칙이
적용되지 않았다.

붙잡히는 것과 아닌 것이 갈린다. backlog 의 **명령**은 메타테스트가 문서에서 꺼내 실제로
돌리므로 필드 이름이 갈리면 빨개진다(재현: `skills/preflight/meta-test.sh` 를 돌리고
`라운드를 셀 수 있는가` 절의 "backlog 에 적힌 세는 명령이 실제로 돈다" 를 본다). 붙잡히지
않는 것은 세 곳의 **산문**이다 — 묶음 키를 바꾸면 손으로 세 곳을 고쳐야 하고, 하나를
빠뜨려도 게이트는 조용하다.

→ 닫는 방법: `classify.sh` 주석에는 **왜 여기서 남기는가**(분류기는 라운드마다 돌고 통과
여부를 모른다 · FAIL 라운드가 표본에 들어간다)만 남기고, 집계 **방법**의 정본은 이 파일
한 곳에 두고 SKILL.md 처럼 가리키기만 한다.

**먼저 셀 것**: 묶음 키나 이벤트 필드가 실제로 바뀌는 빈도. 한 번도 안 바뀌면 세 곳이 갈릴
일도 없고, 정본을 옮기는 것 자체가 새 코드다 — 이 항목이 막으려는 것과 같은 부류의 비용이다.
엔진 이력은 가져오기 커밋에서 시작하므로 그 이전 변경은 이 명령에 나오지 않는다:

```bash
git log --oneline -S'contentDigest' -- skills/preflight/classify.sh | wc -l
```

이관: 2026-11-26 오버레이 백로그에서.

### finding id 가 실행마다 달라진다
`skills/preflight/preflight.js` 의 `findings[].id` 설명·`findingId`·`recurrence` · `agents/pr-quality.md`

스키마와 에이전트 정의가 모두 "같은 결함이면 실행이 바뀌어도 **같은 값**" 을 요구하는데,
같은 advisory 하나에 `pr-quality` 가 실행마다 다른 id 를 냈다(2026-09-18, 오버레이 시절 두 PR 게이트
실행의 전사: 하나는 `base/branch`, 하나는 `base-branch-warning`).

게이트는 `findingIds` 를 다음 라운드 `priorFindings` 로 넘겨 "같은 id 가 다시 나오면 재발" 로 세는데,
새 id 로 다시 내면 그 카운트가 **조용히** 빈다. verdict 와 달리 사람 눈에 아무 증상도 안 보인다.

**같은 입력 안에서도 갈린다 (2026-10-27).** `skills/preflight/eval/flip.sh` 로 같은 입력을 5번씩
돌렸더니 판정은 기대와 전부 맞았는데 막은 실행들의 id 는 갈렸다 — `refund-retry-double` 의
리뷰는 최빈 id 가 5회 중 2회, `body-gate-terms` 의 형식 검사는 5회 중 3회였다. 재현:

```bash
P=~/.claude/skills/preflight; $P/eval/flip.sh prepare <빈 디렉터리>
# 각 <입력>/args.json 으로 preflight.js 워크플로를 5번 → 결과 파일을 줄마다 "<입력> <파일>" 로 적고
$P/eval/flip.sh score <그 디렉터리> @<runs 파일>      # 줄마다 'id 고정 N%'
```

**닫힌 갈래 — 어휘가 있는 lane (2026-10-27).** 어휘가 있는 lane 은 id 를 짓지 않는다. 닫힌 어휘에서
`rule` 을 고르고 `symbol` 을 적으면 워크플로가 `rule@파일#심볼` 로 계산한다(`preflight.js` 의
`findingId` · 어휘는 같은 파일의 `RULES` 와 검사기 `--rules`). 리뷰·PR 형식 lane 을 같은 명령으로 다시
재니 막은 실행의 `id 고정` 이 두 입력 모두 5회 중 5회가 됐다. 2026-11-26 엔진의 `RULES` 는
`code-reviewer`·`pr-quality`·`vault-linter`·`test-runner` 네 lane 을 덮는다.

**verdict 매핑 갈래도 닫혔다 (2026-09-18).** 같은 입력에 verdict 가 갈리던 원인은 `MAPPING` 이
blocking 만 말하고 막지 않는 결과의 verdict 를 말하지 않은 것이었다. 지금은 메타테스트(`lane 마다
verdict 매핑이 있는가`)가 양쪽을 요구한다. 효과(사람이 승인으로 넘긴 횟수)는 아직 안 쟀다 — 관측 로그는
머신의 모든 레포를 담아 창을 고정하지 않은 합계는 재현되지 않으므로, 매핑 도입 시각을 기준으로 전/후를
lane 별로 가른다:

```bash
CUTOFF=<매핑 도입 시각(2026-09-18)의 epoch 초>
python3 - ~/.claude/preflight-log.jsonl "${CUTOFF:-0}" <<'ZW'
import collections, json, sys
cut = int(sys.argv[2] or 0)
before, after = collections.Counter(), collections.Counter()
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except: continue
    if e.get('event') != 'record' or e.get('outcome') != 'recorded': continue
    bucket = after if e.get('ts', 0) >= cut else before
    for lane, d in (e.get('laneDetail') or {}).items():
        if isinstance(d, dict) and d.get('waived'):
            bucket[lane] += 1
for label, c in (('이전', before), ('이후', after)):
    print(f'기준 {label}: 합계 {sum(c.values())}')
    for lane, n in c.most_common():
        print(f'  {n:3d}  {lane}')
ZW
```

진짜 확인이 필요했던 승인이 섞여 있으므로 '이전' 쪽 수치는 상한이다. 매핑을 채운 lane 의 승인 빈도가
줄었는지가 질문이고, 나머지 lane 은 대조군이다.

**남은 것 1 — 재발 집계의 한계.** 결과의 `recurrence` 는 id 문자열을 맞출 뿐이라 id 가 결함을
가르는 만큼만 정확하다. 같은 파일·같은 심볼에 rule `other` 로 낸 서로 다른 참고 두 건이 `재발` 로
세어진 적이 있다. `other` 가 많이 나오면 어휘에 rule 을 더해야 한다는 신호다 — 먼저 `other` 비중부터 센다.

**남은 것 2 — 파일 없는 id 의 해소.** `recurrence` 는 `@파일` 이 없는 id 를 lane 이 돌았으면 본 것으로
친다(`if (at < 0) return true`). PR 형식 lane 에는 맞지만, 리뷰 lane 이 `file` 을 비우면 id 가 `rule#심볼` 이
되고 다음 라운드에 대상 파일이 바뀌면 안 본 것이 해소로 세어진다.
→ 닫는 방법: 파일 없는 id 는 파일을 보지 않는 lane(`selected` 가 빈 lane)에서만 해소로 친다.

**남은 것 3 — 어휘가 없는 lane.** 나머지 lane 은 여전히 lane 이 id 를 짓는다. 넓히려면 그 lane 의 고정
입력부터 `eval/fixtures/` 에 넣고 같은 명령으로 먼저 센다.

**먼저 셀 것**: 리뷰 lane 지적 중 `file` 이 빈 비율(0 이면 남은 것 2 는 손댈 이유가 없다), 그리고 라운드를
넘긴 재발이 실제 브랜치에서 얼마나 쌓이는가 — 결과의 `recurrence` 가 센다.

이관: 2026-11-26 오버레이 백로그에서.

### 만료돼 축약된 PR 표식이 스키마 v1 로 오분류돼 거부된다
`skills/preflight/receipt.sh` · verify 검사 순서 · PR 표식 축약 보존과 함께 생김

24h 정리가 `pr` 을 `{'ts': N, 'pruned': True}` 로 축약해 남기는데 여기엔 `indexTree` 가 없다.
`verify` 는 rec 존재 → **indexTree 부재** → ts 만료 순으로 보므로, 만료된 표식으로 PR 을
만들려 하면 실제 사유(만료)가 아니라 "구 버전 게이트 기록 (스키마 v1)" 으로 거부된다.

게이트는 열리지 않는다(fail-closed 유지). 잘못되는 것은 **사유**다 — `_deny` 사유가 오분류돼
deny 사유 분포가 오염된다. 축약 보존 전에는 만료된 `pr` 이 통째로 삭제돼 "기록 없음" 으로
떨어졌으므로 이 오분류는 축약 보존이 만든 것이다.

```bash
grep -n "'indexTree' not in rec\|time.time() - rec.get('ts'" skills/preflight/receipt.sh   # 부재 검사가 만료 검사보다 앞
```

→ 닫는 방법: ts 만료 검사를 indexTree 검사보다 앞으로 옮기거나, `rec.get('pruned')` 를 명시적으로
거부 분기로 둔다. 어느 쪽이든 `receipt.sh` 정리 루프 위의 "`verify` 는 ts 만료를 따로 거부하므로" 주석을
**실제로 발화하는 검사 이름**으로 고쳐 적는다 — 지금 그 주석은 결론만 맞고 메커니즘이 틀렸다.

이관: 2026-11-26 오버레이 백로그에서.

### PR 표식 스텁이 삭제된 브랜치에도 영구히 남는다
`skills/preflight/receipt.sh` · 정리 루프 · 위 항목과 같은 변경에서 생김

축약으로 레코드 크기는 수 KB → 약 40 bytes 가 됐지만(재현:
`python3 -c "import json;d=json.load(open('$(git rev-parse --absolute-git-dir)/claude-preflight.json'));print({k:len(json.dumps(v,ensure_ascii=False)) for b,e in d['branches'].items() for k,v in e.items()})"`),
`if not _e: del data['branches'][_b]` 가 스텁 때문에 **영원히 참이 되지 않는다.** PR 게이트를
한 번이라도 통과한 브랜치는 브랜치가 삭제된 뒤에도 엔트리가 남고, `classify`·`verify` 가
매 실행마다 이 파일을 통째로 읽는다. 누적은 브랜치 수에 비례한다.

의도된 보존(`classify.sh` 의 `_branch_has_pr_gate` docstring)과 충돌하지 않는 좁은 보완이 가능하다 —
정리 때 `git show-ref --verify --quiet refs/heads/<branch>` 가 실패하는 브랜치의 스텁만
수확한다. 또는 스텁에만 훨씬 긴 상한(90일)을 두고 그 근거를 docstring 의 "만료를 두지
않는다" 옆에 같이 적는다.

**먼저 셀 것**: 영수증에 실제로 쌓인 브랜치 엔트리 수와 파일 크기. 수십 개
수준이면 읽기 비용이 무의미하므로 문서만 고치고 닫는다.

이관: 2026-11-26 오버레이 백로그에서.

### `limits` 가 돌지 않은 검사를 검증했다고 말한다
`skills/preflight/receipt.sh` · 영수증의 `limits` 문자열

전사를 넘기면 "실행 사실·순서·판정 승격까지" 검증했다고 적는데, **순서**는
`classify.sequential` 체인이 있을 때만 검사된다. 체인이 없는 분류에서는 `sequential=[]` 이고 그 루프가
0회 돈다.

→ 조건이 아니라 **실제로 돈 검사 목록**에서 조립한다. `['실행 사실', '판정 승격']` 으로 시작해
`sequential` 이 비어 있지 않을 때만 `'순서'` 를 넣는다.

이관: 2026-11-26 오버레이 백로그에서.

### 주석 하나가 수정 경위를 담고 있다
`skills/preflight/receipt.sh` · 승격 트리거 위

`(ERROR 가 그 자리였다)` — 무엇이 하드코딩돼 있었는지의 경위다. 앞 문장(`_RANK` 가 유일한
출처)만 남기고 이 괄호는 `DECISIONS.md` 나 커밋 메시지 몫이다.

```bash
grep -n 'ERROR 가 그 자리였다' skills/preflight/receipt.sh
```

이관: 2026-11-26 오버레이 백로그에서.

### `--copy` 가 삭제·이름변경된 파일을 걷어내지 않는다
`install.sh` · 복사 모드(합치기)

`cp -R "$base/." "$target/"` 는 덮어쓰기만 하므로 레포에서 지워진 agent·skill 이 `~/.claude` 에
남는다(링크 모드는 대상이 사라진 링크를 걷어내지만 복사 모드에는 그 단계가 없다). 클라우드는 설치
결과가 환경 스냅샷에 캐시돼 정리 계기가 오지 않는다.

→ 복사 전에 **레포가 소유한 이름만** 지운다:
`for e in "$base"/*; do rm -rf "$target/$(basename "$e")"; done`
플랫폼이 넣은 것은 안 건드리면서 이름변경 잔재는 사라진다. 다만 레포에서 **지워진** 이름은 이 루프로도
안 사라진다 — 지난 설치의 목록을 남겨 두고 차집합을 지워야 한다.

이관: 2026-11-26 오버레이 백로그에서.

### 게이트 간 결속을 `contentDigest` 로 할 수 없다 — 설계 필요
`skills/preflight/classify.sh` · `_commit_gate_qa()`

"테스트 파일만 바뀌었으면 직전 QA 통과를 근거로 생략" 을 넣으려면 **직전 게이트의 검증 대상과
지금 대상이 같은가**를 판정해야 하는데, `contentDigest` 로는 안 된다.

`contentDigest`(`lib.sh` 의 `pf_index_digest`)는 커밋 모드에서 **HEAD 대비 스테이징된 변경**이다.
커밋 뒤에는 그 차이가 비어 빈 입력의 해시가 나온다(2026-09 오버레이 시절 관측 로그 183건 중 42건이
빈 해시였다 — 재확인 안 함). 영수증에 박히는 값은 커밋 게이트 시점의 것이므로 **원리상 같아질 수 없다.**
커밋 게이트 재실행도 같다 — 파일이 바뀌었으니 다시 도는 것이라 다이제스트가 반드시 다르다.

→ 결속은 **커밋된 트리**로 해야 한다. 영수증의 `indexTree` 를 PR 게이트에서
`git rev-parse HEAD^{tree}` 와 대조하고, 커밋 게이트 재실행 갈래는 다이제스트 동일성이 아니라
"기록 이후 프로덕션 파일이 안 바뀌었는가(변경 집합이 spec 뿐인가)" 로 판정한다.

메타테스트도 영수증을 위조해 심지 말고 **커밋 게이트 → 커밋 → PR 게이트** 순서를 실제로 재현해야
한다 — 위조하면 실제 흐름에서 일어날 수 없는 시나리오를 인증하게 된다(그렇게 만든 적이 있다).

**주의**: `_commit_gate_qa()` 는 지금도 PR 게이트의 `qa-done-at-commit-gate` 사유와 `placement`
문구에 쓰인다. 그쪽은 안내 문구일 뿐 판정을 바꾸지 않으므로 현행 유지. `classify.sh` 의 한 주석이
이 항목을 가리킨다("contentDigest 로 할 수 없어서다(docs/backlog.md)").

이관: 2026-11-26 오버레이 백로그에서.

### QA 체인이 병렬 lane 을 기다린다 — 벽시계 31%
`skills/preflight/preflight.js` · `results = await parallel(…)` 뒤의 `for (const chain of qaChains)`

병렬 배치가 **전부** 끝나야 QA 체인 루프가 시작한다. 그런데 `qa-runner` 프롬프트는
`laneScope`·`snapFor`·`laneMetaBlock`·`priorBlock`(직전 **라운드**)·`qaFocus` 뿐이라 **같은 라운드의 다른
lane 결과를 받지 않는다.** `prior` 는 체인 안(`chain[0]`)에서만 채워진다.

지금 코드는 이 순서에 이유를 하나 적는다 — "QA 체인은 dev 에 부수효과를 내므로 Gate 뒤 QA 단계에서
따로 돈다". Gate 결과로 QA 를 건너뛰는 분기는 없으므로, 그 이유가 실제로 무엇을 막는지(예: Gate 가
죽었을 때 부수효과를 피하는가)는 코드에 드러나 있지 않다.

실측(2026-09-10, 한 백엔드 서비스 레포): 전체 29m25 가 `code-reviewer 9m07 → qa-runner 9m44 →
qa-reviewer 10m30` 직렬 체인 그대로였다. `qa-runner` 시작이 `code-reviewer` 종료 **2초 뒤**다.
배리어만 없애면 `qa-runner → qa-reviewer` 20m14 가 되고 code-reviewer 는 그 안에 들어간다.

→ QA 체인을 병렬 배치와 **함께** 띄운다. `qa-runner → qa-reviewer` 의존만 유지하면 된다. 먼저 위 주석의
"Gate 뒤" 가 지키려는 것을 확인해 적는다 — 그것이 있으면 이 항목은 그 비용과 맞바꾸는 결정이다.
`qa-reviewer` 를 둘로 쪼개는 것(소스 감사 / 러너 심사)은 별건 — 심사 맥락이 갈릴 위험이 있다.

이관: 2026-11-26 오버레이 백로그에서.

### 문구 회귀 가드가 `_deny` 11곳 중 1곳만 고정한다
`skills/preflight/meta-test/engine.sh` · 「verify 거부 문구가 무엇을 하라고 말하는가」

제목의 11곳은 오버레이 시절 셈이다. 거부 문구가 사유를 예측하지 않는지 보는 단언("거부 문구가 사유를 예측하지 않는다")이 '인덱스 트리
불일치' 한 경로의 출력만 검사한다. `receipt.sh` verify 의 `_deny(` 호출은 14곳이라(2026-11-26
`grep -c '_deny(' skills/preflight/receipt.sh` = 15, 정의 한 줄 포함) 나머지 문구에 사유 이름이 돌아와도
안 걸린다. 소스의 `_deny(` 리터럴을 전부 스캔해 사유 이름(no-gate-run·incomplete-lanes·
stale-head·lane-status·vault-unregistered·branch-mismatch·no-classification 등)이 0건인지 보면 집합 전체가 닫힌다.

이관: 2026-11-26 오버레이 백로그에서.

### `verify` 의 lane 완결성 검사는 사유가 안 갈렸다
`skills/preflight/receipt.sh` · `record` 경로는 '전무(no-gate-run)'와 '일부·엉뚱한 lane
(incomplete-lanes + reported)'를 가르지만, 같은 통제인 `verify` 쪽 gap 검사(`분류가 요구한 lane 이
기록에 없다`)는 `missing` 만 남기고 `reported` 도 사유 분리도 없다. 이 분기는 **record 를 우회해 손으로 쓴
영수증**이 오는 자리라 — 정확히 그 검사가 막으려는 경로 — 오히려 구분이 더 필요할 수 있다.

```bash
grep -n 'missing=gap' skills/preflight/receipt.sh
```

이관: 2026-11-26 오버레이 백로그에서.

### 회귀 명령 실행 확인이 오류로 끝난 호출도 센다
`skills/preflight/receipt.sh` 의 `_scan_transcripts` · CONTRACT: suites-run-is-counted · 2026-10-27 커밋 게이트 참고

전사의 명령은 `tool_use` 가 보이는 순간 `cmds` 에 담긴다. 그 호출의 `tool_result` 가 거부·타임아웃·`is_error`
여도 회귀 명령 실행 검사는 "돌렸다" 로 센다 — `is_error` 로 빼는 것은 구조화 출력 후보(`cand`/`rejected`)뿐이다.
우회는 아니다 — 스위트가 실패했으면 test-runner 판정이 FAIL 이어야 하고 그건 lane-status 검사가 막는다.
다만 "실행 사실을 센다" 는 주장보다 검사가 약하다.

→ 닫는 방법: 구조화 출력이 쓰는 `cand`/`rejected` 와 같이 명령을 `tool_use_id` 로 들고 있다가,
`is_error` 인 결과의 명령을 뺀다.
**먼저 셀 것**: test-runner 전사에서 스위트 호출이 `is_error` 로 끝난 경우가 실제로 있는가.

이관: 2026-11-26 오버레이 백로그에서.

### `all` 로 강제된 test-runner 는 `tscOnly`·`eslintConfig` 를 받지 않는다
`skills/preflight/classify.sh` · mode=all 강제 선택 블록 · 2026-10-29 커밋 게이트 참고

`tscOnly`·`eslintConfig` 는 코드 변경 경로와 회귀 스위트 경로에서만 채워진다. 코드 변경 없이 `all` 로
돌려 test-runner 가 강제로 붙으면 meta 에 `forcedBy`·관례 범위만 있고 이 둘이 없다 — lane 은 jest 를 돌릴지,
린트 설정이 있는지를 스스로 찾는다.

재현 (2026-11-26 엔진에서 확인): `package.json`·`src/*.ts`·`src/*.test.ts` 가 있는 레포에서 README 만 바꿔 스테이징하고
`classify.sh <repo> all | python3 -c 'import json,sys; print(json.load(sys.stdin)["laneMeta"]["test-runner"])'`
→ `{'forcedBy': 'mode=all (원래 사유: no-code-change)', 'conventionScope': …}` — 두 키가 없다.

→ 닫는 방법: 관례 범위처럼 선택이 끝난 뒤 한 곳에서 test-runner 기본 meta 를 채운다.
**먼저 셀 것**: `all` 모드 기록에서 test-runner 가 jest·린트를 잘못 돌리거나 건너뛴 전사가 있는가 —
`all` 은 드물게 쓰여 영향이 없을 수 있다.

이관: 2026-11-26 오버레이 백로그에서.

### PR 본문의 게이트 노출 판정이 실행마다 갈린다
`agents/pr-quality.md` § 개인 게이트 노출 금지 · 2026-11-06

규칙은 lane 이름을 본문에 쓰면 위반이라고 못박는다. 그런데 lane 이름이 11번 든 본문이 통과하고
같은 부류의 다른 본문은 막혔다. 결정론 검사가 아니라 lane 의 판단(어휘 `gate-exposure`)에 맡겨져 있어서다 —
`pr-format-check.sh` 에는 이 어휘 검사가 없다. 오버레이 시절 머지된 PR 52건 중 13건 본문에 lane 이름·`영수증`
같은 표현이 남아 있었다(2026-11-06 집계, 재확인 안 함).

재현:

```bash
gh pr list -R <레포> --state merged --limit 200 --json number,body \
  -q '.[] | select(.body|test("secret-scanner|vault-linter|pr-quality|test-runner|qa-runner|qa-reviewer|게이트 통과|게이트 라운드|영수증")) | .number'
```

→ 닫는 방법: 금지 어휘를 `pr-format-check.sh` 의 결정론 규칙으로 옮긴다. 어휘 정본은 `classify.sh` 의
lane 목록에서 파생시킨다(손으로 적으면 갈린다). `eval/fixtures/body-gate-terms.sh` 가 이 판정의 고정 입력이다.
**먼저 셀 것**: 걸린 본문이 게이트 자신을 고치는 PR 에 몰려 있는지 — 몰려 있으면 "변경 대상이 lane 정의일 때" 의
표기 방법을 규칙에 같이 적어야 한다.

이관: 2026-11-26 오버레이 백로그에서.

### 주석 하나가 고치기 전 형태를 설명한다
`skills/preflight/meta-test/engine.sh` · 입력 생성 실패 픽스처 위 · 2026-11-09

`옛 형태(…)는 이것을 allow 로 통과시켰다` 는 변경 경위다. 이 테스트가 막는 위험을 현재형으로
("출력 유무 판정은 입력 생성 실패를 allow 로 본다") 적으면 된다.

```bash
grep -n '옛 형태' skills/preflight/meta-test/engine.sh
```

이관: 2026-11-26 오버레이 백로그에서.

### 짝 가드의 자기 줄 표식이 실제 프로브도 뺄 수 있다
`skills/preflight/meta-test/engine.sh` · `_pypairs` · 2026-11-09

python stderr 짝 가드는 패턴을 리터럴로 품은 줄(가드 자신·자기시험)을 `# pair-guard-self` 표식으로 빼고 센다.
표식은 줄 전체를 빼므로, 나중에 이 표식이 덮어쓰기(`2>`)를 하는 실제 프로브 줄에 붙으면 가드가 그 줄을 못 본다.
지금 표식이 붙은 실제 프로브는 자기시험 한 줄이고 짝이 맞다.

```bash
grep -n 'pair-guard-self' skills/preflight/meta-test/*.sh   # 2026-11-26: 6줄
```

→ 닫는 방법: 표식을 패턴을 문자열로만 품은 줄로 한정하고, 표식 줄 중 실제 `| python3` 실행이 있는 줄은 `2>>` 를
따로 단언한다. **먼저 셀 것**: 표식 줄 수가 늘어나는가 — 지금 6줄이면 손으로 보는 편이 싸다.

이관: 2026-11-26 오버레이 백로그에서.

### 스냅숏 정리가 실패해도 아무도 모른다
`skills/preflight/preflight.js` · `cleanupSnapshots` · 2026-11-10 PR 게이트 참고

정리는 에이전트 호출이고 `.catch(() => null)` 로 결과를 버린다. 정리 에이전트가 죽으면 원본 레포의
`.git/worktrees/pf-snap.*` 등록과 `$TMPDIR` 디렉터리가 남고, `snapshot.sh` 는 의도적으로 prune 하지 않아 쌓인다.
생성 쪽도 같다 — `snapshot.sh create` 가 돈 뒤 결과가 유실되면 그 경로는 정리 대상에 들어가지 않는다.
2026-11-11 커밋 게이트 한 번이 API 연결 오류로 정리 단계에서 죽어 스냅숏 하나를 남겼다.

```bash
git -C <레포> worktree list --porcelain | grep -c pf-snap
ls -d "$TMPDIR"/pf-snap.* | wc -l      # 2026-11-26 한 개발 머신: 67 (실행 중인 다른 세션 것과 구별하지 않은 수)
```

→ 닫는 방법: 정리 뒤 `git worktree list --porcelain` 으로 만든 경로가 사라졌는지 결정론으로 대조해 로그에 남긴다.
**먼저 셀 것**: 게이트 실행 수 대비 남은 `pf-snap` 등록 수 — 다른 세션이 돌고 있는 스냅숏과 구별하려면 생성 시각과 트리를 같이 본다.

이관: 2026-11-26 오버레이 백로그에서.

### 변이 실행이 meta-test 픽스처의 스냅숏을 남긴다
`skills/preflight/meta-test/engine.sh` · `sn3` 픽스처 · 2026-11-10

변이 하네스가 meta-test 를 변이마다 돌리면, 정리 경로를 망가뜨린 변이가 픽스처 레포 `sn3` 의 스냅숏을
`$TMPDIR` 에 남긴다. 픽스처 레포는 지워지므로 등록은 사라지고 디렉터리만 남는다. 오버레이 시절 두 번의
변이 실행 뒤 3개·21개를 지웠다.

```bash
for d in "$TMPDIR"/pf-snap.*; do sed -n 's#gitdir: ##p' "$d/.git"; done | grep -c '/sn3/'   # 2026-11-26: 0
```

→ 닫는 방법: meta-test 가 시작할 때 `PF_SNAP_ROOT` 같은 자기 전용 상위 디렉터리를 정하고 종료 trap 에서 통째로 지운다.
**먼저 셀 것**: 변이 실행 한 번이 남기는 수 — 실제 게이트 실행이 남긴 것과 섞이지 않는지.

이관: 2026-11-26 오버레이 백로그에서.

### `classificationId` 주석이 하지 않는 대조를 말한다
`skills/preflight/classify.sh` · `classificationId` 필드 위 주석 · 2026-11-10 PR 게이트 참고

주석은 "record 가 이 값을 다시 계산해 대조한다" 고 한다. `receipt.sh` 는 이 값을 영수증과 로그에 옮겨 적기만 한다.
결속은 `indexTree`·`branch`·`head` 대조가 한다.

```bash
grep -n '다시 계산해 대조' skills/preflight/classify.sh
grep -n "classificationId" skills/preflight/receipt.sh
```

→ 닫는 방법: 주석을 "식별용 표지 — 대조하지 않는다" 로 고친다.

이관: 2026-11-26 오버레이 백로그에서.

### 기준선 수집 실패 안내가 lane 에게 스냅숏을 직접 만들라고 한다
`skills/preflight/preflight.js` · test-runner 기준선 폴백 · 2026-11-10 PR 게이트 참고

기준선 수집이 실패하면 test-runner 프롬프트가 "merge-base 기준선을 네가 직접 잡거나" 라고 지시한다.
스냅숏의 생성은 결정론 코드가 하고 lane 은 받은 경로만 쓴다는 원칙과 어긋난다.

```bash
grep -n '네가 직접 잡거나' skills/preflight/preflight.js
```

→ 닫는 방법: 폴백에서 회귀 판정을 하지 말고 "기준선 없음 — 새 실패와 기존 실패를 가르지 않았다" 를 보고하게 한다.
**먼저 셀 것**: 기준선 수집 실패가 실제로 난 실행 수.

이관: 2026-11-26 오버레이 백로그에서.

### 이 레포의 QA 항목은 기록으로 닫을 수 없다
`skills/preflight/receipt.sh` · `qa-not-executed` · 2026-11-10

QA 기록은 qa-runner 의 실행 명령에 URL 이 있어야 남는다. 배포 대상이 없는 레포(이 엔진 레포 포함)는 계획의
`how: qa` 항목을 픽스처 레포의 실제 게이트 라운드로 확인해도 기록이 안 되고, 추적에서 MISSING 으로 남는다.
오버레이 시절 두 PR 이 그 항목을 사용자 승인으로 넘겼다.

→ 닫는 방법: 계획 항목에 `how: qa` 대신 "실제 게이트 라운드" 같은 별도 검증 종류를 두고, 그 증거(워크플로 전사)를 기록에 묶는다.
**먼저 셀 것**: 배포 없는 레포의 계획에서 `how: qa` 항목이 승인으로 넘어간 수.

이관: 2026-11-26 오버레이 백로그에서.

### 회귀 명령 실행 판정이 `nohup` 접두를 모른다
`skills/preflight/receipt.sh` · `_CMD_POS` · 2026-11-11

명령 자리 판정은 변수 대입·`timeout`·`env`·`nice`·`time` 접두만 넘긴다. test-runner 가
`nohup bash …/meta-test-isolated.sh` 로 돌리면 스위트를 실행했는데도 실행 안 함으로 판정된다.

```bash
grep -n '_CMD_POS = ' skills/preflight/receipt.sh
```

→ 닫는 방법: 접두 목록에 `nohup` 을 넣고 meta-test 에 그 형태의 단언을 더한다.
**먼저 셀 것**: `suite-not-run` 거부 중 전사에 `nohup` 이 있던 수.

이관: 2026-11-26 오버레이 백로그에서.

### 워크플로를 재개하면 지워진 스냅숏 경로를 넘긴다
`skills/preflight/preflight.js` · 스냅숏 생성 단계 · 2026-11-11

Workflow 재개는 바뀌지 않은 에이전트 호출을 캐시로 돌려준다. 스냅숏 생성도 에이전트 호출이라 재개하면 이전 실행의
경로가 그대로 나오는데, 그 디렉터리는 이전 실행의 정리 단계가 이미 지웠다. 생성 직후 대조는 받은 경로의 **모양**과
트리 id 만 보고 존재는 보지 않으므로 lane 이 없는 경로를 받는다.

→ 닫는 방법: 생성 직후 결정론 대조(경로 존재·트리 id)를 캐시와 무관하게 다시 하거나, 생성 프롬프트에 실행마다 다른 값을 넣는다.
**먼저 셀 것**: 재개한 게이트 실행 수 — 드물면 "재개하지 말고 다시 돌린다" 를 SKILL 에 적는 편이 싸다.

이관: 2026-11-26 오버레이 백로그에서.

### 옛 서술 단언의 주석이 문구 개수를 틀리게 적는다
`skills/preflight/meta-test/engine.sh` · R14 (P3) 단언 위 주석 · 2026-11-11

주석은 "이 다섯 문구" 라고 하지만 아래 루프의 패턴은 12개다.

```bash
grep -n '이 다섯 문구' skills/preflight/meta-test/engine.sh
```

→ 닫는 방법: 개수를 빼고 "아래 문구들" 로 적는다.

이관: 2026-11-26 오버레이 백로그에서.

### 생성기가 README 를 비운 뒤 쓴다 — 중간 실패 시 복구원이 없다
`make-harness-view.sh` 의 README 쓰기 · 2026-11-12

`cat "$TMP" > README.md` 는 리다이렉션이 열리는 순간 README 를 0바이트로 만든다. 쓰기가 중간에
끊기면(디스크 가득·인터럽트) 생성 결과도 원본도 아닌 잘린 README 가 남고, EXIT trap 이
`$TMP` 를 지우므로 그 시점에 복구원이 없다.

`mv` 를 피한 이유는 코드 주석대로 맞다 — `mktemp` 는 0600 이라 `mv` 하면 README 의 권한이 바뀐다.
다만 그것이 **권한 보존을 원자성과 바꾼 선택**이라는 점은 주석에 적혀 있지 않다.

```bash
grep -nF 'cat "$TMP" > README.md' make-harness-view.sh   # 쓰기 전에 비운다
grep -nF "trap 'rm -f" make-harness-view.sh              # 실패 시 TMP 도 사라진다
```

`-F` 가 필요하다: macOS 의 BSD grep 은 `$` 를 패턴 중간에서도 끝 앵커로 취급하므로, `$TMP` 가 든
BRE 패턴이 같은 줄을 찾지 못한다.

→ 닫는 방법: 권한을 임시 파일에 먼저 옮기고 원자적으로 교체한다 —
`chmod "$(stat -f %Lp README.md)" "$TMP" && mv "$TMP" README.md` (trap 의 `rm -f` 는 mv 뒤 TMP
부재를 그대로 허용한다. `stat -f` 는 BSD 형식이라 Linux 는 `stat -c %a`). **먼저 셀 것**: 이 생성기가 사람이
보지 않는 자리에서 도는 횟수. 사람이 돌리는 동안에는 `git checkout -- README.md` 로 즉시 되돌아오므로,
자동화에 붙기 전까지 창이 열리지 않는다.

이관: 2026-11-26 오버레이 백로그에서.

### 비결정론 가드가 설치본을 보고, 꼬리주석·공백 변형에 샌다
`skills/preflight/meta-test/engine.sh` 의 R16 가드 · 2026-11-12

가드는 커밋될 파일이 아니라 `$_PJR`(`$HOME/.claude/skills/preflight/preflight.js`)을 본다. 설치본이
이 체크아웃으로의 심링크면 스냅숏과 같지만, 설치본과 커밋 내용이 갈리는 환경(클라우드·CI·복사 설치)에서는
금지 호출이 든 커밋을 통과시킨다.

패턴은 `noccE`(→ `_nocode`)로 세므로 **줄 전체가 주석인 줄만** 걸러 꼬리주석의 호출은 세어진다(과탐 —
fail-closed). 제목의 공백 변형 갈래는 닫혔다 — 괄호 안 공백(`new Date( )`)은 지금 패턴 `new Date\([[:space:]]*\)` 가 잡는다(2026-11-26 확인).

```bash
grep -n '_PJR="\|noccE "\$_PJR"' skills/preflight/meta-test/engine.sh
```

→ 닫는 방법: 가드 대상을 스냅숏 안의 레포 상대경로로 바꾸고, 꼬리주석까지 제외하려면 호출 앞에 `//` 가
오는지를 본다. **먼저 셀 것**: 설치본과 커밋 내용이 갈리는 실행이 실제로 있는지 — 심링크 설치만 쓰면 첫
갈래는 발화하지 않는다.

이관: 2026-11-26 오버레이 백로그에서.

### 같은 사실이 세 곳에 적혀 있다
`skills/preflight/preflight.js` 의 `_rmNonce` 주석 블록 · 2026-11-12

"런타임이 비결정 호출을 금지한다" 가 그 블록 안에서 두 번, `meta-test/engine.sh` 의 가드 주석에서 세
번째로 적힌다. 경위·디버깅 과정은 없고 나머지는 되돌림 방지라 남길 것이지만, 재진술 한 문장은
블록을 늘리기만 한다.

```bash
$ awk '/^\/\/ 이 실행의 등록 레포 스냅숏/,/^const _rmNonce/' skills/preflight/preflight.js | grep -c '런타임'
2
$ grep -c '워크플로 런타임은 비결정론 호출을' skills/preflight/meta-test/engine.sh
1
```

→ 닫는 방법: 체크섬이 결정론이라는 재진술 문장을 지운다 — 바로 위의 "스크립트가 지어낼 수는
없다 — 런타임이 금지한다" 가 이미 설명한다. **먼저 셀 것**: 블록을 줄여야 할 만큼 읽기가
나빠졌는지 — 지금은 한 문장이고, 같은 부류가 더 쌓이면 그때 함께 손본다.

이관: 2026-11-26 오버레이 백로그에서.

### 생성 블록의 mermaid 템플릿이 호출자를 주장한다
`make-harness-view.sh` 의 계획 고리 다이어그램 · 2026-11-12

산문에서는 호출자 단정을 없앴지만(`classify.sh` 의 lane 집합에 없다는 사실까지만 적는다),
다이어그램 템플릿은 `/plan --> change-planner --> plan-reviewer` 를 그대로 담는다. 그 둘은 지금도
참이다 — `skills/plan/SKILL.md` 가 실제로 둘을 `Agent(subagent_type: …)` 로 부른다. 문제는 lane 밖
에이전트가 늘어도 그림이 드리프트를 드러내지 않는다는 점이다. 2026-11-26 README 산문은 lane 밖 4개
(`change-planner`·`claim-remeasurer`·`implementer`·`plan-reviewer`)를 적는데 그림은 둘만 그린다.

```bash
grep -c 'change-planner' make-harness-view.sh                        # 1 — 그림 한 줄
grep -n 'lane 집합에 없는 것' README.md
```

→ 닫는 방법: 그림 근처에 lane 밖 에이전트 개수를 생성해 두면(표가 이미 그러듯) 새 에이전트가
붙을 때 diff 에 드러난다. 또는 그 두 노드를 그림에서 빼고 산문에만 맡긴다. **먼저 셀 것**: lane
밖 에이전트가 앞으로 또 느는지.

이관: 2026-11-26 오버레이 백로그에서.

### `exit 2` 계약과 인자 검사가 어긋난다
`make-harness-view.sh` 의 인자 파싱 · 2026-11-12

헤더가 `2 잘못된 인자` 를 계약으로 적었는데 검사는 `case "${1:-}"` 로 `$1` 만 본다. 두 번째 인자부터는
보지 않으므로 오타가 조용히 무시되고 명령이 그대로 수행된다.

```bash
$ bash make-harness-view.sh --check --bogus >/dev/null 2>&1; echo $?
4        # 2026-11-26 엔진 워크트리: 분류 산출물이 없어 4. 산출물이 있으면 --check 를 그대로 수행한다. 어느 쪽도 2 가 아니다
$ bash make-harness-view.sh --bogus >/dev/null 2>&1; echo $?
2
```

→ 닫는 방법: `[ $# -le 1 ]` 를 확인하거나 case 를 루프로 돌려 남은 인자가 있으면 같은 메시지로
`exit 2` 를 낸다. **먼저 셀 것**: 이 스크립트를 두 인자 이상으로 부르는 자리가 생기는지 — 지금은
사람이 손으로 칠 때만 걸린다.

이관: 2026-11-26 오버레이 백로그에서.

### `--body-file` 플래그 형식이 두 스크립트에서 다르고, 한쪽은 조용히 버린다
`skills/preflight/classify.sh` 와 `skills/preflight/pr-format-check.sh` · 2026-11-12

같은 이름의 플래그를 한쪽은 등호로, 한쪽은 공백으로 받는다. 그리고 `pr-format-check.sh` 는
모르는 플래그를 `*) shift;;` 로 버리므로, 등호 형식으로 부르면 **본문이 검사되지 않은 채
`body/not-provided` 로 통과한다.** `classify.sh` 가 내부에서 공백 형식으로 올바르게 넘기므로
정상 경로는 무사하지만, 사람이 직접 부를 때 걸린다. `classify.sh` 는 모르는 플래그를 `exit 2` 로
거부하는데, 이쪽은 막혀 있지 않다.

```bash
grep -n -- '--body-file=?\*' skills/preflight/classify.sh
grep -n -- '--body-file)\|\*) shift;;' skills/preflight/pr-format-check.sh
```

→ 닫는 방법: `pr-format-check.sh` 도 등호 형식을 받게 하거나, `*) shift;;` 를 `classify.sh` 처럼
`exit 2` 로 바꾼다. 후자가 이 레포의 기존 판단과 맞는다. **먼저 셀 것**: 사람이 이 검사기를 직접
부르는 빈도 — 게이트를 통해서만 부른다면 정상 경로는 이미 맞다.

이관: 2026-11-26 오버레이 백로그에서.

### 카테고리 판정 중에 `ctx.vault_dir` 를 부르면 이름 오류로 죽는다
`skills/preflight/classify.sh` 의 카테고리 적재 · 2026-11-12

카테고리 규칙의 `match()` 가 받는 `ctx.vault_dir` 는 `_vault_dir()` 이고, 그 함수는 `_rule()` 을 부른다.
`_rule()` 은 `match()` 루프보다 뒤에 정의되므로, 어느 카테고리가 소속 판정 안에서 `vault_dir` 를 부르면
`NameError` 가 나고 분류는 "적재 실패"(exit 3)라는 엉뚱한 사유로 끝난다. 엔진의 두 카테고리(`generic`·`shell-tool`)와
지금 알려진 오버레이 카테고리의 `match()` 는 `vault_dir` 를 부르지 않아 발화하지 않는다.

```bash
$ grep -n 'def _vault_dir\|_mod.match(\|def _rule' skills/preflight/classify.sh
248:def _vault_dir():
272:        _ev = _mod.match(types.SimpleNamespace(**{**vars(ctx), 'catdir': _d}))
407:def _rule(name):
```

→ 닫는 방법: `_rule()` 을 `match()` 루프 앞으로 옮기거나, 카테고리 계약 주석에 "`match()` 는 `vault_dir`
를 부르지 않는다" 를 적는다. **먼저 셀 것**: 소속 판정에 vault 위치가 필요한 카테고리가 생기는지.

이관: 2026-11-26 오버레이 백로그에서.

### 분류기가 자기 회귀 스위트를 루트 파일 변경에서는 강제하지 않는다
`skills/preflight/categories/shell-tool/rules.py` 의 `suites()`

트리거가 경로 접두 셋뿐이다:

```python
trig = [f for f in changed if f.startswith(('hooks/', 'skills/', 'agents/'))]
```

루트의 `make-harness-view.sh`·`install.sh` 는 **스위트가 단언하는 대상인데 트리거에 없다**
(`meta-test/engine.sh`·`category-hook.sh`·`edit-guard.sh` 가 이 이름을 읽는다). 검사 대상과 검사 발동 조건이
어긋나 있다.

**실측 2026-11-26** — 엔진 워크트리를 `--local` 클론한 스크래치에서 한 줄씩 덧붙여 스테이징하고 커밋 모드로 분류:

| 스테이징한 것 | suites | test-runner |
|---|---|---|
| `make-harness-view.sh` 만 | **(없음)** | 미선택(`no-testable-file-change`) |
| 위에 `install.sh` 추가 | **(없음)** | 미선택(`no-testable-file-change`) |
| 위에 `skills/preflight/DECISIONS.md` 추가 | `['meta-test']` | 선택 |

세 번째 줄이 양성 대조다 — 트리거가 살아 있는 것은 확인됐고, 루트 파일에서만 죽는다.

```bash
$ git clone -q --local <레포> /tmp/p && cd /tmp/p
$ echo '# x' >> make-harness-view.sh && git add make-harness-view.sh
$ bash skills/preflight/classify.sh . commit >/dev/null 2>&1
$ python3 -c "import json; d=json.load(open('.git/claude-preflight.classify.json')); print([x['name'] for x in ((d.get('laneMeta') or {}).get('test-runner') or {}).get('suites') or []])"
[]
```

**측정 함정 둘**: suites 는 `laneMeta.test-runner.suites` 다 — `meta.test-runner` 로 읽으면 늘 빈 목록이 나와
**양성 대조까지 음성으로 보인다.** 그리고 `: >> 파일` 은 내용을 바꾸지 않아 스테이징할 변경이 생기지 않는다 —
실제로 한 줄을 덧붙여야 한다.

**실제로 새어 나갔다 (오버레이 시절).** README·`make-harness-view.sh` 만 바꾼 커밋이 하네스 뷰 단언 하나를 깼는데
커밋 게이트도 PR 게이트도 스위트를 돌리지 않았다. 잡은 것은 리뷰 lane 의 읽기다 — 사람이 읽어서 걸린 것을
스위트가 걸렀다고 셈하면 안 된다.

→ 닫는 방법: `trig` 에 루트 스크립트를 넣거나, 방향을 뒤집어 **문서·백로그만 바뀐 라운드를 빼고
나머지를 강제**한다. 후자가 이 레포의 기존 판단(열거는 늘어나는 쪽을 쫓는다)과 맞는다.
**먼저 셀 것**: 루트 파일만 바뀌는 라운드가 얼마나 되는지 — meta-test 는 한 번에 수 분이고,
백로그·README 만 고치는 라운드마다 붙으면 비용이 크다.

이관: 2026-11-26 오버레이 백로그에서.

### 재측정의 모집단 셈 오차가 측정 불가로 바뀐다
`skills/preflight/preflight.js` · `remeasureJudge` 의 모집단 대조 · 2026-11-16

등록 레포 측정에서 lane 이 레포를 빠짐없이 셌는데 모집단 N 을 틀리게 내면, 코드는 그 N 이 주장의
비율 전체 자리와 다르다는 것만 보고 "코퍼스 일부가 빠진 것과 구별되지 않는다" 로 측정 불가를 낸다.
주장이 틀린 원 사건 위상에서 불일치 대신 측정 불가가 나온다. 실측 결과와 재현 명령은 오버레이 시절 결정 기록
(2026-11-16 「여러 스냅숏 적용 뒤 실측」)에 있고 엔진 `DECISIONS.md` 에는 옮겨지지 않았다. 셈이 틀린 이유는
스냅숏이 지워져 확인하지 못했다.

```bash
grep -n '코퍼스 일부가 빠진 것과 구별되지 않는다' skills/preflight/preflight.js
```

→ 닫는 방법: 먼저 셈이 틀리는 이유를 확인한다(스냅숏을 남기는 실행으로 lane 이 읽은 경로를 본다).
스냅숏 밖을 읽은 것이면 lane 쪽 지시를, 셈 자체가 흔들리는 것이면 코드가 스냅숏별 파일 수를 따로 세어
lane 의 N 과 대조하는 방법을 검토한다. 후자는 lane 에 주지 않는 값이어야 독립성이 유지된다.
**먼저 셀 것**: 같은 픽스처를 더 돌렸을 때 lane 의 N 이 실제 값과 다른 실행의 비율.

이관: 2026-11-26 오버레이 백로그에서.

### 등록 레포 이름이 `target` 이면 대상 레포와 구별되지 않는다
`skills/preflight/preflight.js` · `remeasureOffered`·`remeasureJudge` · 2026-11-16

코드는 대상 레포 스냅숏에 이름 `target` 을 붙이고, 등록 레포 측정인지를 "센 이름 중 `target` 이 아닌 것이
있는가" 로 가른다. 등록 목록(`config.json` 의 `remeasureRepos`, `PF_REMEASURE_REPOS`)은 이름을 검사하지
않으므로 등록 레포 이름이 `target` 이면 그 레포만 센 측정은 대상 레포 측정으로 취급된다. excluded 확인과
모집단 대조가 건너뛰어진다.

```bash
grep -n "name: 'target'\|n !== 'target'" skills/preflight/preflight.js
```

→ 닫는 방법: 등록 목록을 읽을 때 `target` 이름을 거부하거나, 대상 레포 표식을 이름이 아닌 별도 필드로 둔다.
meta-test 에 그 이름의 등록 단언을 더한다.
**먼저 셀 것**: 없음 — 입력 검사 하나로 닫히는 크기다.

이관: 2026-11-26 오버레이 백로그에서.

### 스냅숏 도구 출력에서 빠진 등록 레포는 사용 불가로도 잡히지 않는다
`skills/preflight/preflight.js` · `remeasureSnapshots` · 2026-11-16

`remeasureSnapshots` 는 `claim-remeasure.sh snapshot` 출력의 `repos` 중 등록 목록에 있는 이름만 남긴다.
등록 목록에 있는데 출력에 없는 레포는 `rmRepos` 에 들어가지 않는다. 그 레포는 lane 프롬프트의 코퍼스
목록에도, `remeasureJudge` 의 사용 불가 목록에도 없다. 그래서 그 레포를 `corpus.excluded` 에 적으라는
확인도 걸리지 않는다. 도구가 정상이면 등록 레포마다 한 줄을 내므로 지금 경로로는 생기지 않는다.

```bash
grep -n 'rmRepos = got.repos.filter' skills/preflight/preflight.js
```

→ 닫는 방법: 출력에 없는 등록 이름을 `unusable`(사유: 스냅숏 도구 출력에 없다)로 채운다. meta-test 에
출력에서 한 레포를 뺀 단언을 더한다.
**먼저 셀 것**: 없음 — 빠진 경우를 메우는 한 줄 수정이다.

이관: 2026-11-26 오버레이 백로그에서.

### 하네스 뷰 판정을 건너뛴 사실이 기록에 남지 않는다
`skills/preflight/receipt.sh` · `harness-view-stale` 의 건너뜀 경로 · 2026-11-16

생성기가 없거나 인덱스와 다르거나 인덱스 README 에 마커가 없으면 판정하지 않고 사유를 화면에 찍는다
(`참고 — 하네스 뷰를 판정하지 않았다`). 그 사유는 `_log('record', 'recorded', …)` 인자에 들어가지 않는다.
그래서 영수증과 관측 로그만으로는 판정한 기록과 건너뛴 기록이 구별되지 않고, **"이 검사가 꺼진 채 몇 번
통과했나"를 나중에 셀 수 없다.** 조용히 꺼진 검사는 이 검사가 애초에 막으려던 실패 모드다.

```bash
grep -n '_hv_skip' skills/preflight/receipt.sh   # 설정과 화면 출력만 — _log 인자에는 없다
```

→ 닫는 방법: `record`/`recorded` 이벤트에 건너뜀 사유 필드를 더하고, 카테고리 스위트에 그 로그 줄 단언을 붙인다.
**먼저 셀 것**: 없음 — 필드 하나와 단언 하나의 크기다. 다만 이것을 닫아야 아래 항목의 지표를 셀 수 있다.

이관: 2026-11-26 오버레이 백로그에서.

### 하네스 뷰 거부 안내의 `git add -p` 는 TTY 를 요구한다
`skills/preflight/receipt.sh` · `harness-view-stale` 거부 메시지 · 2026-11-16

거부 안내는 `--write-from-index` 로 재생성한 뒤 `git add -p README.md` 로 **마커 블록만** 담으라고 말하고,
README 를 통째로 add 하지 말라고 덧붙인다. `-p` 는 대화형이라 TTY 없는 실행 경로에서는 쓸 수 없다 —
에이전트가 이 거부에 걸리면 안내를 그대로 따를 수 없다. README 에 다른 미스테이징 수정이 없으면
`git add README.md` 로 끝나지만 안내는 그 경우를 말하지 않는다.

```bash
grep -n 'git add -p README.md' skills/preflight/receipt.sh
```

→ 닫는 방법: TTY 없는 경로를 안내에 함께 적는다. 다른 미스테이징 수정이 없을 때의 `git add README.md` 를 먼저
두고, 있을 때 블록만 담는 비대화형 수단(블록 범위 패치를 `git apply --cached` 로 넣는 식)이 **실제로 되는지
확인한 뒤** 적는다 — 통하지 않는 복구 수단을 안내해 차단 판정을 받은 적이 있다.
**먼저 셀 것**: `reason='harness-view-stale'` 로 거부된 횟수(관측 로그에 이미 남는다)와, 그중 README 에 다른
미스테이징 수정이 함께 있어 통째 add 가 불가능했던 비율 — 후자는 지금 기록되지 않는다.

이관: 2026-11-26 오버레이 백로그에서.

### 인덱스에서 풀어 올 입력 목록이 두 곳에 있다
`make-harness-view.sh` · 인덱스 모드의 pathspec 과 임베드 python · 2026-11-16

인덱스 모드는 `ls-files -- agents settings.hooks.json` 으로 입력을 임시 폴더에 풀고, 생성 python 은
`(root / "agents")` 와 `root / "settings.hooks.json"` 을 따로 읽는다. **입력이 늘 때 한쪽만 고치면** python 이
읽는 입력이 풀려 있지 않은데 생성은 성공한다 — `settings.hooks.json` 은 `hj.exists()` 로 조용히 건너뛰므로
훅 행이 빠진 블록이 나온다. 인덱스에는 그 파일이 있으니 README 블록과 달라 거부가 나고, 안내대로
`--write-from-index` 로 재생성하면 **빠진 블록이 README 에 써지고 다음 실행은 통과한다.** 거부가 결함을
커밋으로 세탁한다. `agents/` 부재만 `exit 4` 로 잡는다. 지금은 두 목록이 일치하므로 생기지 않는다.

```bash
grep -n 'ls-files -z -- agents settings.hooks.json' make-harness-view.sh      # 풀어 오는 목록
grep -n 'root / "agents"\|root / "settings.hooks.json"' make-harness-view.sh  # 읽는 목록
grep -n 'hj.exists()' make-harness-view.sh                                    # 없으면 조용히 빈 표
```

→ 닫는 방법: 목록을 한 곳에 두거나(pathspec 을 python 이 읽는 경로에서 파생), 인덱스 모드에서 입력이 하나라도
빠지면 `agents/` 가드와 같은 방식으로 `exit 4` 로 끝낸다. 후자가 작다.
**먼저 셀 것**: 없음 — 가드 한 줄이다.

이관: 2026-11-26 오버레이 백로그에서.

### 커밋 판정의 남은 갈래 — 메시지 글·문장 범위·문자열 실행 명령
`hooks/preflight-gate.sh` `commit_verdict` · 2026-11-26 (`commit-multiple`·`commit-git-env`·`commit-nested-shell` 도입 리뷰에서)

세 거부를 넣은 뒤에도 남는 갈래다. 앞의 둘은 과탐(fail-closed), 셋째는 그 전부터 있던 미탐, 넷째는 새 판정의 빈틈이다.
히어독 본문을 따로 빼지 않으므로(DECISIONS.md 2026-11-26) 가짜 히어독으로 개수를 피하는 갈래와, 본문 글이 대상 레포를 정하는 갈래
(`cat > f <<'X'` 본문의 `git -C <B> commit` 뒤 진짜 커밋 — 이제 `commit-multiple`)는 없다.

1. **메시지 글**: 커밋 메시지(여러 줄 `-m "…`, `-m "$(cat <<'X'`, `-F - <<'X'` 히어독) 본문에 `git commit`·`bash -c 'git commit'`·
   `eval git commit` 글이 있으면 둘째 호출·중첩 커밋으로 읽혀 `commit-multiple`·`commit-nested-shell` 이다(과탐, 의도된 대가). 두 거부 문구가
   메시지를 파일로 써서 `-F <파일>` 로 넘기라고 안내한다.
2. **문장 범위**: 앞 문장의 일회성 할당 `GIT_PAGER=cat git log; git commit …` 도 `commit-git-env` 로 거부한다(과탐, fail-closed). 할당을 그 문장에만
   묶는 수정이 후보다.
3. **문자열 실행 명령**: 문자열을 명령으로 실행하는 것 중 셸 단어 `-c`·`eval` 밖 — `su -c`·`script -c`·`$SHELL -c`·`python3 -c 'os.system(…)'`·
   `ssh host '…'` — 은 판정하지 않는다. 그 전부터 있던 갈래다.
4. **중첩 셸 인자 읽기**: 새 `commit-nested-shell` 판정이 놓치는 형태 둘 — 회귀는 아니다(직전 훅은 중첩 셸 커밋을 모두 놓쳤다).
   `bash 2>&1 -c '<커밋>'`·`eval 2>&1 '<커밋>'` 은 `is_sep` 가 `&` 든 리다이렉트 토큰(`>&`·`&>`)을 명령 끝으로 읽어 인자 탐색이 멈춘다(폴백
   `NEST_RX` 도 같다). `bash -c $'<커밋>'` 은 shlex 가 ANSI-C 따옴표를 몰라 `$git …` 토큰이 된다. 둘 다 훅이 판정 없이 통과시킨다.
   닫는 방법 후보: 리다이렉트 토큰(`>`·`<` 포함)은 구분자로 보지 않고, 셸 단어·`eval` 인자 글은 LOOSE_CALL 로도 한 번 더 본다.

→ 닫는 방법: 실행 형태를 더 열거하지 않고 방향을 바꾸는 것을 검토한다 — **커밋 글이 든 토큰은 무해한 명령의 인자일 때만 받는다**(`echo`·`printf`,
`git commit` 의 `-m`/`-F` 값 등 화이트리스트). 그 밖의 자리에 커밋 글이 있으면 거부한다. 「형태 차단은 열거 방향이 틀렸다」 와 같은 결론이다.
**먼저 셀 것**: 관측 로그의 `commit-multiple`·`commit-git-env`·`commit-nested-shell` 거부 수(머지 뒤 일주일) — 과탐(1·2)이 얼마나 막는지.

2026-11-26.

## 관측 중 — 데이터가 쌓이면 판단한다

### `hook-unavailable` 빈도
`hooks/preflight-gate.sh` · 원인 3종(`receipt-missing`·`receipt-not-executable`·
`receipt-error`)으로 기록 중. 지금은 **막지 않는다** — 하드 차단하면
훅 자신을 고치는 커밋도 막힌다(부트스트랩 경로).

빈도를 보고 정한다: 0에 가까우면 fail-closed 로 조여도 안전하고, `receipt-error` 가 잦으면
그건 조일 문제가 아니라 고칠 문제다.

```bash
grep -n 'pf_hook_log hook-unavailable' hooks/preflight-gate.sh
```

이관: 2026-11-26 오버레이 백로그에서.

### `waived` qa-runner 도 `qa-not-executed` 로 막힌다
사람이 승인해 `waived: true, originalStatus: WARNING` 으로 기록한 qa-runner 도 live==0 이면
`record` 가 거부한다(`receipt.sh` — `ran` 은 SKIPPED·NOT_APPLICABLE 만 뺀다). **fail-closed 는 유지한다** —
요청을 못 보냈으면 waived-PASS 가 아니라 `SKIPPED`/`NOT_APPLICABLE` 이 맞는 기록이고, 승인으로 실행 사실을
만들 수는 없다.

고칠 것은 문구다: 거절문("QA 가 통과로 보고됐는데 라이브 요청이 0건이다")이 그 길을 알려주지 않아 승인자가
막다른 길에 선다. 거절 메시지에 대안 상태를 한 줄 넣고, `CONTRACT: qa-execution-is-counted-not-claimed`
주석에 waived-PASS 도 여기 도달한다는 사실을 적는다.

이관: 2026-11-26 오버레이 백로그에서.

### C: `live>0` 증거가 실제 QA 를 얼마나 대표하는가
**시작 조건**: `recorded ∩ evidence['qa-runner']['live'] > 0` 이 10건 이상.

실측 2026-09-11 (오버레이 시절) — `record/recorded` 210건 중 `evidence.qa-runner` 를 가진 것 1건,
`live` 필드 0건(필드가 그 무렵 오버레이 커밋에서 생겼다). qa-runner 자체가 **210:1 로 dormant** 하다.
발동 빈도를 올리려고 설계를 바꾸지 않는다 — 먼저 이 capability 가 실제로 필요했던 횟수를 센다.

모집단은 `~/.claude/preflight-log.jsonl` 의 `record/recorded` 로 고정한다. 거부된 실행을
넣으면 "게이트를 통과한 증거의 질"이 아니라 "내가 돌린 전부"를 재게 된다.

증거 경로는 `evidence['qa-runner']['live']` — **최상위 `live` 가 아니다.** 경로를 잘못 잡으면 값이 0 인 것과
구분되지 않는 0 이 나온다.

조건이 차면 `live=1` 명령을 샘플링해 QA / 탐색으로 분류한다. 그 결과와 함께
`live` → `urlCommands` 개명도 정한다 — 지금 이름은 "실행됨"을 암시하지만 실제 의미는
"URL 이 실린 명령이 관측됨"이다.

이관: 2026-11-26 오버레이 백로그에서.

### 우회 사유는 내용 주장과 권한 주장으로 갈린다
`PREFLIGHT_SKIP` 의 `reason` 을 한 덩어리로 검증하려 하면 안 된다. 성질이 다른 둘이 섞여 있다.

| 주장 | 예 | 검증 |
|---|---|---|
| **내용** | "package.json 버전 범프만 했다" | 커밋 diff 와 대조 — **기계적으로 가능** |
| **권한** | "사용자가 우회해도 된다고 했다" | 현재 시스템에 증거가 없다 — **불가능** |

실증 2026-09-11, 한 서비스 레포의 우회 커밋: 사유가 "머지 뒤 package.json 버전 범프만 — 사용자 관례,
사용자가 머지·배포를 승인했다" 는 취지였다. 내용 주장은 참이었다(실제 diff 가 `package.json` 한 줄).
권한 주장은 확인할 수 없다 — 인용된 말은 **배포 승인**이지 우회 승인이 아니다. 한 번은 무해하지만 이것이
관용구가 되면 짧은 승인 한 마디가 상시 우회권이 된다.

같은 흐름의 로그(58초):
```
hook   denied    unsafe-command-shape
verify denied    branch-mismatch
hook   bypassed  PREFLIGHT_SKIP
```
**거부 2건 뒤 우회가 발생했다** 까지가 관측이다. 의도는 로그에 없으므로 단정하지 않는다.

앞서 발견한 CI 캠페인 63건은 **내용 주장조차 검증 불가능한** 사유였다(28개 레포에 같은 문장).
두 사례의 차이가 이 항목의 설계 근거다: 먼저 내용 주장만 기계적으로 검증하고, 권한 주장은
"검증되지 않음"으로 **남긴다** — 검증한 것처럼 만들지 않는다.

**먼저 쌓을 것**: 우회 사례. 지금 근거는 2건이다.

이관: 2026-11-26 오버레이 백로그에서.

### `cd` 해석은 정적으로 결정 불가능하다
훅은 명령 텍스트에서 커밋이 날 디렉터리를 추정한다. **어느 `cd` 가 실제로 실행되는가는
텍스트만으로 정해지지 않는다** — `false && cd X ; git commit`, `[ -d X ] && cd X; git commit`
같은 형태가 그렇다. 그 `cd` 가 이기면 **다른 레포의 영수증으로 검증된다**(fail-open).
`skills/preflight/meta-test/engine.sh` 가 이 절을 "알려진 한계" 로 가리키며 현재 동작을 고정한다.

2026-09-14 실측으로 13개 형태를 쟀다. **남은 미탐 목록** — 2026-11-26 엔진 훅의 해석 단계만 떼어 돌려
(아래 「한 명령 안의 커밋 호출은 …」 절의 추출 명령) 네 형태 모두 같은 해석 재료가 나오는 것을 확인했다:

| 형태 | 결과 |
|---|---|
| `(cd X && git commit)` 서브셸 | cwd 로 해석(`CD_DIR` 빈 값) — 커밋은 X 에서 난다 (fail-open) |
| `false && cd X ; git commit` | X 로 해석 — 실행되지 않는 cd (fail-open) |
| `cd X; git commit` | `X;` 로 잡아 unresolvable 거부 (오탐) |
| `cd 'X' && git commit` | `'X'` 로 잡아 unresolvable 거부 (오탐) |

앞의 둘은 **찾지 못해서** cwd 로 떨어지거나 엉뚱한 것을 고르고, 뒤의 둘은 **피연산자를 셸처럼
파싱하지 않아서** 거부된다. 거부 문구가 원인을 `$VAR` 로 지목해 사람을 엉뚱한 데로 보낸다.
줄인 방법은 형태를 열거한 게 아니라 **재료를 좁힌 것**이다 — 경로는 매치된 호출 안의 `-C` 와
그 호출 **앞**의 `cd` 에서만 뽑는다. 형태를 하나씩 막는 방향으로 가면 `--dry-run` 면제가
여섯 번 뚫린 길을 그대로 간다.

**다음 단계는 열거가 아니라 설계 변경이다.** 후보 둘:
- 모호하면 거부한다 — `cd` 후보가 여럿이거나 조건부면 `unresolvable-dir`. 오탐이 늘지만
  fail-closed 다.
- `git -C` 를 요구한다 — `cd … && git commit` 을 아예 막는다. 가장 확실하지만 상용 형태를
  막는 것이라 별도 결정이 필요하다.

**먼저 셀 것**: 위 형태가 실제 로그에 나타나는 빈도. 0에 가까우면 현재 상태로 두고 고정해 둔
메타테스트만 유지한다.

이관: 2026-11-26 오버레이 백로그에서.

### 형태 차단은 **열거 방향이 틀렸다**
`hooks/preflight-gate.sh` 의 같은 명령 안 인덱스 변경 차단(`split_reason`)은 인덱스를 쓰는 하위명령을
열거한다(`add rm mv restore reset stash apply`). 그 집합은 **git 버전마다 늘고**, 빠진 것이 그대로 구멍이 된다.
2026-11-26 엔진 훅의 그 정규식에 대어 본 결과, 미탐 4/4:

```
git update-index --add f && git commit      git cherry-pick X && git commit
git checkout HEAD -- f && git commit        git sparse-checkout set x && git commit
```

동시에 **과탐도 난다** — 이름만 보므로 읽기 전용 형태가 걸린다:
`git stash list`, `git stash show`, `git apply --check` 뒤의 커밋이 차단된다(같은 정규식에 셋 다 일치).

**방향을 뒤집어라.** 읽기 전용 하위명령의 화이트리스트(`log show diff status rev-parse help
grep blame ls-files …`)를 두고 **그 밖의 것이 commit 앞에 오면 차단**한다. 읽기 전용 집합은
작고 안정적이다 — 늘어나는 쪽을 열거하는 것이 지금까지 계속 틀린 이유다.

같은 부류의 경고: 2026-09-14 에 게이트 대상 판정(`git -c k=v commit` 등)을 **받는 쪽으로 넓히려다** 7라운드를
돌고 되돌렸다 — 한 갈래를 막을 때마다 개행·공백형 전역 옵션·히어독 절단·`<<-` 히어독·공백 든 `-C` 경로 같은
새 갈래가 생겼다. 그 구멍은 2026-11-12 에 넓히지 않고 거부하는 쪽(`commit-global-option`·`commit-unparsed`)으로
닫혔다. 형태 차단을 고칠 때는 화이트리스트 전환과 **재료를 토큰 한 벌로 고정**하는 것을 같이, 별도 작업으로 한다.

**먼저 정할 것**: 읽기 전용 화이트리스트에 무엇을 넣을지. 빠지면 과탐(fail-closed)이므로
좁게 시작해서 실제 차단 기록을 보고 넓힌다.

이관: 2026-11-26 오버레이 백로그에서.

### 대상 레포 해석 재료가 아직 정규식이다
커밋 호출은 토큰으로 찾지만(`commit_calls`), 대상 레포를 정하는 재료(`C_DIR`·`CD_DIR`·`SUFFIX`)는
여전히 명령 전체에 건 STRICT 정규식의 **첫 매치**에서 나온다. 두 판정이 다른 호출을 보는 틈은
지금 `-C` 값 대조로만 막는다 — 값이 다르면 `commit-unparsed`. **같은 호출인지는 보지 않는다.**
둘 다 `-C` 가 없으면 값이 같아(빈 값) 대조를 지나고, `CD_DIR` 은 가짜 매치 앞에서 잘린다.

실측 2026-11-17, 2026-11-26 엔진 훅의 해석 단계에서 재현(`C_DIR=''`, `CD_DIR=''` — 여러 커밋 거부(`commit-multiple`)를 넣은 뒤에도 같다.
따옴표 안 글은 호출로 세지 않으므로 커밋 호출은 하나다): 아래 명령은 cwd 레포에 대한
일반 검증으로 넘어간다. 실제 커밋은 `/other` 에서 난다.
```
echo "; git commit "; cd /other; git commit -m x
```
재현 — 훅의 해석 단계만 떼어 돌린다. 지금 훅이 이 명령 자체를 커밋으로 읽어 막지 않게 단어를 나눈다(스크립트 파일로 돌리는 편이 안전하다):
```bash
H=hooks/preflight-gate.sh; T=$(mktemp -d); CM="com""mit"
awk '/^eval "\$\(CMD="\$CMD" python3 -c /{f=1;next} f&&/^. 2>\/dev\/null\)" 2>\/dev\/null \|\| exit 0/{f=0} f' "$H" > "$T/parse.py"
CMD="echo \"; git $CM \"; cd /other; git $CM -m x" python3 "$T/parse.py" | grep -v SUFFIX
```

같은 부류가 한 PR 리뷰에서 세 번 연달아 나왔다(2026-11-17): 전역 옵션 폴백이 앞 호출에 가려짐 →
STRICT 가 메시지 안 글을 잡음 → 값 대조가 같은 호출을 보장하지 못함. 위 「형태 차단은 열거 방향이 틀렸다」 가
경고한 그대로다.

**고칠 것**: 재료를 **토큰 한 벌**에서 낸다. `commit_calls` 가 첫 커밋 호출의 `-C` 값(이미 토큰으로
풀려 있다), 그 호출 앞 토큰 열의 마지막 `cd` 인자, 그 호출 뒤 토큰(형태 차단용)을 함께 돌려주고,
STRICT 정규식은 경로 해석에서 뺀다. 토큰화가 안 되는 줄(여러 줄 따옴표)은 줄들을 이어 붙여 한 번
더 토큰화하고, 그래도 안 되면 거부한다. `cd` 해석의 정적 한계(위 「`cd` 해석은 정적으로 결정
불가능하다」)는 그대로 남는다 — 이 작업은 "다른 호출을 보는" 틈만 닫는다.

**먼저 셀 것**: 토큰화가 안 되는 커밋 명령이 얼마나 되는지 — 그만큼이 새 거부가 된다. 관측
로그의 `commit-unparsed` 거부 수를 머지 뒤 일주일 센다.

이관: 2026-11-26 오버레이 백로그에서.

---

## 닫힘

### 한 명령 안의 커밋 호출은 첫 번째 하나만 판정된다 — 닫힘 (2026-11-26)
훅은 경로 해석 재료(`C_DIR`·`CD_DIR`)를 첫 커밋 호출 하나에서만 냈다. 같은 Bash 호출의 둘째 커밋(`git -C /a commit && git -C /b commit`, 따옴표 친
`"git"`·`'git'`, `cd` 로 갈아탄 둘째 커밋)은 첫 호출의 영수증으로 판정됐다.

닫힘: 넓히지 않고 거부 — `commit_verdict` 가 명령 전체(토큰 판정 줄 + 토큰화 실패 줄 폴백)의 커밋 호출을 세어 2개 이상이면 경로 해석 전에
`commit-multiple` 로 거부하고 "한 Bash 호출에 커밋은 하나만 · 픽스처 스크립트는 파일로" 를 안내한다. 2026-11-01~26 전사 869건 중 해당 26건은 직전 훅에서도
모두 다른 사유로 거부되던 것이다. `skills/preflight/DECISIONS.md` 2026-11-26 「한 호출 안의 여러 커밋·…」, 회귀 `meta-test/engine.sh` 「deny 하는 자리는 전부 기록된다」.

### 환경변수·중첩 셸로 대상 레포를 바꾸는 커밋은 거부되지 않는다 — 닫힘 (2026-11-26)
`GIT_DIR=… git -C <repo> commit` 은 `-C` 레포의 영수증으로 통과하고 커밋은 다른 레포에 들어갔다(`GIT_WORK_TREE`·`GIT_INDEX_FILE`·`GIT_CONFIG_*` 도 같다).
`bash -c '…commit…'`·`eval` 안 커밋은 따옴표 안이라 판정 자체가 없었다.

닫힘: 커밋 앞 `GIT_*=` 할당은 `commit-git-env` 로 거부한다 — 작성자·날짜 변수 6개만 받는 화이트리스트(실사용 4건이 전부 이것). `sh|bash|zsh|dash|ksh` 의
`-c` 인자와 `eval` 인자는 다시 토큰화해(깊이 상한 3) 커밋이 있으면 `commit-nested-shell` 로 거부한다. `su -c`·`script -c` 등은 보지 않는다(한계).
`skills/preflight/DECISIONS.md` 2026-11-26 같은 절, 회귀 `meta-test/engine.sh` 같은 절.

### 프로필 영향도가 커밋 제목 형식에 기댄다 — 닫힘 (2026-11-25)
`profile-measure.sh` 의 수정 커밋 판정 `FIX_RE`(126행)는 제목만 본다 — `fix`/`hotfix`/`revert` conventional 제목과
`Revert "` 만 수정 커밋이다. conventional 제목을 쓰지 않는 레포(제목이 자연어 문장)에서는 수정 커밋이 하나도 잡히지 않아
영향도 축이 비게 된다.

재현: 그런 레포에서 `profile-measure.sh measure` → 후보 3개 모두 위반 39/39 인데 영향도 0, fixPattern 일치 0건
(2026-11-18 실측, 비머지 커밋 40).

→ 닫는 방법 후보: 제목 대신(또는 함께) 같은 파일을 짧은 거리 안에 다시 고친 커밋을 수정 후보로 보거나, 프로필 조정 키로
레포별 수정 제목 패턴을 받는다 — 고르기 전에 센다.

**먼저 셀 것**: (1) 측정 대상 레포마다 비머지 커밋 중 `FIX_RE` 일치 비율, (2) 일치 0 인 레포의 수,
(3) 같은 파일 재수정(창 K) 커밋 수 대비 `FIX_RE` 일치 수.

지금 고치지 않는 이유: 표본 레포가 하나라 대안 정의를 고를 근거가 없다.

**실측 (2026-11-25)**: 로컬 체크아웃 중 비머지 커밋 20개 이상인 레포 56개(origin 으로 중복 제거, 레포마다 최근 비머지 200개).
`FIX_RE` 일치 비율 중앙값 5.1%(범위 0~44%), 일치 0 인 레포 5 — 그중 conventional 제목이 아예 없는 레포는 1(위 재현 레포)이고
나머지 4 는 conventional 제목을 쓰지만 문서·메모리 레포라 `fix` 커밋이 없다. 같은 파일을 뒤 5 커밋 안에 다시 고친 커밋은 중앙값 82%,
`FIX_RE` 일치 수의 12.5배다.

```bash
$ git -C <레포> log --no-merges -n 200 --format='%x00%s' --name-only   # 레포마다 — 제목에 FIX_RE·conventional 정규식, 파일 집합으로 창 5 재수정
```

→ 판단: "같은 파일 재수정" 을 수정 커밋으로 보는 후보는 **기각** — 커밋 대부분이 해당해 영향도가 위반율과 구분되지 않는다. 남은 문제는
conventional 제목이 없는 레포(1/56)에서 영향도 0 이 "결함 없음" 으로 읽히는 것이다. 닫는 방법을 좁힌다: 측정 창에서 `FIX_RE` 일치가 0 이면
영향도 칸을 0 이 아니라 **측정 불가(수정 커밋 0)** 로 표시한다.

닫힘: 좁힌 방법대로 — 재생한 커밋에 수정 커밋 제목이 0개면 `impact.measurable=false`·비율 null, 표 칸 "측정 불가(수정 커밋 0)" 와 안내 줄, 조정 근거(evidence)에도 측정 불가를 적는다. `skills/preflight/DECISIONS.md` 2026-11-25 「수정 커밋이 없으면 영향도는 측정 불가」, 회귀 `meta-test/profile-measure.sh` PM6b.

### 기준을 고치는 비용 — `agents/*.md` 변경의 라운드 수 — 닫힘 (2026-11-25)
게이트가 **자기 개선을 게이트한다.** 2026-09-10 훅·검사기 변경이 16라운드였다. 그 비용이
lane 기준을 고칠 때도 든다면 사람은 기준을 안 고치거나 우회한다 — QA 강제를 뺄 때 본 구조와
같다(강제 기간 면제율 10/10, 그중 2건은 게이트 전체 우회).

지금은 근거가 없다. 16라운드는 **훅과 검사기**를 고친 것이라 대표성이 없고, `agents/*.md` 만
바뀐 커밋의 라운드 수를 세어본 적이 없다. 비용은 이미 갈려 있기도 하다 — 같은 날 문서만
바뀐 커밋은 lane 1개·12.4초·1라운드였다(분류기가 `no-code-change` 로 줄인다).

**세야 할 것**: `agents/*.md` 만 변경된 커밋이 몇 라운드에 통과하는가.

| 관측 | 결론 |
|---|---|
| 1~2라운드 | 현행 유지 — 기준 변경은 이미 싸다 |
| 3라운드 이상이 반복 | 기준 변경용 경로를 따로 본다 (지금 만들면 근거 없는 통제를 하나 더 얹는 것) |

**세는 명령.** `classify.sh` 가 라운드마다 `event: round` 를 남긴다 — 분류 시점이라
게이트가 FAIL 로 끝난 라운드도 표본에 들어간다:

```bash
python3 - ~/.claude/preflight-log.jsonl <<'ZR'
import collections, json, sys

rounds, paths = collections.defaultdict(set), collections.defaultdict(list)
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e.get('event') != 'round':
        continue
    # 한 묶음 = 커밋 게이트는 이 커밋 위에서, PR 게이트는 이 브랜치의 PR 에서 돈 라운드들
    k = (e['repo'], e['branch'], 'PR' if e.get('kind') == 'pr' else e['head'])
    rounds[k].add(e.get('roundDigest') or e['contentDigest'])   # 서로 다른 값의 개수 = 라운드 수
    paths[k].append((e['files'], e['paths']))

def only_agents(k):
    # paths 는 상한에서 잘린다 — 한 라운드라도 잘렸으면 "이것만" 을 주장할 수 없다
    return all(n == len(p) and p and all(f.startswith('agents/') and f.endswith('.md') for f in p)
               for n, p in paths[k])

for k in sorted(rounds):
    print(f"{len(rounds[k])}라운드  {'agents-only' if only_agents(k) else '기타':<11}"
          f"  {k[1]} @{k[2][:8]}  {k[0]}")
ZR
```

묶음이 `repo`+`branch`+`head` 인 이유: 커밋하면 `head` 가 바뀌어 **다음 커밋**이 다른 묶음으로
갈린다. 브랜치로만 묶으면 한 브랜치의 커밋 7개가 한 덩어리가 되어 커밋당 라운드 수가 안 나온다.

**PR 게이트는 `repo`+`branch` 로 묶고 `roundDigest` 로 센다.** PR 게이트는 커밋 뒤에 돌아
`contentDigest` 가 늘 빈 해시라(실측: PR 라운드 이벤트 422건에 값 4가지) 그것으로는 아무것도 못 센다.
`roundDigest` 는 merge-base 이후 브랜치 내용과 PR 본문(`--body-file`)으로 만든다 — 지적을 고친 커밋이
`head` 를 바꿔도 같은 PR 의 다음 라운드로 세고, 본문만 고친 라운드도 센다. 본문을 안 넘기면 본문만
고친 라운드는 합쳐진다. merge-base 를 못 구한 이벤트는 `roundBasis: head-fallback` 으로 커밋마다 가르고, 본문을 못 읽은
이벤트는 `bodyError` 를 남긴다. 2026-10-27 이전 PR 이벤트에는 `roundDigest` 가 없어 예전처럼 하나로 합쳐진다.
라운드 수를 `contentDigest` 의 **가짓수**로 세는 이유: 한 변경이 N 라운드 돌면 이벤트도 N 개라
그대로 세면 이벤트 수가 되고, 내용이 그대로인 재실행은 라운드가 아니라 같은 상태의 재분류다.

**아직 표본이 없다.** 이 이벤트는 2026-09-17 에 들어갔고 그 이전 라운드는 로그에 없다 —
위 명령의 출력이 쌓이기 전까지 이 항목의 결론 칸은 채우지 않는다.

**실측 (2026-11-25)**: 위 명령으로 센 묶음 2339개 중 `agents-only` 10개 — 1라운드 9, 2라운드 1(PR 게이트 1건). 3라운드 이상 0.
같은 로그의 전체 묶음은 1라운드 1873·2라운드 308·3라운드 88·4라운드 38·5라운드 이상 32.

닫힘: 표의 "1~2라운드 → 현행 유지 — 기준 변경은 이미 싸다" 에 해당한다. 기준 변경용 경로를 따로 만들지 않는다.

### 기준선 체크아웃의 HEAD 가 프롬프트의 기준 커밋과 달라 lane 이 기준선을 의심한다 — 닫힘 (2026-11-25)
위치: `skills/preflight/preflight.js` 기준선 프롬프트("기준선 체크아웃 … 기준 커밋 …") · `skills/preflight/DECISIONS.md`
2026-11-18 「측정 입력을 6개 더했다」의 측정.

스냅숏은 트리 id 를 대조하므로 내용은 같은데, 프롬프트는 커밋만 준다. lane 이 HEAD 를 비교해 다르면 기준선을 버리고
기존 실패를 새로 깨진 것으로 올린다(위 측정 `node-baseline-broken-clean` 에서 두 모델 각 1/5).

→ 닫는 방법: 기준선·대상 프롬프트에 "체크아웃 HEAD 는 스냅숏이 만든 커밋이라 기준 커밋과 다르다 — 트리 id 로 대조됐다" 와
트리 id 를 준다.

**먼저 셀 것**: 실제 로그의 test-runner FAIL 중 사유에 기준선 불일치가 적힌 비율.

닫힘: 기준선 수집·test-runner·대상 스냅숏 프롬프트가 HEAD 해시 차이가 정상임을 알린다 — `skills/preflight/DECISIONS.md` 2026-11-25 「스냅숏 체크아웃의 HEAD 해시가 다른 것은 정상이라고 알린다」.

### `PF_AGENTS_DIR` 설명이 워크플로가 읽는 정의를 바꾸는 것처럼 읽힌다 — 닫힘 (2026-11-25)
위치: `skills/preflight/eval/flip.sh` 의 `AGENTS_DIR` 주석·재측정 쪽 주석.

이 변수는 flip 이 해시할 자리만 바꾼다. 세션 등록이 읽지 않는 디렉터리를 주면 manifest 가 돌지 않은 정의를 기록한다.

→ 닫는 방법: 주석에 "해시할 자리만 바꾼다 — 세션이 읽는 agents 디렉터리를 줘라" 를 적는다.

닫힘: 두 구간 주석에 "해시할 자리만 바꾼다 — 세션이 실제로 읽는 agents 디렉터리를 줘라" 를 적었다 — 같은 DECISIONS 절.

### manifest 의 `harness`·`harnessDirty` 가 파일 링크·복사 설치에서 비어 있다 — 닫힘 (2026-11-25)
위치: `skills/preflight/eval/flip.sh` 의 `git -C REPO rev-parse HEAD` / `status --porcelain`.

REPO 는 스크립트 디렉터리 기준이라 그 설치 형태에서 체크아웃이 아니다 — 커밋이 빈 문자열, dirty 가 false 로 남는다.

→ 닫는 방법: `engine_checkout()` 결과로 계산하고 없으면 null.

닫힘: 두 manifest 모두 `engine_checkout()` 에서 재고, 체크아웃이 아니면 null — `skills/preflight/DECISIONS.md` 2026-11-25 「flip manifest 의 harness 를 엔진 체크아웃에서 잰다」.

### 엔진 단독 스위트에 조직 카테고리 의존 단언이 없다 — 닫힘 (2026-11-25)
엔진을 오버레이 레포에서 떼어 낼 때(2026-11-17), vault 등록 조회·QA 안내·관례 범위처럼 **카테고리 규칙 훅을
거쳐야 드러나는** 엔진 동작의 단언은 그 규칙을 가진 오버레이 카테고리 스위트로 옮겼다. 오버레이와 함께 돌리면
그대로 검증되지만, 엔진만 돌리면 그 훅 경로(`vault_link`·`QA_HINT`·`convention`·`vault_docs`)는 검사되지 않는다.

→ 닫는 방법: 엔진 meta-test 안에 조직 용어 없는 **테스트 전용 카테고리 픽스처**를 두고, 옮긴 단언을 그 픽스처로 다시 쓴다.

닫힘: 엔진 meta-test 가 테스트 전용 오버레이(`fixture-hooks` 는 규칙 훅 전부, `fixture-bare` 는 match 만)를 만들어 같은 변경을 두 카테고리 레포에서 분류하고, 훅 값이 lane 선택·laneMeta·vaultLink·qa 사유·files 에 실리는지와 훅이 없을 때의 기본값을 본다 — `skills/preflight/DECISIONS.md` 2026-11-25 「카테고리 규칙 훅을 엔진 스위트가 직접 본다」, 회귀 `meta-test/engine.sh` 「카테고리 규칙 훅 → 엔진 동작」 CH-a~CH-i.

### Python 레포의 테스트가 돌지 않는다 — 닫힘 (2026-11-24)
`.py` 는 `code-reviewer` 대상(`classify.sh` `CODE_EXT`)이지만 `test-runner` 는 eslint/tsc/jest 만 돌아 Python 테스트(pytest 등)를
실행하지 않는다 — `.py` 변경에서 `test-runner` 는 `no-testable-file-change` 로 남는다.

→ 닫는 방법: 카테고리 규칙(`suites`)으로 레포의 테스트 명령을 분류기가 확정하거나, `test-runner` 에 언어별 명령을 둔다.

**먼저 셀 것**: 프로필이 있는 Python 레포 수와 그 레포들의 테스트 러너 종류.

닫힘: 분류기가 카테고리와 무관하게 `.py` 로직 변경 + 스냅숏의 `test_*.py`·`*_test.py` 에서 `test-runner` 를 고르고 Python 회귀 명령(pytest 신호(설정·conftest·함수형 테스트)가 있으면 `python3 -B -m pytest -q -o cache_dir=$(mktemp -d) <dirs>`, 없으면 테스트 파일 디렉터리마다 `python3 -B -m unittest discover -s <dir> [-t <top>] -p <패턴>`)을 확정한다 — `skills/preflight/DECISIONS.md` 2026-11-24 「Python 테스트를 분류기가 확정한다」, 회귀 `meta-test/engine.sh` 「Python 테스트」 py(a)~(y). "먼저 셀 것" 은 관측 로그로 셌다(관찰): `.py` 를 바꾼 라운드가 있는 레포 중 테스트가 있는 레포 둘, 둘 다 `unittest`.

### record 단계가 카테고리의 `SECRET_SCAN` 을 다시 계산하지 않는다 — 닫힘 (2026-11-23)
위치: `skills/preflight/receipt.sh` record 의 재스캔(CONTRACT `secret-scan-recheck-at-record`) · `skills/preflight/classify.sh`
`SECRET_SCAN_MODE`.

재스캔은 범위·파일을 다시 구하지만 "그 카테고리가 always 인가" 는 다시 보지 않는다. always 카테고리에서 분류 artifact 를 고쳐
`selected` 에서 `secret-scanner` 를 빼고 `secretScan` 을 그대로 두면, 재스캔이 CLEAN 일 때 기록이 통과한다(재스캔이 CLEAN 이
아니면 지금도 거부한다). 이번 변경 전에도 같았다 — 그때도 record 는 분류의 `selected` 를 필수 lane 의 근거로 썼다(회귀 아님).

재현: SECRET_SCAN 이 없는 카테고리 레포에서 깨끗한 변경을 스테이징하고 `classify.sh <repo> commit` → artifact 의 `selected` 에서
`secret-scanner` 를 지우고 `notSelected` 에 아무 사유나 넣는다 → `receipt.sh record commit <repo> '{}'` 가 기록된다.

→ 닫는 방법: record 에서 선언 카테고리의 `rules.py` 를 읽어 mode 를 다시 계산하고(`all` 분류는 always), always 면 재스캔 결과와
무관하게 `secret-scanner` 결과(SKIPPED·NOT_APPLICABLE 아님)를 요구한다.

**먼저 셀 것**: 관측 로그의 record 이벤트 가운데 분류 artifact 를 고친 흔적(기록의 lane 집합이 분류의 `selected` 와 어긋남,
`classify-sha256` 과 다른 artifact)이 있는 기록 수.

닫힘: record 가 재스캔의 `categoryMode`(선언 카테고리의 `rules.py`, `all` 분류는 always)로 모드를 다시 구해 `secret-scan-mode-mismatch` 로 거부한다 — `skills/preflight/DECISIONS.md` 2026-11-23 「기록 단계가 시크릿 검사 모드를 다시 구한다」, 회귀 `meta-test/engine.sh` SS-o. 남은 한계: 카테고리 이름 위조는 범위 밖(같은 절).
"먼저 셀 것" 의 관측 로그 집계는 이 레포에 로그가 없어 하지 않았다.
남은 한계(카테고리 이름 위조)도 닫힘(2026-11-24): record 가 같은 대상으로 카테고리 소속을 다시 판정해 `category-mismatch` 로 거부한다 —
`skills/preflight/DECISIONS.md` 2026-11-24 「기록 단계가 카테고리 소속을 다시 판정한다」, 회귀 `meta-test/engine.sh` CR-a~e.
