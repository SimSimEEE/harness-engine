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

### 측정 입력을 6개 더했다 — 다중 결함·경계·오탐 유도·동시 회귀·깨진 기준선

- **무엇**: 아래 「haiku 로 내렸다」 절의 한계(lane 당 입력 2개)에 적은 경우를 입력으로 더했다 — 다중 결함
  (`vault-multi-defect`), 형식만 틀린 경계 위반(`vault-date-format`), 위반처럼 보이는 정상 문서로 오탐을 유도하는 대조군
  (`vault-lookalike-clean`), 두 테스트 동시 회귀(`node-multi-regression`), 기준선부터 실패하는 테스트 — 새 실패가 없으면
  PASS 기대(`node-baseline-broken-clean`), 새 회귀가 함께 오면 FAIL 기대(`node-baseline-broken-regress`). 각 입력은 만들 때
  전제(테스트 실패 수 등)를 스스로 확인하고 어긋나면 exit 1 이다. 깨진 기준선은 `_node_base.sh` 의 `add_broken_baseline()` 이
  develop 에 커밋·push 한다.
- **측정**(모델별 k=5, 측정된 정의는 측정 머신의 설치본 = 오버레이 정의 — manifest `agentSources` 로 확인):

  | 입력 | 기대 | haiku | sonnet |
  |---|---|---|---|
  | vault-multi-defect | FAIL | 5/5 | 5/5 |
  | vault-date-format | FAIL | 5/5 | 5/5 |
  | vault-lookalike-clean | PASS | 5/5 | 5/5 |
  | node-multi-regression | FAIL | 5/5 | 5/5 |
  | node-baseline-broken-clean | PASS | 4/5 | 4/5 |
  | node-baseline-broken-regress | FAIL | 5/5 | 5/5 |

  다중 결함은 두 모델 모두 5회 전부 세 결함을 다 지적했고, 오탐 유도 대조군은 두 모델 모두 지적 0 이다.
  `node-baseline-broken-clean` 의 FAIL 각 1회는 같은 원인이다 — lane 이 기준선 체크아웃의 HEAD 가 프롬프트의 기준 커밋과
  다르다고 보고 기준선을 믿지 않았다(스냅숏은 트리를 풀어 새 커밋을 만들므로 HEAD 가 다르다). 모델 차이가 아니라 기준선
  프롬프트의 모호함이다 → `docs/backlog.md` 「기준선 체크아웃의 HEAD 가 프롬프트의 기준 커밋과 달라 lane 이 기준선을 의심한다」.
  측정 명령: `eval/flip.sh prepare <out> --lane-model=vault-linter=<m> --lane-model=test-runner=<m> <입력 6개>` 뒤 실행마다
  runId 를 달리해 k=5, `eval/flip.sh score <out> @<runs>`.
- **어디**: `eval/fixtures/`(입력 6개·`_node_base.sh`), `meta-test/engine.sh`(flip prepare 단언의 입력 집합).

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
- **정정 (같은 날)**: 위 측정에서 돈 정의는 이 레포의 `agents/` 가 아니라 측정한 머신의 설치본이었다. 그 설치본은
  오버레이가 두 이름을 덮고 있어 lane 트랜스크립트 40개 전부에 오버레이 정의에만 있는 문구가 실려 있었고, 엔진 정의의
  문구는 없었다. 모델 override 는 frontmatter 를 덮으므로 모델별 비교 자체는 유효하다 — 잰 것은 **오버레이 정의의**
  haiku·sonnet 일치율이다. 엔진 정의는 직접 재지 않았다. 두 정의는 절차가 같고 오버레이 판이 조직 레포 이름·경로를
  더한 것이라 엔진 하향은 그대로 두되, 근거가 옮겨 쓴 것임을 여기 남긴다. 엔진 정의로 직접 재려면 오버레이 없이 설치한
  환경에서 같은 명령을 돌린다. 출처를 잘못 적은 원인은 아래 「flip 측정의 에이전트 출처」.

### flip 측정의 에이전트 출처 — 레포가 아니라 설치본 정의를 기록한다

- **무엇**: `eval/flip.sh` 의 manifest 다이제스트(`agents`)를 이 레포의 `agents/<lane>.md` 가 아니라 워크플로가 해석하는
  설치본(`~/.claude/agents/<lane>.md` 의 실경로, `PF_AGENTS_DIR` 로 바꾼다)에서 뜬다. `agentSources` 에 실경로와 레포 정의와의
  일치 여부(`sameAsRepo`)를 남기고, 다르면 prepare·score 가 경고한다. 재측정(③)의 `claim-remeasurer` 다이제스트도 같다.
  대조할 레포는 `flip.sh` 파일의 실경로가 놓인 체크아웃이다(`PF_ENGINE_REPO` 로 준다) — 스크립트 디렉터리 기준이면 파일 단위
  링크·복사 설치에서 설치 루트가 되어 설치본을 설치본과 비교한다. 체크아웃이 설치 루트와 같으면(복사 설치) `sameAsRepo` 는
  `null` 이고 경고한다 — 대조하지 않은 것을 일치로 적지 않는다.
- **왜**: 워크플로는 `agentType` 을 세션의 에이전트 등록에서 해석한다. 오버레이가 같은 이름의 정의를 덮은 설치본에서
  레포를 해시하면, manifest 는 돌지 않은 정의를 "잰 정의" 로 적는다 — 위 하향 측정이 그렇게 대상을 잘못 기록했다.

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

### `.py` 를 코드로 친다 — 리뷰 대상, 테스트 대상은 아니다

- **무엇**: `classify.sh` 의 `CODE_EXT` 에 `.py` 를 넣고, `_commentish` 가 `.py` 를 `#` 주석 언어로 본다. `TESTABLE_EXT` 에는
  넣지 않았다. `.py` 로직 변경은 `code-reviewer`(`--review`·PR 게이트)와 `--qa` 의 `qa-runner`(배포물 집합 `DEPLOYED_EXT` 가
  `CODE_EXT` 에서 파생된다)를 고르고, `test-runner` 는 `no-testable-file-change` 로 남는다.
- **왜 (숫자)**: 처음 보는 Python 레포 스모크에서 `.py` 를 바꾼 변경의 `selected` 가 `secret-scanner` 하나, `code=[]` 였다 —
  리뷰가 PR 게이트에서도 돌지 않는다. 확장자로 코드를 판정하는 자리는 `CODE_EXT` **1곳**이다. 거기서 파생되는 자리가
  `DEPLOYED_EXT`(QA 배포물)·`test_files`(`TESTABLE_EXT` 로 거른다) 둘이고, 주석 판정 `_commentish` 는 별도 목록이라 같이 고쳤다.
  lib.sh·profile.sh·profile-measure.sh·harness-profile 스킬에는 확장자 판정이 없다. 그래서 언어 목록 정본을 따로 만들지 않았다.
- **test-runner 범위**: `test-runner` 는 eslint/tsc/jest 만 돈다. `.py` 를 `TESTABLE_EXT` 에 넣으면 Python 레포에서 없는
  tsconfig·jest 를 돌려 실패만 만든다. Python 테스트 실행은 백로그(「Python 레포의 테스트가 돌지 않는다」)로 남겼다.
- **ENGINE_VERSION 유지**: 프로필 스키마·설정 키가 바뀌지 않았다 — 같은 날 haiku 하향·`effort` 명시와 같은 선례다.
- **어디**: `classify.sh`(`CODE_EXT`·`_commentish`), `meta-test/engine.sh` 「배포 동작 집합은 한 곳에서 정의된다」 절의 `.py` 단언 4개.

### 프로필 결정 기록 자리를 프로필이 쓰인 레포로 바로잡았다

`harness-profile` 7단계는 결정 기록을 엔진 `DECISIONS.md` 에 남기라고 했지만, `profile.sh init` 은 오버레이가 설정돼 있으면
프로필을 오버레이의 `profiles/` 에 쓴다(공개 엔진에 레포 정보를 남기지 않는다). 그 지시대로면 프로필은 오버레이에, 그 레포
이름이 적힌 결정 기록은 공개 엔진에 남는다. 이제 결정 기록은 프로필이 쓰인 레포 — 오버레이면 `<오버레이>/docs/DECISIONS.md`,
없으면 엔진 `DECISIONS.md` — 에 쓰고, 둘을 같은 레포에 커밋한다. 어디: `skills/harness-profile/SKILL.md` 흐름도·7단계.

## 2026-11-19

### 시크릿 검사 결정론 우선 — 정규식이 걸러 넘긴 것만 `secret-scanner` 가 판정한다

- **무엇**: 분류기가 `secret-scan.sh` 로 변경(커밋 모드 HEAD 대 인덱스, PR 모드 merge-base..HEAD)의 추가·삭제 라인을
  `secret-patterns.json`(패턴·민감 경로 정본, `version` 포함)으로 스캔한다. 결과는 `CLEAN`·`HITS`·`SENSITIVE_PATH`·`SCAN_ERROR`
  이고, 분류 JSON 의 `secretScan` 에 값 없이(패턴 이름·파일·줄 번호만) 남는다. 카테고리 rules.py 의 `SECRET_SCAN` 이 `'auto'`
  일 때만 `CLEAN` 이면 `secret-scanner` 를 건너뛴다(사유 `secret-scan-clean — …`). 그 밖에는 걸린 위치·민감 경로를
  `laneMeta['secret-scanner'].scan` 으로 프롬프트에 넘기고, lane 은 "걸린 것 판정 + 민감 경로 파일 내용 확인" 을 한다.
  카테고리는 `SECRET_SENSITIVE_EXTRA` 로 민감 경로 glob 을 더한다. `receipt.sh record` 는 범위·파일을 분류 artifact 에서
  받지 않고 다시 구해 같은 대상을 다시 스캔해(카테고리는 선언값), status·patternsVersion 이 분류와 다르거나 `CLEAN` 이 아닌데 `secret-scanner` 결과가 없거나 SKIPPED 면
  거부한다(`secret-scan-mismatch`).
- **경로·바이너리 처리**: diff 헤더 경로 표기(`/dev/null`, `a/`·`b/` 접두, 공백 경로의 끝 TAB, `core.quotePath` 에 따른
  C 인용 `"…"`+`\ooo`)를 모두 풀고, 같은 범위의 `git diff --numstat -z` 가 줄 변경이 있다고 한 텍스트 파일이 스캔에서
  하나라도 빠지면 SCAN_ERROR 다(파서 누락이 CLEAN 이 되지 않게). 바이너리(`-\t-`)는 내용을 못 보므로 이름과 무관하게 민감
  경로로 보고, 키 저장소 확장자(`*.p12`·`*.pfx`·`*.jks`·`*.keystore`·`id_rsa*`·`id_ed25519*`)를 민감 경로에 더했다. 따옴표 없는 비밀번호
  할당(YAML·properties·env)과 접속 URL 에 박힌 자격증명은 suspect 패턴으로 LLM 에 넘긴다 — 플레이스홀더는 정규식에서 거르지
  않고 판정에 맡긴다(오탐은 비용, 미탐은 사고). 패턴 정본은 v4 이다.
- **후속 수정(호환, 엔진 버전 그대로)**:
  - 키 이름이 따옴표로 닫힌 뒤 `:`·`=`·`=>` 가 오는 형태(JSON·dict·해시)를 suspect `secret-like-quoted-key` 로 잡고, `secret-like-assign` 에 `=>` 와 세션·접근 토큰/키·비밀번호 계열 어휘를 더했다 — 따옴표 키에 따옴표 없는 값(숫자·불리언·변수 참조)은 일부러 안 잡는다.
  - 기록 단계 재스캔의 거부 사유를 가른다: PR 모드에서 status 가 갈리고 분류 artifact 의 `base.mergeBase` 가 지금 merge-base 와 다르면 `secret-scan-base-moved`(분류 이후 base 브랜치가 움직임), 아니면 `secret-scan-mismatch` — 둘 다 거부다.
  프롬프트의 역할은 auto 카테고리의 HITS·SENSITIVE_PATH 에서만 "걸린 것 판정" 으로 좁히고, always·SCAN_ERROR 는 전수 검사다.
- **기본값은 현행 유지(opt-in)**: 상수가 없거나 `'always'` 면 지금처럼 늘 선택하고, 스캔 결과는 기록만 한다. 엔진·오버레이의
  배포 순서와 무관하게 오버레이 카테고리는 바뀌지 않는다. 이 엔진에서는 `shell-tool` 만 `'auto'` 다. `all` 모드는
  `'always'` 로 본다. 기본 카테고리 `generic` 은 `'always'` 로 둔다 — 미분류 레포가 모두 거기 오므로, `'auto'` 면 미분류
  문서 레포의 개인 데이터 검사와 정규식에 없는 형식의 자격증명 검사가 함께 빠진다.
- **왜**: 한 조직 설치본의 관측 로그에서 `secret-scanner` 는 사실상 모든 게이트에서 돌았지만 FAIL 은 드물었고, 과거 FAIL 은
  모두 정규식(JWT·AWS 키)으로 잡히는 값이었다. 이 단계 비용은 검사 단계 가운데 적지 않은 몫이었다.
- **검증 — 과거 입력 재생(모델 호출 없음)**: 과거 `secret-scanner` 실행의 diff 를 재구성해 새 라우팅으로 돌렸다.
  - 과거 FAIL 은 모두 LLM 으로 넘어갔다 — 일부는 내용 패턴(JWT·AKIA·ASIA)으로, 나머지는 `env/*.yml` 경로 규칙만으로
    (내용은 재구성되지 않았다). 경로 규칙은 빼면 안 되는 안전장치다.
  - 과거 WARNING 은 경로 규칙으로 넘어간 것, 내용이 재구성되지 않아 판정할 수 없는 것, 빈 범위 경고(`SCAN_ERROR` 가 대신한다)로 갈렸다.
  - 재구성 가능한 과거 통과 실행에서 코드 레포는 다수가 정규식 단계에서 끝났고, 문서 레포는 전부 그랬다.
  - AWS 임시 키(`ASIA…`) 지적이 기존 패턴표에 없어 패턴을 더했다.
  - 재구성 가능한 실행은 일부뿐이다(워크트리·임시 클론 삭제, 예전 분류 JSON 의 인덱스 트리 부재, 예전 프롬프트의 범위 부재) —
    대표성은 보장되지 않는다. **측정 스크립트는 이 레포 밖이라 수치는 싣지 않는다**(관측 로그와 과거 전사를 읽는 일회성 재생 스크립트).
- **치른 값**: 문서 레포의 개인 데이터 검사(정규식으로 못 잡는다)는 재생에서 문서 레포 실행이 전부 CLEAN 이었다 — 그런 카테고리를
  `'auto'` 로 두면 그 검사가 사라진다. 그래서 기본값을 `'always'` 로 두고 카테고리가 고른다.
- **이번 변경 범위에 넣지 않았다**: 선택된 lane 이 0개일 때 워크플로 없이 기록하는 단축 경로, 훅(verify)의 커밋 직전 재스캔.
- **어디**: `secret-scan.sh`·`secret-patterns.json`(신규), `classify.sh`(선택 규칙·`secretScan`), `receipt.sh`(record 재스캔,
  CONTRACT `secret-scan-recheck-at-record`), `preflight.js`(`secretScanBlock`), `agents/secret-scanner.md`(역할),
  `categories/shell-tool/rules.py`(`SECRET_SCAN = 'auto'`)·`categories/generic/rules.py`(상수 없음 — always), `meta-test/engine.sh`(회귀). `ENGINE_VERSION` 2.2 → **2.3**
  (호환되는 추가 — 새 선택 상수 둘, 프로필 계약은 그대로).

### `test-runner` 0.7 — 설치본 diff 규칙을 버리고 격리 실행 줄로 검사 대상을 확인한다

- **무엇**: `agents/test-runner.md` 0.7 의 "`diff -q <레포>/hooks/… $HOME/.claude/hooks/…` 가 갈리면 blocking" 규칙을 지웠다.
  meta-test 는 임시 HOME 에 스냅숏(오버레이 레포면 엔진 + 스냅숏 오버레이)을 설치본으로 삼아 돌므로, 검사 대상은 출력의
  `== 격리 실행: …` 줄로 확인하고 `~/.claude` 설치본과의 차이는 판정 근거가 아니다. 그 줄이 없거나 경로가 스냅숏이 아닐 때만
  검사 대상이 틀린 것으로 막는다. 함께, 회귀 명령은 포그라운드로 끝까지(`timeout: 600000`, `run_in_background` 금지) 돌리고
  종료 코드와 통과·실패 수를 본 뒤에 보고한다 — `preflight.js` 의 회귀 명령 프롬프트에도 같은 문장을 넣었다(meta-test 가
  목록에 있을 때만 격리 줄 문장을 붙인다).
- **왜**: 설치본은 머지·재설치 전에는 언제나 옛 판이라, 훅을 고치는 커밋은 그 규칙대로면 매번 FAIL 이다. 2026-11-19
  한 브랜치에서 이 지적이 커밋·PR 게이트에 되풀이돼 사유를 남긴 우회로 넘겼고, 같은 변경이 통과한 라운드도 있었다 — 판정이
  흔들렸다. 별도로 meta-test 를 백그라운드로 띄우고 끝나기 전에 보고해 "통과·실패 수 미확인" 으로 막힌 실행도 있었다.
- **측정**: flip 입력 `eval/fixtures/overlay-hooks-change.sh`(측정 전용 카테고리 `eval-overlay`, 기대 `test-runner` PASS)를
  더했다. 정의 변경 전후 수치는 PR 본문에 둔다.
- **어디**: `agents/test-runner.md` 0.6·0.7 공통 문단과 0.7, `skills/preflight/preflight.js` 회귀 명령 블록,
  `eval/fixtures/overlay-hooks-change.sh`·`eval/fixtures/overlay-hooks-regress.sh`·`eval/fixtures/_overlay/categories/eval-overlay/`, `SKILL.md` 참고 절.

### 빈 게이트 단축 경로 — 선택된 lane 이 없는 커밋은 워크플로 없이 한 호출로 기록한다

- **무엇**: `preflight-fast.sh <repo> commit [--msg-file=<초안>]`(신규)가 `classify.sh` 를 같은 인자로 돌리고, 필수 lane
  (`selected` + `sequential`)이 비어 있을 때만 모든 lane 을 SKIPPED(사유는 분류의 `notSelected` 그대로)로 채워
  `PF_RECORD_VIA=fast-path receipt.sh record commit` 을 부른다. 선택이 있으면 기록하지 않고 exit 10, 분류 실패면 그 종료코드,
  `pr`·`all`·`--qa`·`--review`·`--body-file` 은 exit 2 로 거부한다. 사실 주장 검사가 WARN 이면 요약에 한 줄 보인다(판정 영향 없음).
- **기록 쪽**: 단축 경로 기록도 정식 기록과 같은 절차 검사(인덱스·브랜치·모드·HEAD 결속, 시크릿 재스캔, 하네스 뷰)를 지난다.
  전사 없이 기록하는 경로는 원래 허용돼 있었고(`required and not lanes` 조건 — 필수 lane 이 비면 걸리지 않는다), 이번에 실행으로
  확인했다(meta-test FP-a). 추가한 것은 표시와 그 표시의 조건이다 — `via: fast-path` 가 영수증 항목·`procedure`·관측 로그
  record 이벤트에 남고, 그 표시로 온 기록은 필수 lane 이 있거나 SKIPPED·NOT_APPLICABLE 밖의 결과를 보고하면
  `fast-path-not-empty` 로 거부한다(CONTRACT `fast-path-requires-empty-selection`). 모르는 표시 값은 `via-unknown`.
  표시 없이 `'{}'` 로 기록하는 기존 경로는 그대로다 — 표시는 우회를 새로 막는 장치가 아니라 단축 경로 기록을 셀 수 있게 하는
  관측이고, 표시를 단 기록이 빈 선택이라는 것만 보장한다.
- **훅 안내**: 커밋을 막는 deny 본문에 `<설치 루트>/skills/preflight/preflight-fast.sh <repo> commit` 을 채워 넣는다 —
  스킬 문서를 읽지 않은 세션도 부를 수 있게. 설치 루트는 훅이 이미 쓰는 `PF_ROOT` 다.
- **왜**: 정식 절차는 메인 세션에서 스킬 로드 → 분류 → 워크플로 → 기록 → 커밋의 턴을 밟고, 턴마다 그 세션의 컨텍스트 전체를
  다시 읽는다. 선택된 lane 이 없는 커밋은 워크플로가 할 일이 없으므로 그 턴들이 결과를 바꾸지 않는다. 단축 경로는
  (스테이징과 함께) 단축 호출 → 커밋의 두 호출이다. 시크릿 검사 결정론 우선(위)으로 `shell-tool` 처럼 `SECRET_SCAN = 'auto'`
  인 카테고리에서 선택된 lane 이 없는 커밋이 생겼다. 비용 수치는 재현 명령이 이 레포에 없어 싣지 않는다.
- **이번 범위에 넣지 않았다**: PR 게이트(`pr-quality` 가 늘 선택되어 해당 없음), `always` 카테고리(`secret-scanner` 가 늘 선택되어
  해당 없음).
- **어디**: `preflight-fast.sh`(신규), `receipt.sh`(`PF_RECORD_VIA`·`via`·`fast-path-not-empty`·`via-unknown`),
  `hooks/preflight-gate.sh`(deny 안내), `SKILL.md`(맨 앞 3줄·관측 로그 사유), `meta-test/engine.sh`(FP-a~f).
  `ENGINE_VERSION` 2.3 → **2.4**(호환되는 추가 — 새 진입점, 프로필 계약은 그대로).
