# 결정과 경위

주석은 **결론과 그것을 떠받치는 숫자**만 담는다. "처음엔 A였다가 B로 바꿨고 그 이유는…" 같은
**경위는 여기에** 쓴다. 한 커밋 안에서 설명되는 경위는 커밋 메시지로 보내고, 이 파일에는
**여러 커밋에 걸친 결정과 그 근거 숫자**만 남긴다.

형식: 날짜 · 무엇을 바꿨나 · 왜 (숫자) · 어디에 남았나.

이 엔진은 한 조직의 하네스 레포에서 떼어 냈다. 그 이전의 결정 기록은 조직 내부 정보(레포 이름·사건)를 담고 있어
옮기지 않았다. 코드 주석이 "DECISIONS.md 「…」" 로 가리키는 절 가운데 이 파일에 없는 것은 그 이전 기록이다 —
주석에 남은 결론과 숫자가 현재의 근거다.

---

## 2026-11-17

### 엔진을 독립 레포로 분리했다 — 엔진 · 카테고리 · 프로필 세 층

- **엔진**(이 레포): 분류(`classify.sh`)·실행/집계(`preflight.js`)·기록/검증(`receipt.sh`)·훅·계획 사이클·프로필 생성기.
  어느 조직에나 쓰는 것만 둔다.
- **카테고리**: 레포 성격별 규칙(`categories/<이름>/rules.py`·`procedures.json`). 엔진은 `shell-tool`(이 엔진 레포 자신)과
  `generic`(기본) 둘만 싣고, 조직 전용 카테고리는 **오버레이**에 둔다.
- **프로필**: 레포 하나의 카테고리 고정·승인된 조정(`profiles/<owner>/<repo>.json`). 오버레이가 있으면 오버레이에 쓴다.

**오버레이 루트**(`lib.sh pf_overlay_dir` — `PF_OVERLAY_DIR` 또는 `config.json` 의 `overlayDir`): 그 아래
`categories/`·`profiles/` 를 엔진 것에 더해 읽는다. 루트 사이 이름·슬러그가 겹치면 적재 실패(exit 3)다 — 어느 쪽 규칙인지
모르는 채로 고르지 않는다. 설정했는데 디렉터리가 없어도 적재 실패다(조용히 빠지면 그 카테고리의 검사가 사라진다).

**기본 카테고리 `generic`**: 엔진 카테고리만 설치하면 어떤 레포도 "카테고리 없음" 이라 `/harness-profile` 이 멈춘다.
catch-all `match` 는 "겹침은 풀지 않는다" 와 충돌하므로 선언의 `fallback` 으로 둔다 — 어느 카테고리에도 신호가 없을 때만
소속되고, 근거는 `fallback — 다른 카테고리의 신호가 없다` 다. `fallback` 은 전체에서 하나다.

**QA 세션 헤더**: 세션 헤더 이름과 함께 보낼 서명 안내는 카테고리 `qa_meta` 의 `sessionHeader`·`sessionNote` 로 옮겼다.
워크플로에 조직 헤더 이름이 박혀 있었다.

`ENGINE_VERSION` 2.0 → **2.1**: 오버레이 루트·`fallback`·`sessionHeader` 는 모두 선택 키라 MINOR 다. 기존 "2.0" 프로필은
그대로 적재된다(같은 MAJOR, 프로필 MINOR ≤ 엔진 MINOR).

옮기며 바뀐 검증: 카테고리 규칙 훅을 거쳐야 드러나는 엔진 단언은 그 규칙을 가진 오버레이 카테고리 스위트로 옮겼다
(`docs/backlog.md` 「엔진 단독 스위트에 조직 카테고리 의존 단언이 없다」). 이전 레포의 머지 이력에 기대던 단언(선행 PR 머지
커밋이 HEAD 의 조상인가)은 이력을 새로 시작하므로 지웠다.

---

## 2026-11-18

### 판단 역할 opus 에이전트 4개에 `effort: high` 를 명시했다

- **무엇**: `change-planner`·`plan-reviewer`·`code-reviewer`·`qa-reviewer` frontmatter 에 `model: opus` 다음 줄로
  `effort: high`. `model` 값은 그대로다.
- **왜**: Opus 5.5 의 effort 기본값이 medium 으로 내려갔고(이전 세대 high), 메인 세션과 다른 모델로 도는 서브에이전트에는
  세션 effort 가 적용되지 않는다. frontmatter 에 없으면 판단 lane 이 이전보다 얕게 추론한다.
- **하지 않은 것**: opus → sonnet 하향은 하지 않는다 — 5.5 세대 가격 차가 2배이고, 이 넷은 판단·적발 역할이라 놓쳤을 때
  비용이 더 크다. haiku 하향 후보(`vault-linter`·`test-runner`)와 `secret-scanner` 는
  `skills/preflight/eval/flip.sh` 로 같은 입력을 k 회 돌린 판정이 기대 판정과 일치하는 비율을 잰 뒤 정한다 —
  스크립트는 있지만 lane 모델 override 와 이 lane 들의 측정 픽스처가 아직 없다. `implementer` 는 기본(medium)을 유지한다.
- **어디에**: 올리는 쪽은 에이전트 frontmatter 가 정본이고, `preflight.js` 의 `EFFORT` 맵은 낮추는 쪽 전용으로 남긴다
  (`code-reviewer`·`qa-reviewer` 는 워크플로 호출에서 effort 를 넘기지 않으므로 frontmatter 값이 쓰인다).
  `ENGINE_VERSION` 은 올리지 않는다 — 프로필 스키마와 무관하다.

### `vault-linter`·`test-runner` 에 지적 어휘를 뒀다 — id 를 하네스가 계산하고, 같은 id 는 접는다

- **무엇**: `preflight.js` 의 `RULES` 에 두 lane 의 닫힌 어휘를, `SYMBOL_HINT` 에 심볼 안내를 더했다. vault-linter 는
  위반의 **종류**(frontmatter 값·형식·누락 키, wikilink 대상·형식, 언어, 파일명, 절대경로, 크기, append-only, 개인 데이터,
  게이트 어휘)로, test-runner 는 **어떤 검사가 새로 깨졌는가**(테스트·타입·린트·관례 검사기·회귀 명령·기준선 실패·미검증)로
  가른다. 둘 다 `other` 를 둔다. 이제 두 lane 의 finding id 도 `findingId()`(`rule@파일#심볼`)가 계산하고, lane 이 지은
  이름은 `label` 로 남는다. 스키마·게이트 프롬프트·`priorBlock`·집계의 id 치환은 어휘가 있는 lane 에 이미 적용되던 배관
  그대로다. 두 에이전트 정의의 id 불릿은 `code-reviewer` 와 같은 취지(어휘에서 rule 을 고르고 symbol 을 적는다, id 는
  하네스가 계산한다, 어휘는 워크플로가 정본)로 바꿨고 어휘 항목은 옮겨 적지 않았다.
- **같은 id 접기**(`foldFindings`, CONTRACT `finding-id-dedup-per-lane`): 집계가 어휘가 있는 lane 의 지적을 계산 id 로 묶어
  같은 id 를 하나로 합친다 — 첫 항목 기준, `blocking` 은 OR, `summary` 는 서로 다른 것만 ` / ` 로 잇고, `label` 은 첫 것.
  rule 이 없는 지적과 어휘가 없는 lane 은 접지 않는다.
- **왜**: haiku 로 내린 뒤 막은 실행 5회 중 최빈 id 집합 점유가 vault 2/5·test 1/5 였다(아래 절). lane 이 id 를 지으면
  라운드 사이 재발 집계(`recurrence`)가 같은 결함을 해소+새로 로 갈라 센다 — 그 절이 "모델을 되돌리기보다 어휘를 두는
  것이 순서" 라고 적은 대로 했다. 접기는 id 가 같다는 것이 곧 같은 결함이라는 정의에서 나온다: 한 테스트 파일에서 테스트
  2개가 깨지면 `new-test-failure@<그 파일>` 이 두 번 나오고, 접지 않으면 blocking 목록 건수가 실행마다 1·2 로 흔들린다.
- **치른 값**: test-runner 의 `new-test-failure` 는 **테스트 파일 단위**다(심볼을 비우게 했다 — 테스트 이름은 실행마다
  표기가 갈린다). 한 파일 안의 서로 다른 실패는 지적 하나로 합쳐지고, 구분은 이어 붙인 `summary` 에만 남는다. 그래서 한
  파일에서 실패 하나를 고치고 다른 하나가 남으면 재발 집계는 "같은 결함이 그대로" 로 센다. vault-linter 도 심볼을 비우는
  rule(언어·파일명·크기 등)은 같은 문서의 같은 종류 위반이 하나로 합쳐진다.
- **측정**(2026-11-18, haiku k=5, 결함 입력 2개, lane 정의는 이 머신의 오버레이 설치본): 최빈 id 집합 점유가 vault 2/5 → **5/5**(`frontmatter-enum@notes/release-checklist.md#status`), test 1/5 → **4/5**(`new-test-failure@test/slugify.test.js`), 판정 일치는 둘 다 5/5 그대로. test 의 1회는 같은 결함을 `regression-suite` 로 골랐다 — 이 입력의 회귀 명령이 `node --test` 자체라 두 rule 설명이 겹쳤다. 측정 뒤 `regression-suite` 를 "테스트 러너가 아닌 회귀 스크립트" 로 좁히고 `new-test-failure` 에 "회귀 명령으로 받은 테스트 러너 실행 포함" 을 더했다 — 이 수정은 다시 재지 않았다.
- **한계**: 어휘 선택이 실행마다 안정한지(같은 결함에 같은 rule 을 고르는지)는 이 변경으로 보장되지 않는다 — 경계가
  애매한 위반(예: frontmatter 형식과 enum 사이)은 rule 이 갈리면 id 도 갈린다.

### `vault-linter`·`test-runner` 를 sonnet 에서 haiku 로 내렸다

- **무엇**: 두 에이전트 frontmatter 의 `model: sonnet` → `model: haiku`. 다른 값(effort·contract)은 그대로다.
  `preflight.js` 의 `EFFORT` 맵(`vault-linter: low`)도 그대로 — 측정이 그 값으로 돌았다.
- **왜**: 아래 측정 장치로 입력 4개(lane 당 결함 1·대조군 1)를 모델마다 k=5 돌린 기대 판정 일치율이 haiku·sonnet 모두
  20/20 이다. 기준은 haiku 일치율 1.0 이었다. 트랜스크립트로 lane 에이전트 20개가 override 대로 각 모델에서 10개씩
  돈 것을 확인했다. FAIL 실행의 차단 지적은 전부 실제 결함을 가리켰고, 대조군 지적은 0건이었다.
  측정 명령: `eval/flip.sh prepare <out> --lane-model=vault-linter=<m> --lane-model=test-runner=<m> vault-status-enum
  vault-clean-note node-slug-regression node-slug-control` 뒤 실행마다 runId 를 달리해 k=5, `eval/flip.sh score <out> @<runs>`.
- **치른 값**: 같은 결함이 같은 id 로 나온 비율이 낮아졌다 — 막은 실행 5회 중 최빈 id 집합 점유가 haiku 는 vault 2/5·
  test 1/5, sonnet 은 5/5·3/5. 두 lane 은 `RULES` 어휘가 없어 lane 이 id 를 짓는다. 판정은 바뀌지 않지만 라운드 사이
  재발 집계(`recurrence`)는 이 두 lane 에서 해소+새로 로 갈려 세질 수 있다. 재발 집계가 필요해지면 이 두 lane 에
  어휘를 두는 것이 순서다(모델을 되돌리는 것보다). 토큰은 lane 1회 중앙값으로 haiku 가 더 쓴다(출력 약 3배) —
  단가 차이(1/20)가 그보다 크다.
- **한계**: lane 당 입력 2개다. 다중 결함·경계가 애매한 위반·기준선에서 이미 실패하던 테스트는 재지 않았다.
  이 경우가 실제로 새면 그 입력을 픽스처로 더해 같은 장치로 다시 잰다.
- **하지 않은 것**: `secret-scanner` 는 그대로 sonnet — 놓쳤을 때 공개 레포 유출로 이어진다.

### lane 모델 비교 측정 장치 — 측정 전용 override 와 픽스처 4개

- **무엇**: `preflight.js` 가 `args.laneModel`·`args.laneEffort`(`{lane: 값}`)를 받아 그 lane 호출의 model·effort 만 바꾼다.
  `eval/flip.sh prepare` 가 `--lane-model=<lane>=<model>`·`--lane-effort=<lane>=<effort>` 로 그 인자를 해당 lane 을 재는
  입력의 `args.json` 에만 싣고 manifest 에 남긴다. `score` 는 결과의 override 가 manifest 와 다르면 거부한다.
  입력 4개: `vault-status-enum`(enum 밖 status — FAIL)·`vault-clean-note`(대조군 PASS)·`node-slug-regression`
  (기존 테스트를 깨는 변경 — FAIL)·`node-slug-control`(대조군 PASS). 둘씩 한 값만 다르다.
- **왜**: haiku 하향 후보 lane 은 기계적이지만(로그 76일 도구 호출 중앙값 2·5) 하향 여부는 같은 입력의 기대 판정
  일치율로 정한다 — 기준은 haiku 일치율 1.0. 측정 없이 내리면 놓친 결함이 어디서 새는지 보이지 않는다.
- **게이트가 약해지지 않게**: override 가 하나라도 있으면 verdict·`lanes[].status`·`receiptLanes[].status` 가 전부
  `MEASUREMENT_ONLY` 다 — `receipt.sh` 의 통과 목록(PASS·SKIPPED·NOT_APPLICABLE)에 없어 record 가 거부한다. 데이터 스크립트
  적재(게이트 전용 경로)와 함께 오면 워크플로가 시작 전에 거부한다. 이번 실행의 게이트 lane 이 아닌 키·허용 밖 값도 거부한다
  (오타가 조용히 무시되면 "haiku 로 쟀다" 가 거짓이 된다).
- **픽스처 카테고리**: 엔진에는 vault 문서 규칙이 없고, 실제 lane 은 tsc/jest 설치 상태에 흔들린다. 입력이
  `eval/fixtures/_overlay` 를 복사해 들고 오고 `flip.sh` 가 그때만 `PF_OVERLAY_DIR` 로 준다 — 이 머신의 오버레이가 섞이지
  않아 입력이 고르는 lane 이 머신마다 같고, 회귀 명령은 설치 없는 `node --test` 로 확정된다.
- **하지 않은 것**: 에이전트 frontmatter 의 model 은 바꾸지 않았다 — 측정 결과를 보고 별도 변경으로 한다.
  `secret-scanner` 는 놓쳤을 때 공개 레포 유출로 이어져 이번 측정 대상에서 뺐다.

### 메인 세션의 레포 직접 편집 차단

**결정**: PreToolUse 훅 `hooks/main-edit-guard.sh`(matcher `Edit|Write|MultiEdit|NotebookEdit`)가 메인 세션(훅 입력에
`agent_id` 없음)의 레포 파일 편집을 막고 `implementer` 서브에이전트 위임을 요구한다. 관측(`edit-observe.sh`, #88)과
역할 분담 정본(SKILL.md 「역할 분담」)만으로는 메인 직접 편집이 줄지 않았다 — 아래 수치.

**판정 규칙**(처음 걸린 것이 답): 모드 off → 개입 없음(출력·로그 없음) · `agent_id` 있음 → 통과(subagent) ·
allowlist → 통과 · 레포 밖 → 통과(outside-repo) · Edit `replace_all=true` → 차단 · Edit 바뀐 줄 ≤ 2 → 통과(small-edit),
그 이상 차단 · MultiEdit 는 replace_all 이 하나라도 있으면 차단, 아니면 바뀐 줄 합계로 같은 규칙 · Write 는 새 파일(new-file)·
기존 파일(repo-edit) 모두 차단 · NotebookEdit 차단. 바뀐 줄 = `difflib.SequenceMatcher(old 줄, new 줄)` 의 opcode 마다
`max(삭제 줄, 삽입 줄)` 의 합 — 교체 한 줄을 2로 세지 않으려고 합이 아니라 max 다.
레포 판정은 경로의 가장 가까운 **존재하는** 상위 디렉터리에서 `git rev-parse --show-toplevel`(3초). allowlist 는 내장
(`~/.claude/projects/*/memory/**`, `~/Library/Application Support/Claude/side-session-notes/**`) + config.json
`mainEditGuardAllow` + 오버레이 `edit-guard.json` 의 `allow`, 경로 그대로와 realpath 양쪽으로 대조한다.

**2줄 예외**: SKILL.md 역할 분담의 예외 「한두 줄 수정」과 같은 선이다. 오타·버전 숫자 같은 한두 줄을 위임하면 위임
비용(브리핑·워크트리·보고 대조)이 편집보다 크다. `replace_all` 은 old/new 로 줄 수를 셀 수 없어(일치마다 바뀐다) 한 줄이어도 막는다.
Write 는 내용 전체를 쓰므로 크기와 무관하게 막는다.

**모드·기본값 off**: off|warn|enforce, 그 밖의 값은 off. 해석은 `PF_MAIN_EDIT_GUARD`(설정돼 있으면) > 설치본
`config.json` 의 `mainEditGuard`(머신 로컬 탈출구, 빈 값은 다음으로) > 오버레이 루트(`pf_overlay_dir` 와 같은 해석)의 커밋 파일
`edit-guard.json` 의 `mainEditGuard` > off. 엔진은 공개 레포라 누구에게나 깔린다 — 위임 대상(`implementer`)을 쓰는
워크플로가 아닌 설치에서 편집을 막으면 안 되므로 엔진 기본은 끄고, 켜는 것은 오버레이(조직)와 머신의 몫이다.
`config.example.json` 의 `mainEditGuard` 는 `""` 다 — `"off"` 로 두면 example 에서 만든 모든 config.json 이 오버레이
설정을 덮어 오버레이가 켤 수 없게 된다. warn 은 차단 자리에서 `additionalContext` 만 내고 로그에 `outcome: warn` 을 남긴다
(켜기 전 영향 측정용).

**fail-open**: 입력 파싱 실패·예외·git 실행 불가·git 시간 초과는 출력 없이 exit 0(가능하면 `outcome: error` 로그).
`git rev-parse` 가 0 아닌 코드로 끝나는 것(레포 아님 포함)은 오류가 아니라 레포 밖 판정이다(`allow`, `outside-repo`). 이 훅이 고장 나
모든 편집이 막히면 그 훅을 고칠 수단(편집)까지 막힌다. 게이트 훅(preflight-gate.sh, fail-closed)과 반대인 이유는 막는 대상이
다르기 때문이다 — 커밋은 기다릴 수 있지만 편집이 막히면 복구할 길이 없다.

**홈 레포 예외**: toplevel 이 `$HOME` 과 같으면 레포 밖으로 본다. 실측상 홈 디렉터리 자체가 git 레포인 머신이 있다 — 아래
근거 수치의 분해에서 측정 기간 메인 Edit/Write 202건 중 45건의 repo 가 `$HOME` 이었다. 그대로 두면 메모리·세션 노트·설정 파일 편집이 전부
레포 편집으로 막힌다.

**근거 수치** — `edit-observe.sh` 로그(`event: edit`), 기간 2026-11-16 00:00 KST(ts 1794754800) ~ 2026-11-18 10:31:31 KST
(ts 1794965491):

- (a) 메인(`outcome: main`), `tool ∈ {Edit, Write}`, repo 있음 · repo ≠ `$HOME` · path 가 repo 아래: **70건 · 13세션** (Edit 55 · Write 15)
- (b) 서브에이전트(`outcome: subagent`) Edit/Write: **62건** (Write 41 · Edit 21)
- 참고: 메인 Edit/Write 전체 202건 = (a) 70 + 홈 레포 45 + repo 없음 78 + repo 는 있으나 path 가 그 밖 9
  (9건은 심링크된 메모리 디렉터리 — repo 는 메모리 레포, path 는 `~/.claude/projects/…/memory`)

```
$ python3 - <<'PY'
import json, os
LO, HI = 1794754800, 1794965491
H = os.path.realpath(os.path.expanduser("~"))
rs = [r for r in map(json.loads, open(os.path.expanduser("~/.claude/preflight-log.jsonl"), errors="surrogateescape"))
      if r.get("event") == "edit" and LO <= r.get("ts", 0) <= HI]
under = lambda r: (r.get("path") or "").startswith((r.get("repo") or "\0").rstrip("/") + "/")
a = [r for r in rs if r["outcome"] == "main" and r["tool"] in ("Edit", "Write") and r.get("repo")
     and os.path.realpath(r["repo"]) != H and under(r)]
b = [r for r in rs if r["outcome"] == "subagent" and r["tool"] in ("Edit", "Write")]
m = [r for r in rs if r["outcome"] == "main" and r["tool"] in ("Edit", "Write")]
home = [r for r in m if r.get("repo") and os.path.realpath(r["repo"]) == H]
norepo = [r for r in m if not r.get("repo")]
outside = [r for r in m if r.get("repo") and os.path.realpath(r["repo"]) != H and not under(r)]
print(f"a={len(a)} a_sessions={len({r.get('sessionId') for r in a})} b={len(b)}",
      f"main={len(m)} home={len(home)} norepo={len(norepo)} path_outside_repo={len(outside)}")
PY
a=70 a_sessions=13 b=62 main=202 home=45 norepo=78 path_outside_repo=9
```

상위 세션이 앞서 잰 값(메인 레포 74건·15세션, 서브에이전트 51건)과 다른 이유: 측정 시각이 늦어 서브에이전트 편집이 더
쌓였고(이 변경의 구현 편집 포함), 메인 쪽은 path 가 repo 아래인 것만 세어 심링크 메모리 경로 9건이 빠졌다(상한 ts 가 없던
측정이라 정확한 대응은 재현할 수 없다).

**한계**: 사이드 세션은 자기 프로세스에서 최상위라 `agent_id` 가 없어 메인으로 집계·판정된다 — 사이드 세션에서도 막히므로
사이드 세션도 `implementer` 에 위임해야 한다. Bash 편집(`sed -i`·리다이렉트 등)은 막지 않는다 — 명령 모양 판정은 우회할 수
있고 오탐이 읽기 명령을 막는다. 그쪽은 `edit-observe.sh` 가 관측만 한다.

`ENGINE_VERSION` 2.1 → **2.2**: 새 훅과 새 선택 설정 키(`mainEditGuard`·`mainEditGuardAllow`·오버레이 `edit-guard.json`)는
하위 호환 기능 추가라 MINOR 다. 기본 off 라 기존 설치의 동작은 바뀌지 않고, "2.1" 프로필은 그대로 적재된다.
