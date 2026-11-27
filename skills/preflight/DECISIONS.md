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

## 2026-11-23

### 기록 단계가 시크릿 검사 모드를 다시 구한다

- `receipt.sh record` 가 재스캔(`secret-scan.sh --category <선언 카테고리>`, 루트는 `classify.sh` 와 같은 엔진·오버레이 순서)의 `categoryMode` 로 모드를 다시 구하고(`all` 분류는 always), always 인데 `secret-scanner` 결과가 없거나 SKIPPED·NOT_APPLICABLE 이면, 또는 분류의 `secretScan.mode` 와 다르면 `secret-scan-mode-mismatch` 로 거부한다(백로그 「record 단계가 카테고리의 `SECRET_SCAN` 을 다시 계산하지 않는다」). 한계: 카테고리 **이름**을 위조하면(always 카테고리를 auto 카테고리 이름으로) 그 이름의 규칙으로 구하므로 통과한다 — 소속 재판정은 하지 않았다. 호환 수정이라 `ENGINE_VERSION` 은 그대로. 어디: `secret-scan.sh`(`categoryMode`), `receipt.sh`(CONTRACT `secret-scan-recheck-at-record` (c)), `classify.sh`·`secret-scan.sh`(CONTRACT `secret-scan-mode-rule`), `SKILL.md`, `meta-test/engine.sh`(SS-o).

### flip 측정 실행을 레포에 넣었다 — 헤드리스 세션에 정의를 주입하는 `flip.sh run`

- **무엇**: `eval/flip.sh run <out> [--k=N] [--agent=<lane>=<정의 파일>]... [--model=M] [--jobs=N]` 이 prepare 한 입력마다 결과가
  k 개가 되도록 헤드리스 세션(`${CLAUDE_BIN:-claude} -p`)을 띄워 워크플로를 한 번씩 돌린다. 실행마다 `args.json` 과 고유 `runId` 를
  리터럴로 담은 래퍼 워크플로(`<입력>/run-<i>.wf.js`)를 만들고 세션에는 그 경로만 준다(JSON 을 중계시키면 문자열로 넘어가 워크플로가
  args 를 못 읽었다). `--add-dir` 로 측정 디렉터리와 `preflight.js` 자리를 둘 다 연다(Workflow 는 그 밖의 scriptPath 를 거부한다).
  읽히는 결과는 다시 돌리지 않고(이어 채움), 통과한 결과만 `runs.txt` 에 더한다. `--agent` 는 정의 파일의 frontmatter
  (description·model·tools)와 본문을 `--agents` 로 주입하고 manifest `injected` 에 실경로·sha1 을 남긴다. 이미 다른 정의(또는 주입 없음)로
  돈 디렉터리면 거부한다. `score` 는 주입 lane 의 다이제스트·출처를 주입 파일로 보고하고, 그 lane 에 설치본≠레포 경고를 내지 않는다.
- **왜**: 에이전트 정의는 세션 시작 때 고정된다 — `agents/<lane>.md` 를 고친 세션에서 Workflow 로 돌리면 고치기 전 정의를 재고, 새로 만든
  정의 파일은 그 세션에 보이지 않는다(실측). 지난 전후 측정은 임시 스크립트로 헤드리스 세션에 정의를 주입했는데, 그 스크립트가 레포에
  없었고 manifest 의 `agents` 는 주입한 정의가 아니라 설치본을 기록했다 — 잰 정의와 기록된 정의가 달랐다.
- **치른 값**: 실행마다 헤드리스 오케스트레이터 세션이 하나씩 더 돈다(기본 sonnet — lane 비용에 더해지는 몫). 결과 파일은 그 세션의
  LLM 이 Write 로 옮긴다 — 가공하거나 빼먹을 수 있어, run 은 파일이 JSON 으로 읽히고 `lanes` 가 있는지만 확인하고 내용의 충실성은
  보장하지 않는다. `--agents` 에는 frontmatter 의 `effort` 등 다른 키가 실리지 않는다.
- **어디**: `eval/flip.sh`(`run`, score 의 `injected`), `SKILL.md`(참고 절), `meta-test/engine.sh`(flip run — `CLAUDE_BIN` 스텁, 모델 호출 없음).

## 2026-11-24

### 분류 한 번 — `preflight-run.sh prepare`

- **무엇**: `preflight-run.sh prepare <repo> commit|pr|all [--round=N] [--prior=<파일>] [classify.sh 플래그…]`(신규)가 분류를 한 번
  돌리고 다음 행동을 JSON 한 줄로 낸다. 단축 경로 대상(commit, 플래그는 `--msg-file` 뿐)이고 선택 lane 이 0개면 `via: fast-path`
  기록까지 하고 `action=recorded`, 아니면 데이터 스크립트를 쓰고 `action=workflow` 와 Workflow 에 그대로 넣을 `scriptPath`·`args`
  (`repo`·`mode`·`round`·`classificationScript`·`classificationSha256`, 있으면 `prBodyFile`·`priorFindings`)를 낸다. `--round`·`--prior`
  는 prepare 가 쓰고 `classify.sh` 에 넘기지 않는다. 분류 실패면 stdout 이 비고 그 종료코드로 끝난다.
- **한 벌로 둔 것**: SKILL.md gate-args 블록의 `pf_gate_args` 는 이제 `preflight-run.sh gate-args` 를 부르는 한 줄이다 — 분류 실패 전달·
  `classify-sha256` 필수·데이터 스크립트 쓰기가 스크립트 한 곳에 있다. 블록을 `lib.sh` 로 옮기지 않은 이유: 블록은 메인 세션의 셸에서
  정의되는데 그 셸이 bash 라는 보장이 없고(`lib.sh` 는 `BASH_SOURCE` 에 기댄다), 명령 호출은 셸에 무관하다. 단축 경로의 대상 조건·판정·
  기록은 `lib.sh` 의 `pf_fast_eligible`·`pf_fast_plan`·`pf_fast_record` 로 옮겨 `preflight-fast.sh` 와 prepare 가 같이 쓴다.
- **왜**: 메인 세션 게이트 턴을 단계별로 나눠 보면 `classify.sh` 를 단독으로 돌린 턴과 분류·인자를 다시 만든 턴이 각각 워크플로
  실행 수에 가까웠다(관찰 — 집계 스크립트가 이 레포 밖에 있어 수치는 적지 않는다). 분류 단독 실행 뒤 같은 인자로
  `pf_gate_args` 를 다시 부르면 분류가 두 번 돌고 턴도 두 번 쓴다. prepare 는 그 둘을 한 호출로 합친다.
- **한계**: 턴 수 감소는 아직 재지 않았다 — 같은 집계를 배포 뒤 다시 돌려야 안다. `scriptPath` 의 원본 경로(심링크를 푼
  `preflight.js`)가 세션이 읽을 수 없는 자리면 Workflow 가 거부한다 — `PF_CLS_DIR` 를 주면 그 폴더에 사본을 둔다. 사본은 덮어쓰기라
  같은 폴더를 두 세션이 쓰면 마지막 것이 남는다(내용은 같은 설치본이면 같다). 커밋 훅의 deny 안내는 아직 `preflight-fast.sh` 를 가리킨다.
- **어디**: `preflight-run.sh`(신규), `lib.sh`(`pf_fast_*`), `preflight-fast.sh`(공용 함수 사용), `SKILL.md`(맨 앞·§ 1·§ 2·gate-args 블록),
  `meta-test/engine.sh`(RUN-a~g). `ENGINE_VERSION` 2.4 → **2.5**(호환되는 추가 — 새 진입점, 프로필 계약은 그대로).

### 워크플로 안에서 기록

- **왜**: 게이트가 PASS 면 메인 세션이 워크플로 결과에서 `receiptLanes` 를 꺼내 파일로 쓰고 `receipt.sh record` 를 다시 부르느라
  게이트마다 메인 턴이 더 들었다(관찰 — 집계 스크립트가 이 레포 밖에 있어 수치는 적지 않는다). 메인 턴은 큰 컨텍스트를 다시 읽어
  비싸다. 워크플로 스크립트는 셸을 못 돌리고 파일을 못 쓰며 자기 전사 디렉터리 경로를 모르므로, 기록은 에이전트 하나가 한다.
- **무엇**: `preflight.js` 의 마지막 단계 — 집계 verdict 가 PASS 이고 측정 전용이 아니고 `args.autoRecord !== false` 이면
  haiku·effort low 기록 에이전트(label `record`, `gateAgent` 경유)가 명령 **하나**만 돌린다:
  `bash <engineDir>/receipt.sh record commit|pr <repo> --lanes-b64=<b64> --lanes-sha256=<hex> --transcripts-marker=pf-record:<꼬리>:<16hex>`.
  `engineDir` 은 `classify.sh` 가 분류에 싣는다(새 키). 꼬리는 `args.runId || classification.runNonce`, 16hex 는 분류 바이트 sha256
  (인라인 분류면 분류 객체 직렬화의 sha256) 앞 16자다. 결과에 `recorded: {status: RECORDED|REFUSED|ERROR|SKIPPED, reason, output}` 이
  붙고, RECORDED 면 `next` 가 "record 를 다시 부르지 말고 커밋으로", 아니면 지금까지의 메인 기록 안내다. FAIL·NEEDS_CONFIRM 은
  부르지 않는다 — waiver 는 사용자 승인이라 메인 몫이다. `receipt.sh record` 는 두 옵션을 새로 받는다: `--lanes-b64`+`--lanes-sha256`
  (디코드 바이트 sha256 이 다르면 `lanes-digest-mismatch`), `--transcripts-marker`(설정 루트 `CLAUDE_CONFIG_DIR` 또는 `~/.claude` 의
  `projects/*/*/subagents/workflows/wf_*/agent-*.jsonl` 중 최근 6시간 안에 바뀐 전사에서 표식을 찾아 wf 디렉터리가 정확히 하나일 때만
  쓴다 — 아니면 `transcripts-marker-unresolved`). 표식을 주면 기록 경로 표시가 `via: workflow` 가 되고(로그·영수증), 표식 없이
  `PF_RECORD_VIA=workflow` 는 `via-unknown` 이다. 그 뒤 검사는 위치 인자 형태와 같다.
- **충실도**: lane 결과는 모델이 명령에 옮겨 적으므로 sha256 으로 대조한다 — 분류 적재와 같은 `_sha256Hex`·`_utf8Encode` 로 워크플로가
  계산하고 receipt.sh 가 디코드 바이트로 다시 계산한다(한 글자라도 바뀌면 거부). 옮겨 적기 전에 lane 상태를 바꾸는 위조는 이 대조가
  아니라 기존 전사 검증(`no-lane-evidence`·`concealed-promotion`·`sequence-violated`)이 잡는다 — 표식으로 찾은 디렉터리는 그 워크플로의
  lane 전사가 든 디렉터리다. 기록 시점에 워크플로는 끝나지 않았다: 기록 에이전트 자신은 결과가 없고, 스냅숏·재측정 정리는 집계 전에
  끝나므로 기록이 마지막 에이전트다. 기록·정리 에이전트는 구조화 출력에 `lane` 이 없어 전사 귀속(수락된 `StructuredOutput.lane` 만)에
  들어가지 않는다 — 별도 무시 규칙을 두지 않았고, lane 전사 없이 그 둘만 있는 디렉터리는 그대로 `no-lane-evidence` 다(meta-test WR-d).
- **한계**: 기록 에이전트가 결과를 지어내 RECORDED 로 보고해도(종료코드 0 과 `recorded: ` 줄) 영수증이 없으면 커밋 훅의 verify 가
  막는다 — 그때 메인이 기록하면 된다. 같은 꼬리·같은 분류로 워크플로를 두 번 돌리면 표식이 두 디렉터리에 있어 거부된다(폴백).
  표식의 16hex 를 분류 artifact 와 대조하지는 않는다 — 탐색 키일 뿐이다. base64 가 길어 모델이 옮기다 틀릴 수 있고, 그때는
  `lanes-digest-mismatch` 로 폴백한다. 턴 감소는 아직 재지 않았다. `eval/flip.sh` 실행은 `autoRecord: false` 를 넘겨
  측정 입력 레포에 영수증을 남기지 않는다.
- **폴백**: `recorded.status` 가 RECORDED 가 아니면 지금까지처럼 메인이 `receiptLanes` 를 파일로 써서
  `receipt.sh record … @<lanes.json> "" <Transcript dir>` 로 기록한다(SKILL.md § 4).
- **어디**: `preflight.js`(BEGIN auto-record · CONTRACT `auto-record-pass-only`, 결과 `recorded`), `receipt.sh`(CONTRACT
  `workflow-record-inputs`, via 어휘), `classify.sh`(`engineDir`), `SKILL.md`(§ 4·관측 로그), `meta-test/engine.sh`(WR-a~g).
  `ENGINE_VERSION` 2.5 → **2.6**(호환되는 추가 — 새 옵션·결과 키, 위치 인자 형태는 그대로).

### lane 결과는 전사에서 읽는다 — 기록 명령에서 base64 를 뺐다

- **왜**: 2.6 의 워크플로 안 기록이 PR 게이트에서 매번 `lanes-digest-mismatch` 로 거부돼 메인 기록으로 폴백했다. 2026-11-24
  오버레이 레포 게이트 4회 중 커밋 게이트 1회는 RECORDED, PR 게이트 2회는 REFUSED. 두 거부의 기록 에이전트 전사를 대조하면
  프롬프트의 base64 는 sha256 과 맞았고(3108자·2388자), 에이전트가 명령에 옮겨 적은 값이 달랐다 — 한 번은 1349번째 글자 뒤 201자가
  빠졌고(2907자, 디코드 실패), 한 번은 2164번째 글자부터 바뀌었다(2384자). PR 게이트는 lane 이 여럿이고 `metrics` 가 `reason` 으로 들어가
  lane 결과가 수 KB 다. 커밋 게이트(lane 하나)는 짧아 옮겨 적기가 맞았다. 옮겨 적기 오류는 길이에 따라 늘므로 재시도로 풀리지 않는다.
  재현: 위 전사(`subagents/workflows/wf_*/agent-*.jsonl` 중 `--lanes-b64` 가 든 것)의 첫 user 메시지와 Bash `tool_use` 의 `--lanes-b64=` 값 비교.
- **무엇**: 기록 명령은 `receipt.sh record commit|pr <repo> --lanes-sha256=<hex> --transcripts-marker=<표식>` 이다. base64 는 기록 에이전트
  프롬프트의 `pf-record-lanes=<b64>` 줄에만 싣고, receipt.sh 가 표식으로 찾은 wf 디렉터리에서 첫 user 메시지에 표식이 든 전사를 골라
  그 메시지(런타임이 쓴 프롬프트)의 그 줄을 디코드해 sha256 으로 대조한다. 모델이 옮겨 적는 값은 sha256(64자)·표식·레포 경로뿐이다.
  첫 user 메시지만 입력이다(2026-11-25 「사용자 요청 중계 메시지 뒤의 기록 프롬프트도 읽는다」에서 첫 응답 전 user 메시지로 넓힘) — 에이전트 자신의 도구 호출·출력(뒤 줄)에 쓴 줄은 읽지 않는다. 표식이 든 프롬프트나 그 줄이 하나가 아니면
  `lanes-payload-unresolved`, 출처(표식·`--lanes-b64`) 없이 sha256 만 오면 `lanes-digest-mismatch`. `--lanes-b64` 는 그대로 받는다(2.6 형태).
- **충실도**: 전사는 런타임이 쓴다. 프롬프트 바이트가 곧 워크플로가 계산한 바이트이므로 옮겨 적기 오류가 끼어들 자리가 없다. lane 상태
  위조는 지금처럼 전사 검증(`no-lane-evidence` 등)이 잡는다.
- **전사 형식**: 런타임은 계산된 프롬프트 앞에 `[Workflow harness — computed task] …` 머리말 한 줄을 붙이고 모든 줄을 공백 두 칸
  들여 쓴다(2026-11-24 기록 에이전트 전사 실측). 그래서 payload 줄은 줄 머리 공백을 허용해 찾고, meta-test 스텁도 같은 형태로 쓴다.
- **한계**: 전사 형식(첫 `message.role == "user"` 줄의 문자열 또는 text 블록)에 기댄다 — 형식이 바뀌면 `lanes-payload-unresolved` 로
  폴백한다(게이트가 열리지는 않는다). 실제 PR 게이트에서 RECORDED 가 나는지는 머지 뒤 첫 게이트에서 관찰한다.
- **어디**: `preflight.js`(auto-record `payload`·기록 프롬프트), `receipt.sh`(CONTRACT `workflow-record-inputs`), `SKILL.md`(관측 로그 어휘),
  `meta-test/engine.sh`(WR-h: 긴 lane 결과 + 명령의 긴 값을 망가뜨리는 기록 에이전트 스텁으로 끝-대-끝 RECORDED;
  WR-i: 프롬프트 payload 출처 규칙; WR-j: 명령 길이). `ENGINE_VERSION` 2.6 → **2.7**(호환 — 새 거부 어휘, 2.6 옵션 형태는 그대로).

### 기록 단계가 카테고리 소속을 다시 판정한다

- **왜**: 2026-11-23 「기록 단계가 시크릿 검사 모드를 다시 구한다」는 분류 artifact 가 **선언한** 카테고리 이름의 `rules.py` 로 모드를
  구했다 — 같은 절의 한계대로, always 카테고리(`generic`) 분류의 `category` 를 auto 카테고리 이름(`shell-tool`)으로 바꾸고
  `secretScan.mode` 를 `auto` 로, `secret-scanner` 를 빼면 재스캔이 CLEAN 일 때 기록이 통과했다(meta-test CR-c 가 이 위조를 재현한다).
  카테고리 이름은 시크릿 검사 모드만이 아니라 관례 lane·QA 규칙도 고르므로, 이름을 믿는 한 소속이 바뀐 분류를 기록이 받는다.
- **무엇**: `receipt.sh record` 가 시크릿 재스캔 앞에서(CONTRACT `category-recheck-at-record`) `classify.sh <dir> category` 로 소속을
  다시 판정한다. 커밋 모드는 인덱스 스냅숏(조회의 기본), PR 모드는 새 옵션 `--of=pr` 로 HEAD 스냅숏 — 분류와 같은 스냅숏이다.
  판정 코드는 분류와 같은 경로다(`--of=pr` 는 `MODE=pr` 로 스냅숏·base 해석까지 pr 분류와 같은 줄을 지나고 판정 직후 끝난다).
  카테고리 루트(엔진 다음 오버레이)·프로필 고정·겹침·fallback 규칙도 그대로다. 다시 판정한 카테고리가 선언과 다르면
  `category-mismatch`(로그 `declared`·`rejudged`), 재판정이 exit 3(겹침·적재 실패·프로필 불일치)이거나 실행·출력이 깨지면
  `category-unresolved`(`detail`: `overlap`·`load-failed`·`profile`·`error`)로 거부한다.
- **순서**: 스냅숏 결속(커밋 `index-changed`, PR `stale-head`)이 먼저다. 분류 뒤 다른 카테고리 표식을 스테이징하면 소속도 바뀌지만
  사유는 `index-changed` 다 — 대상이 바뀐 것이 먼저이고, 소속 불일치는 그 결과다(meta-test CR-e, 커밋·PR 둘 다).
- **함께 바꾼 것 — 모드 거부 문구를 원인별로**: `secret-scan-mode-mismatch` 는 사유 코드를 그대로 두고(로그 호환) 사람에게 보이는
  문구와 로그 `detail` 을 원인 코드 목록으로 나눴다 — `lane-missing`(결과 없음 → 재분류), `lane-skipped`(SKIPPED → lane 재실행),
  `lane-not-applicable`(NOT_APPLICABLE → 카테고리 확인 뒤 lane 재실행), `mode-differs`(분류의 mode 가 다시 구한 값과 다름 → 카테고리
  규칙 확인 뒤 재분류). 원인마다 할 일을 한 줄씩 붙이고, 둘 이상이면 모두 싣는다. `detail` 은 원래 사람이 읽는 문장 목록이었는데
  이제 코드 목록이고, 문장은 새 키 `facts` 에 있다. 이 사유로 거부된 실례는 없었다(관찰) — 문구만의 변경이다.
- **치른 값**: 기록마다 카테고리 판정 한 번(파이썬 기동 + `git ls-files`/`ls-tree` + 각 `rules.py` 의 `match`).
  이 레포 체크아웃(추적 파일 117개)에서 10회 실측 중앙값: 커밋 모드 0.120초, PR 모드(`--of=pr`) 0.137초(2026-11-24).
  재현: 레포 루트에서 `bash skills/preflight/classify.sh "$PWD" category [--of=pr]` 를 10회 돌려 벽시계 시간의 중앙값을 낸다.
- **한계**: 재판정은 판정 **입력**(스냅숏)이 같을 때 같은 답을 낸다는 데 기댄다 — 분류와 기록 사이에 `rules.py`·`categories.json`·
  프로필·오버레이 설정이 바뀌면 정직한 분류도 `category-mismatch`·`category-unresolved` 로 거부된다(다시 분류하면 된다).
  설치본 `ENGINE_VERSION` 을 못 읽게 된 경우도 같다 — 프로필이 있으면 재판정이 프로필 결속에서 멈춰 `category-unresolved`
  (detail `profile`)다. 그래서 「엔진 버전 표식」의 기록 불개입은 "기록 자신은 이 값으로 판정하지 않는다" 로 좁혀진다
  (meta-test 「엔진 버전」 절: 프로필 없는 오버레이에서 기록 진행·null, 프로필이 있으면 거부).
  `all` 분류는 커밋 기록으로만 받으므로 인덱스로 판정한다. 카테고리 이름이 아닌 다른 artifact 필드(`selected` 의 관례 lane 등)의
  위조는 이 검사 범위 밖이다.
- **해소**: 2026-11-23 「기록 단계가 시크릿 검사 모드를 다시 구한다」의 한계 문장(카테고리 이름 위조)은 이 절로 닫힌다.
- **어디**: `classify.sh`(category 조회 `--of=commit|pr`), `receipt.sh`(CONTRACT `category-recheck-at-record`, CONTRACT
  `secret-scan-recheck-at-record` (c) 원인 코드), `SKILL.md`(관측 로그 사유·라우팅 표), `meta-test/engine.sh`(CR-a~e, SS-o 원인별 문구),
  `docs/backlog.md`(닫힘 항목에 후속 한 줄). `ENGINE_VERSION` 은 그대로다 — 2026-11-23 절과 같은 종류(위조 경로를 닫는
  호환 강화, 프로필 계약 그대로)라 그 절의 관례를 따랐다.

### Python 테스트를 분류기가 확정한다

- **왜**: `.py` 는 `code-reviewer` 대상(`CODE_EXT`)인데 `test-runner` 는 eslint·tsc·jest 만 돌아, `.py` 변경에서 `test-runner` 가
  `no-testable-file-change` 로 빠졌다 — Python 레포의 테스트는 어느 게이트에서도 돌지 않았다(백로그 「Python 레포의 테스트가 돌지 않는다」).
  관찰: 관측 로그상 `.py` 를 바꾼 게이트 라운드가 있는 레포 중 테스트가 있는 레포는 둘이고 둘 다 표준 `unittest`(TestCase)다 —
  하나는 테스트 파일이 패키지가 아닌 폴더에(`tools/test_*.py`), 하나는 `tests/` 패키지(`__init__.py`)에 있다. 테스트가 없는 Python 레포도 있다.
  그 머신에는 pytest 가 없다. 집계 스크립트가 이 레포 밖에 있어 수치는 적지 않는다.
- **무엇**: 카테고리와 무관한 엔진 공통 규칙(`classify.sh`, 카테고리 `suites` 바로 뒤). 커밋·PR 대상에 `.py` 로직 변경(기존
  `logic_changed` 휴리스틱 — 주석·공백만이면 제외)이 있고 스냅숏에 `test_*.py`·`*_test.py` 가 있으면 `test-runner` 를 고르고 회귀
  명령을 확정한다. 테스트 파일은 **그 파일이 있는 디렉터리**별로 묶는다. 러너는 `_py_runner` 한 함수가 스냅숏 내용으로 정한다 —
  pytest 신호가 하나라도 있으면 pytest: 루트의 pytest 설정(`pytest.ini`, `pyproject.toml` 의 `[tool.pytest…`, `setup.cfg`·`tox.ini` 의
  `[tool:pytest]`·`[pytest]`, 근거 `config`), 스냅숏 어디든 `conftest.py`(`conftest`), 함수형·클래스형 테스트 파일(`function-style`), 파싱 실패 파일
  (`parse-error`). 파일 형은 `_py_test_style` 하나가 **구문 트리(`ast.parse`)** 로 정한다 — 클래스의 베이스는 같은 모듈의 클래스 정의로 따라가
  해소한다(순환 방지) — 끝 이름(Name·Attribute 의 마지막 이름)이 `…TestCase`(`TestCase`·`unittest.TestCase`·`IsolatedAsyncioTestCase` …)에
  닿으면 TestCase 클래스, 베이스가 없거나 `object` 이거나 같은 모듈 안에서 `…TestCase` 없이 끝나면 일반 클래스, 다른 모듈에서 import 한
  베이스처럼 해소할 수 없으면 그 클래스는 근거로 쓰지 않는다(unknown). 모듈 수준 `def test*`·`async def test*` 나 이름이 `Test` 로 시작하는
  일반 클래스(pytest 클래스형)가 있으면 function, TestCase 클래스만 있으면 unittest(`class Base(unittest.TestCase)` + `class TestFoo(Base)`
  포함), 판정할 테스트가 없으면(헬퍼만·해소 불가 클래스만) 판정에서 뺀다, 파싱 실패는 pytest 쪽(0개 실행으로 통과하는 것보다 실패가 낫다).
  해소 불가 베이스만 있는 파일은 다른 신호가 없으면 unittest 로 남는다 — 그 베이스가 TestCase 면 discover 가 실제로 찾아 돈다(py(w)),
  TestCase 가 아니면 0개 실행으로 3.12+ 는 FAIL(exit 5), 그 전 버전은 통과한다(한계). import 문은 근거가 아니고 주석·문자열은 트리에 없다.
  모든 테스트 파일이 unittest 형이고 신호가 없을 때만 unittest 다. unittest discover 는 함수형 테스트를 0개로 센다(3.12+ exit 5 를 test-runner 가 환경
  문제로 오진하기 쉽고, 3.12 미만은 0개로 통과) — 그래서 신호 하나로 pytest 로 기운다. pytest 면 `cd <스냅숏> && python3 -B -m pytest -q -o cache_dir=$(mktemp -d) <dirs>`(2026-11-25 이전 `-p no:cacheprovider`)
  한 개, unittest 면 디렉터리마다 `cd <스냅숏> && python3 -B -m unittest discover -s <dir> [-t <top>] -p 'test_*.py'`(`*_test.py` 만 있으면
  `-p '*_test.py'`). 디렉터리가 패키지(`__init__.py`)면 `__init__.py` 가 이어지는 가장 위 패키지의 부모를 `-t` 로 준다(루트면 `-t .`) —
  import 이름이 패키지 경로가 된다. 다른 디렉터리 a 의 `discover -s a` 가 이미 수집하는 디렉터리(a→d 사이가 모두 패키지, 같은 패턴)는
  명령을 뺀다 — 루트와 패키지 `tests/` 가 함께면 명령 하나다. pytest 인자는 조상이 이미 인자인 디렉터리를 뺀다(비패키지 하위도 수집한다). 이름은 `python-tests`·`python-tests:<dir>`,
  `laneMeta.test-runner.pythonTests` 에 사유(`python-tests — …`)·러너·근거(`why`: `config`·`conftest`·`function-style`·`parse-error`)·설정 파일·함수형·파싱 실패 파일(최대 5개)·디렉터리가 남는다. 테스트가 없으면 아무것도 하지 않는다 —
  `test-runner` 는 지금 사유 그대로다.
- **카테고리 suites 와의 관계**: 대체하지 않고 **더한다**(`suites` 목록에 extend). 엔진 레포(`shell-tool`)는 지금 추적 파일에
  `test_*.py`·`*_test.py` 가 없어(`git ls-files` 0건) 회귀 명령 집합이 그대로다. 그런 파일이 생기면 `meta-test` 와 함께 돈다 — 둘 다
  커밋될 내용을 검사하는 명령이라 겹쳐도 덜 도는 쪽이 아니다.
- **기록 단계**: `suite-not-run` 은 그대로 적용된다 — `marker` 가 명령 문자열 자체(`python3 -B -m unittest discover …`)라서
  `receipt.sh` 의 `_ran_script` 가 전사에서 그 문자열이 명령 자리에 왔는지 센다(`cd <경로> && ` 뒤, `/usr/bin/` 같은 경로 접두, 뒤의
  `2>&1 | tail` 은 허용). 패턴·플래그를 바꿔 돌리면 확정된 명령의 실행이 아니다. `receipt.sh` 는 고치지 않았다.
- **프롬프트**: Python 전용 레포는 package.json 이 없어 `tscOnly=True` 다. `preflight.js` 가 그 값으로 "실행 가능한 테스트가 없다 —
  `tsc --noEmit` 만" 을 회귀 명령과 함께 내면, lane 이 그 문장을 따라 회귀 명령을 건너뛰고 기록이 `suite-not-run` 으로 거부된다. 그래서
  변이 하네스가 아닌 회귀 명령이 하나라도 있으면 그 문장을 내지 않는다(`tscOnly` 는 jest 기준선일 뿐이다). 분류기에서 Python 블록만
  `tscOnly` 를 안 세우는 방법은 고르지 않았다 — shell-tool 카테고리 suites 도 같은 `setdefault` 로 엔진 레포(package.json 없음)에 같은 충돌을
  만들고, 프롬프트 한 곳에서 막으면 두 경로가 같이 닫힌다. pytest 명령은 `-B` 와 스냅숏 밖 캐시 폴더(2026-11-25 「pytest 캐시는 실행마다 새 임시 폴더에」)로 스냅숏에 `__pycache__`·`.pytest_cache`
  를 쓰지 않는다(unittest 경로의 `-B` 와 같다).
- **test-runner**: 회귀 명령을 글자 그대로 돌리고 종료 코드·마지막 요약 줄을 보고한다. 명령을 돌리지 못하면(예: `No module named pytest`)
  다른 회귀 명령과 같이 FAIL 이다 — reason 에 원인이 환경임과 해결(pytest 설치)을 적는다. `Ran 0 tests`·`NO TESTS RAN`·`no tests ran` 은
  테스트를 찾지 못한 것으로 FAIL, reason 에 0개 실행과 분류기 판정 근거를 적는다 — 환경 문제로 쓰지 않는다(`agents/test-runner.md` 0.8).
- **해소 — 최상위로 묶던 첫 판**: 처음에는 최상위 디렉터리별로 묶었는데, unittest discover 는 `-s` 아래를 패키지로만 내려가
  `skills/preflight/test_m.py` 같은 비패키지 중첩 테스트를 `-s skills` 로 0개 실행했다(Python 3.12+ 는 exit 5 `NO TESTS RAN` 으로 매
  게이트 FAIL, 그 전 버전은 0개로 통과 — 커밋 게이트 리뷰가 재현). 묶는 단위를 테스트 파일의 디렉터리로 바꿔 해소했다. 회귀 단언은
  확정 명령을 픽스처에서 실제로 돌려 `Ran N tests` 의 N≥1 까지 본다(py(h)~(j)). 같은 리뷰가 함수형 테스트·conftest 만 있는 레포도 unittest 로 떨어져 0개 실행되는 경로를 짚어, 러너 선택을
  위 `_py_runner` 로 넓혔다(py(l)~(o)). 그 첫 판은 파일 형을 정규식(`import unittest`·`TestCase` 문자열)으로 봐서
  `from unittest.mock import patch` 를 쓰는 pytest 함수형 파일을 unittest 형으로 세 0개 실행했다(3.14 에서 exit 5 재현) — 정규식 휴리스틱이
  입력마다 다르게 틀려, 판정을 구문 트리로 바꿨다(py(p)~(u)). 구문 트리 첫 판은 베이스 끝 이름만 봐서 같은 모듈의
  `Base(unittest.TestCase)` 를 상속한 `TestFoo(Base)` 를 pytest 클래스형으로 세 순수 unittest 레포에 pytest 명령을 확정했다 — 베이스를 같은
  모듈 안에서 해소하고, 해소 불가는 근거에서 빼게 좁혔다(py(v)~(x)).
- **한계**: pytest 설정은 스냅숏 **루트**만 본다. 기준선 비교는 없다(다른 회귀 명령과 같이 하나라도 실패하면 FAIL).
  pytest 로 판정된 레포(설정·conftest·함수형)에서 그 파이썬에 pytest 가 없으면 게이트가 막힌다 — 의도다. `preflight.js` 의 회귀 명령 지시("돌리지 못했으면
  그것도 FAIL")를 따라 fail-closed 로 두었고, 해결은 pytest 설치다(test-runner 는 reason 에 환경 원인과 해결을 적는다).
- **인터프리터 전제**: 확정 명령은 `python3` 를 경로 없이 부른다 — lane 의 셸이 물려받은 `PATH` 에서 먼저 찾은 `python3`(보통 시스템
  파이썬)다. venv·uv·poetry 같은 가상환경을 감지하지 않는다. 의존성을 가상환경에만 둔 레포는 테스트 모듈 import 가 실패해 FAIL 이다(fail-closed,
  pytest 부재와 같은 취급) — 해결은 그 의존성을 그 `python3` 에 설치하거나 가상환경을 활성화한 셸에서 Claude Code 를 띄우는 것이다.
  감지를 넣지 않은 이유: 지금 게이트를 지나는 Python 레포의 테스트는 표준 라이브러리만 쓴다(관찰). 감지 규칙(`.venv/bin/python`·`uv.lock`·
  `poetry.lock` 중 무엇을 어떤 순서로 믿을지)은 그런 레포가 생겼을 때 그 레포의 구성을 보고 정한다. 그때 확정 명령 문자열이 바뀌므로
  `receipt.sh` 의 `suite-not-run` 대조는 새 문자열을 그대로 따른다.
- **어디**: `classify.sh`(Python 테스트 블록), `preflight.js`(test-runner 프롬프트의 tsc 만 문장), `agents/test-runner.md`(0.8), `SKILL.md`(lane 표 한 줄), `docs/backlog.md`(닫힘),
  `meta-test/engine.sh`(「Python 테스트」 절 py(a)~(y)). `ENGINE_VERSION` 2.7 → **2.8**(호환되는 추가 — 새 회귀 명령·laneMeta 키,
  프로필 계약 그대로).

## 2026-11-25

### 사용자 요청 중계 메시지 뒤의 기록 프롬프트도 읽는다

- **왜**: 사용자 메시지로 시작한 턴에서 띄운 게이트 워크플로는 집계가 PASS 여도 워크플로 안 기록이
  `lanes-payload-unresolved` 로 거부됐다. 그 턴이면 런타임이 기록 에이전트 전사에 `[Workflow harness — user request]` 로 시작하는
  사용자 요청 중계 user 메시지를 프롬프트 **앞에** 쓰고, 표식과 `pf-record-lanes=` 가 든 프롬프트는 두 번째 user 메시지가 된다.
  `receipt.sh` 는 첫 user 메시지만 읽어 표식이 든 프롬프트를 찾지 못했다(거부 사유 `lanes-payload-unresolved`). 알림으로 시작한 턴의 워크플로는 중계 메시지가 없어 통과했다 —
  같은 날 같은 브랜치의 커밋 게이트(사용자 턴)는 거부, PR 게이트(알림 턴)는 `via workflow` 기록. 거부는 fail-closed 라 메인 기록 폴백이
  있었지만, 사용자 요청으로 시작한 게이트마다 메인 기록 턴이 되살아났다.
- **무엇**: 런타임 입력을 "첫 user 메시지" 에서 "에이전트가 처음 응답하기 전의 user 메시지들" 로 넓혔다. 그중 **표식이 든 메시지**에서만
  payload 를 읽는다 — 중계 메시지는 사용자가 친 글이라 표식이 없고, 거기 `pf-record-lanes=` 줄이 있어도 받지 않는다. 첫 응답(assistant 메시지,
  `tool_use`·`tool_result` 블록) 뒤의 줄은 여전히 입력이 아니고, 표식이 든 프롬프트·payload 줄이 하나일 때만 받는 규칙도 그대로다.
  중계 메시지의 머리말 문자열에 기대지 않는다 — 런타임이 머리말을 바꿔도 순서(응답 전/후)로 가른다.
  입력은 상위 `type` 이 `user` 인 행만 센다 — 런타임은 첫 응답 전에도 `api-request-blob` 행(role user)에 요청 사본을 실어 프롬프트가 한 번 더
  나온다. 첫 수정본은 이 행까지 세 같은 실제 전사를 "표식이 든 프롬프트 둘" 로 거부했다 — 합성 픽스처로는 통과했고, 거부된 실제 전사에
  같은 기록 명령을 다시 돌려 찾았다. 그 전사로 수정본을 돌리면 `via workflow` 로 기록된다.
- **회귀**: `meta-test/engine.sh` WR-k — 실제 전사의 행 순서(중계 메시지 · 프롬프트 · attachment · `api-request-blob` · 첫 응답)로 만든 픽스처에서
  기록되고, 중계 메시지에만 payload 가 있으면 `lanes-payload-unresolved`. 수정 전 `receipt.sh` 와 부가 행을 세던 첫 수정본 모두 WR-k 가 실패한다.
- **어디**: `receipt.sh`(CONTRACT `workflow-record-inputs`), `preflight.js`(주석). `ENGINE_VERSION` 은 그대로(입력 계약을 고친 결함 수정 —
  새 플래그·키 없음).

### 회귀 명령이 있어도 jest 건너뜀은 알린다

- **왜**: 2.8 에서 회귀 명령(Python 테스트·meta-test 등)이 확정되면 "실행 가능한 테스트가 없다 — `tsc --noEmit` 만" 문장을 통째로
  뺐다(「Python 테스트를 분류기가 확정한다」 프롬프트 항). 그 결과 jest 테스트가 없는 `package.json`(`tscOnly=True`)과 회귀 명령이 함께인
  레포에서는 jest 를 건너뛰라는 안내까지 사라져, lane 이 jest 를 돌려 테스트를 찾지 못한 실패를 만들 수 있었다(2.8 PR 리뷰의 비차단 지적).
- **무엇**: `tscOnly` 면 언제나 jest 건너뜀을 알린다. 변이 하네스가 아닌 회귀 명령이 있으면 "jest 로 돌릴 테스트가 없다 — jest 는 건너뛴다고
  명시해라. 아래 회귀 명령은 그대로 돌린다", 없으면 지금 문장 그대로다.
- **회귀**: `meta-test/engine.sh` py(z) — `{"name":"x"}` package.json + TS 파일 + unittest 테스트가 있는 레포의 `.py` 변경에서 새 문장과
  회귀 명령이 함께 나가고 "실행 가능한 테스트가 없다" 는 나가지 않는다. py(y) 두 단언은 그대로다.
- **어디**: `preflight.js`(test-runner 프롬프트), `meta-test/engine.sh`. `ENGINE_VERSION` 은 그대로(프롬프트 문구 — 계약·키 변화 없음).

### pytest 캐시는 실행마다 새 임시 폴더에

- **왜**: 2.8 의 pytest 확정 명령은 스냅숏에 `.pytest_cache` 를 쓰지 않으려고 `-p no:cacheprovider` 로 캐시 플러그인을 껐다. 그 플러그인이
  pytest 내장 `cache` 픽스처를 제공하므로, 그 픽스처를 쓰는 테스트는 게이트에서 `fixture 'cache' not found` ERROR 로 막혔다(2.8 PR 리뷰의
  비차단 지적). pytest 9.2.0 으로 `def test_c(cache)` 픽스처를 돌려 재현했다 — 옛 명령 `1 error`, 새 명령 `1 passed`, 두 경우 모두 테스트 폴더에
  `.pytest_cache` 가 생기지 않았다.
- **무엇**: 확정 명령을 `python3 -B -m pytest -q -o cache_dir=$(mktemp -d) <dirs>` 로 바꿨다. 캐시는 실행마다 새로 만든 스냅숏 밖 임시 폴더에
  쓴다 — 스냅숏에는 아무것도 남지 않고(같은 스냅숏에서 도는 다른 회귀 명령에 섞이지 않는다), 앞 실행의 캐시 값이 테스트에 새지 않는다.
  `-o` 는 레포 설정의 `cache_dir` 보다 우선한다. 임시 폴더는 지우지 않는다(실행마다 작은 폴더 하나 — OS 임시 폴더 정리에 맡긴다).
- **기록 단계**: marker 가 명령 문자열 자체라 `$(mktemp -d)` 도 글자 그대로 대조한다. `receipt.sh` 는 고치지 않았다 — py(f2) 가 치환이 든 명령의
  실행을 기록하고, 옛 `-p no:cacheprovider` 명령은 `suite-not-run` 으로 거부하는 것을 본다.
- **어디**: `classify.sh`(pytest 명령), `meta-test/engine.sh`(py(c)·py(l)·py(m)·py(o) 기대 문자열, py(f2)), `agents/test-runner.md`, `SKILL.md`,
  `docs/backlog.md`(닫힘 항목의 명령). `ENGINE_VERSION` 은 그대로(확정 명령 문자열만 바뀜 — 키·계약 그대로).

### 카테고리 규칙 훅을 엔진 스위트가 직접 본다

- **왜**: 엔진 카테고리(shell-tool·generic)는 규칙 훅 대부분을 두지 않는다. 그래서 훅을 거쳐야 드러나는 엔진 동작 — vault 문서 판정(`vault_docs`),
  mode=all 강제(`ALL_MODE_FORCED`), 의존성 줄 패턴(`DEP_KEY_EXTRA`), 관례 판정(`convention`), 등록 조회와 vault 위치(`vault_link`·`vault_dir_fallback`),
  vault-sync 선택(`VAULT_SYNC`), QA 메타(`qa_meta`), QA 안내(`QA_HINT`) — 은 그 훅을 가진 오버레이 카테고리 스위트에서만 검사됐다. 엔진만 돌리면
  `classify.sh` 의 훅 호출을 지워도 초록이었다(docs/backlog.md 「엔진 단독 스위트에 조직 카테고리 의존 단언이 없다」).
- **무엇**: `meta-test/engine.sh` 에 테스트 전용 오버레이를 임시 디렉터리에 만드는 절을 더했다. 카테고리는 둘이다 — `fixture-hooks`(표식 `.fixture-hooks`,
  훅 전부)와 `fixture-bare`(표식 `.fixture-bare`, match 만). 같은 변경을 두 카테고리 레포에서 분류해, 훅 값(전부 `fh-` 로 시작)이 lane 선택·laneMeta·
  vaultLink·qa 사유·files 에 그대로 실리는지와 훅이 없을 때 엔진 기본값(`no-vault-doc-change`·카테고리 비해당 사유·`NOT_APPLICABLE`)으로 남는지를 본다.
  vault 는 로컬 디렉터리 둘(등록 노트 있음·없음)이고 네트워크를 쓰지 않는다. 분류기는 `config.json` 을 뺀 엔진 사본(파일 단위 심링크)으로 돌린다 —
  설치본 `config.json` 에 `vaultDir` 가 있으면 `vault_dir_fallback` 에 닿지 않는다. `classify.sh` 동작은 바꾸지 않았다.
  `SECRET_SCAN`·`SECRET_SENSITIVE_EXTRA` 는 「결정론 시크릿 스캔」 절(SS-a·SS-d)이 이미 오버레이 픽스처로 본다. `suites` 도 shell-tool 이 갖지만,
  카테고리 회귀 명령이 코드 변경 없이 test-runner 를 고르는 경로를 함께 본다(CH-i).
- **회귀**: `meta-test/engine.sh` 「카테고리 규칙 훅 → 엔진 동작」 CH-a~CH-i 22개. 단언마다 `classify.sh` 의 해당 훅 사용을 깨뜨려(훅 결과 버림·무시,
  훅이 없을 때의 기본값 변경, VAULT_DIR·폴백 순서 뒤집기) 그 단언이 실패하는 것을 확인하고 되돌렸다.
- **어디**: `meta-test/engine.sh`(새 절), `docs/backlog.md`(닫힘으로 옮김). `ENGINE_VERSION` 은 그대로(테스트만 — 계약·키 변화 없음).

### 스냅숏 체크아웃의 HEAD 해시가 다른 것은 정상이라고 알린다

- **왜**: snapshot.sh 는 기준 커밋(또는 커밋될 인덱스)의 트리로 `commit-tree` 커밋을 새로 만들어 체크아웃하고, 체크아웃의 `HEAD^{tree}` 를 그 트리와
  대조한다. 내용은 같지만 HEAD 해시는 기준 커밋과 늘 다르다. 프롬프트가 기준 커밋 해시만 주니 lane 이 HEAD 를 비교해 기준선을 버리거나 의심했다 —
  측정(2026-11-18 「측정 입력을 6개 더했다」 `node-baseline-broken-clean`)에서 두 모델 각 1/5, 실제 게이트에서도 test-runner FAIL 중
  "체크아웃 HEAD 가 기준 커밋과 달라 기준선 미실행"·"기준선 HEAD 가 프롬프트의 기준과 다르다(확인 필요)" 가 나왔다(관찰 — 전 세션 워크플로
  journal 의 test-runner FAIL 사유를 훑어 찾았다).
- **무엇**: 기준선 수집 프롬프트와 test-runner 의 기준선 줄에 "HEAD 해시가 다른 것이 정상 — 내용은 기준 커밋의 트리(트리 id 앞 12자)이고
  snapshot.sh 가 대조했다 — HEAD 차이로 기준선을 버리거나 의심하지 마라" 를 넣었다. 대상 스냅숏 블록에도 HEAD 가 원본 커밋 해시와 다른 것이
  정상이라는 한 문장을 더했다.
- **회귀**: `meta-test/engine.sh` 변이 절의 스텁 프롬프트에서 baseline·test-runner 프롬프트가 그 문장을 싣는지 본다.
- **어디**: `preflight.js`(BASE_HEAD_NOTE, snapshot-block), `meta-test/engine.sh`, `docs/backlog.md`(닫힘). `ENGINE_VERSION` 은 그대로(프롬프트 문구).

### flip manifest 의 harness 를 엔진 체크아웃에서 잰다

- **왜**: `eval/flip.sh` 의 lane 측정·재측정 manifest 는 `harness`(엔진 커밋)·`harnessDirty` 를 스크립트 디렉터리 기준 REPO 에서 쟀다. 파일 단위
  링크·복사 설치에서는 그 자리가 설치 루트라 체크아웃이 아니어서, 커밋이 빈 문자열·변경이 false 로 남았다 — 어느 엔진으로 잰 측정인지 manifest 가
  말하지 못했다(docs/backlog.md 「manifest 의 `harness`·`harnessDirty` 가 …」). 격리 회귀 실행도 같은 설치 형태라 빈 값이었다.
- **무엇**: 두 구간 모두 `engine_checkout()`(PF_ENGINE_REPO, 아니면 flip.sh 실경로의 체크아웃 — 설치 루트는 제외)에서 잰다. 그 경로가 git 작업 트리의
  최상위가 아니면 둘 다 null 이다. 재측정 구간에도 같은 함수를 두고 FLIP_FILE 을 넘긴다. 쓰지 않게 된 REPO 정의는 지웠다. 함께
  `PF_AGENTS_DIR` 주석을 고쳤다 — 이 변수는 **해시할 자리만** 바꾸고 워크플로가 읽는 정의는 바꾸지 않으므로 세션이 실제로 읽는 agents 디렉터리를
  줘야 한다(docs/backlog.md 「`PF_AGENTS_DIR` 설명이 …」).
- **회귀**: `meta-test/engine.sh` — flip prepare·remeasure-prepare 의 manifest `harness` 가 flip.sh 실경로 체크아웃의 HEAD 와 같다.
- **어디**: `eval/flip.sh`, `meta-test/engine.sh`, `docs/backlog.md`(두 항목 닫힘). `ENGINE_VERSION` 은 그대로(측정 도구 — 게이트 계약 무관).

### 수정 커밋이 없으면 영향도는 측정 불가

- **왜**: `profile-measure.sh` 의 영향도 축은 제목이 `FIX_RE`(conventional `fix`·`hotfix`·`revert`·`Revert "`)에 맞는 커밋만 수정 커밋으로 센다.
  conventional 제목을 쓰지 않는 레포에서는 수정 커밋이 하나도 잡히지 않아 영향도가 0% 로 나왔고, 표에서 "미선택 뒤 결함 없음" 으로 읽혔다
  (docs/backlog.md 「프로필 영향도가 커밋 제목 형식에 기댄다」). 같은 날 실측(같은 항목)에서 "같은 파일 재수정" 을 수정 커밋 대용으로 쓰는
  후보는 커밋 대부분이 해당해 기각했다.
- **무엇**: 재생한 커밋 중 수정 커밋 제목이 0개면 후보마다 `impact.measurable=false`·비율 null 로 두고 `means` 에 "0 은 수정 없음이 아니다" 를 적는다.
  출력 최상위에 `fixCommits`(그 개수)를 싣고, 조정 근거(evidence)에도 측정 불가를 적는다. 표의 영향도 칸은 `측정 불가(수정 커밋 0)` 이고 표 아래에
  안내 줄이 붙는다. 수정 커밋이 하나라도 있으면 지금과 같다. 생성기 스킬 문서의 축 설명에 한 줄을 더했다.
- **회귀**: `meta-test/profile-measure.sh` PM6b — 자연어 제목 이력에서 측정 불가 표시, 수정 커밋이 있는 이력은 그대로.
- **어디**: `profile-measure.sh`(measure·table), `skills/harness-profile/SKILL.md`, `meta-test/profile-measure.sh`, `docs/backlog.md`(닫힘).
  `ENGINE_VERSION` 은 그대로(실측 출력에 키를 더했을 뿐 — 프로필 계약 무관).

### 우회는 커밋·PR 생성 명령 앞의 할당 자리에서만 인정한다

- **왜**: 훅은 명령 문자열 **어디에서든** 우회 변수의 할당 글자(`<변수>=<사유>`)를 찾아, 4자 이상이면 게이트 없이 통과시켰다. 커밋 메시지·히어독 본문·
  주석이 그 글자를 설명만 해도, 또는 같은 명령줄의 다른 명령 앞에 붙어 있어도 그 커밋이 우회됐다. 오버레이 백로그에 "우회 탐지가 커밋 메시지
  본문에도 걸린다 — 과탐(fail-closed)이라 급하지 않다" 로 남아 있었는데, 2026-11-25 트리아지에서 실제로는 **통과 쪽으로 열린다**는 것을 임시
  로그로 재현했다(메시지 안 글자 → `outcome: bypassed`). 우회 자체는 사유를 붙여 쓰는 탈출구라 권한이 넓어지는 것은 아니지만, 의도하지 않은
  커밋이 조용히 게이트를 건너뛴다.
- **무엇**: 우회 할당을 **명령 전체의 맨 앞**에서만 본다. 앞머리로는 `cd <경로> &&` 하나와 `env` 접두, 다른 환경변수 할당만 허용하고, 할당 바로 뒤가
  게이트가 지키는 호출 자체(`git [-C 경로] commit`·`gh pr create`)여야 한다. 사유 검사(4자 이상, 형식적 값 거부)는 그대로다. 그 밖의 자리의 글자는
  우회도 사유 없는 우회 거부도 아니고 평소 판정(영수증 검증)으로 간다. 첫 판은 따옴표·히어독 본문·주석 밖의 "명령 시작 자리" 를 문자 단위로 찾는
  스캐너였는데, 커밋 게이트 리뷰가 큰따옴표 안 명령 치환(`"$(cat <<'EOF' … )"`, 이 하네스의 표준 커밋 메시지 형태)의 본문에 짝 없는 `"` 하나만
  있어도 따옴표 상태가 뒤집혀 본문의 `(`·줄바꿈 뒤가 명령 시작으로 읽히고 우회가 되는 것을 재현했다. 셸 문법 흉내는 또 다른 갈래를 남기므로 맨 앞
  고정으로 바꿨다 — 뒤의 메시지·본문은 판정에 들어오지 않는다. 같은 리뷰가 짚은 "다른 git·gh 호출 앞의 할당"(`… git status; git commit`)도 함께 닫힌다.
- **회귀**: `meta-test/engine.sh` 「우회에는 사유가 필요하다」 — 메시지(큰·작은따옴표)·히어독 본문·명령 치환 안 짝 없는 따옴표·다른 명령 앞·주석·
  다른 git/gh 호출 앞의 글자는 `bypassed` 가 남지 않고, `cd … &&` 뒤·`env` 뒤 할당은 여전히 `bypassed`. 수정 전 훅으로는 앞의 여덟이 모두 `bypassed` 로 통과했다.
- **어디**: `hooks/preflight-gate.sh`(우회 판정), `meta-test/engine.sh`. `ENGINE_VERSION` 은 그대로(문서화된 우회 형태는 그대로 통한다).

## 2026-11-26

### 한 호출 안의 여러 커밋·`GIT_` 환경변수·중첩 셸 안 커밋을 거부한다

- **왜**: 훅의 대상 레포 해석 재료(`C_DIR`·`CD_DIR`)는 한 커밋 호출에서만 나온다. 세 형태가 그 해석을 빠져나갔다
  (docs/backlog.md 「한 명령 안의 커밋 호출은 첫 번째 하나만 판정된다」·「환경변수·중첩 셸로 대상 레포를 바꾸는 커밋은 거부되지 않는다」).
  ① 같은 호출의 둘째 커밋(`git -C /a commit && git -C /b commit`, 따옴표 친 `"git"`, `cd` 로 갈아탄 둘째 커밋)은 첫 호출의 영수증으로 판정됐다.
  ② `GIT_DIR`·`GIT_WORK_TREE`·`GIT_INDEX_FILE`·`GIT_CONFIG_*` 할당은 `-C` 만 있는 정상 커밋으로 읽혀 `-C` 레포의 영수증으로 통과하고 커밋은 다른 곳에 들어갔다.
  ③ `bash -c '…commit…'`·`eval "…commit…"` 은 따옴표 안이라 커밋으로 보지 않아 판정 자체가 없었다.
  2026-09-14 에 전역 옵션을 받는 쪽으로 넓히다 7라운드를 돌고 되돌린 경위가 있어, 2026-11-12 `commit-global-option` 과 같이 **넓히지 않고 거부**한다.
- **실측(2026-11-01~26, 한 개발 머신의 세션 전사)**: 커밋이 든 Bash 호출 869건 중 커밋 호출 2개 이상 26건 — 그 26건을 직전 훅으로 재생하면 모두
  다른 사유로 이미 거부됐다(새 거부가 정상 사용을 막지 않는다). 커밋 앞 `GIT_` 접두 할당 4건은 전부 작성자·날짜 변수, 중첩 셸 안 커밋 0건.
- **무엇**: `commit_verdict` 가 명령 전체(토큰 판정 줄과 토큰화 실패 줄의 GITPOS 폴백 합산)를 한 번 훑어 세 사유를 낸다.
  - `commit-multiple` — 커밋 호출이 2개 이상. 호출마다 레포를 따로 풀어 영수증을 여럿 검증하는 쪽은 `cd` 해석을 호출마다 다시 하게 되어 같은 함정을 부른다.
    안내: 커밋마다 별도 호출, 픽스처 레포를 여러 번 커밋하는 스크립트는 파일로.
  - `commit-git-env` — 커밋 호출보다 앞(이전 줄 포함)에 `GIT_` 로 시작하는 할당 토큰이 있다(맨 앞·`env` 뒤·`export` 뒤 모두 — 토큰 자리를 가리지 않는다).
    **화이트리스트**로 `GIT_AUTHOR_{NAME,EMAIL,DATE}`·`GIT_COMMITTER_{NAME,EMAIL,DATE}` 여섯만 받는다. 이 여섯은 커밋 객체의 메타데이터만 바꾸고 대상 레포·
    인덱스·설정을 바꾸지 않으며, 실사용 4건이 전부 이것이다. `GIT_` 변수는 git 버전마다 늘어나므로(`GIT_CONFIG_PARAMETERS`·`GIT_CONFIG_GLOBAL` 등)
    위험한 쪽을 열거하면 새 변수가 빠져나간다.
  - `commit-nested-shell` — 셸 단어 `sh|bash|zsh|dash|ksh|fish|csh|tcsh`(경로 붙은 것 포함)나 변수 확장 하나뿐인 명령 단어(`$SHELL`·`"$BASH"`·
    `${X}` — 무엇이 실행될지 정적으로 모른다) 뒤 같은 단순 명령(다음 구분자까지)에 짧은 옵션 묶음에
    `c` 가 든 토큰(`-c`·`-lc`·`-ec`)이 하나라도 있으면, 그 뒤 **남은 인자 전부**를 하나씩 다시 토큰화해 커밋 호출(또는 다시 중첩된 커밋)이 있다.
    `eval` 은 뒤 인자를 이은 글을 같은 방식으로 본다. 깊이 상한 3, 상한에 닿은 글은 `git … commit` 글이 있으면 중첩 커밋으로 본다.
    옵션을 하나씩 해석하지 않는다 — 첫 판은 옵션 뒤 첫 인자 하나만 골라 `bash -c -- '…'`(`--` 를 명령 문자열로 집음)과 `bash --rcfile X -c '…'`
    (값 받는 긴 옵션에서 멈춤)을 놓쳤다(커밋 게이트 리뷰가 재현). 고르는 쪽은 셸·옵션마다 명령 문자열 자리가 달라 매번 한 갈래를 놓친다.
    토큰화가 안 되는 줄(여러 줄 인자)은 c 옵션 뒤 인자 글을 단순 명령 끝까지 모은다 — 따옴표 인자는 짝 따옴표까지(줄을 넘어도), 맨 인자는 공백까지,
    따옴표 밖 `;&|()`·줄바꿈에서 멈춘다. 그 글에 `git … commit` 이 있으면 중첩 커밋이다. 그 전 판은 명령 끝까지 봐서 따옴표 히어독 본문 안
    `eval "$(…)"` 뒤의 진짜 커밋 하나를 중첩으로 오인했다(재생 1건).
  - 겹치면 형태(`commit-global-option`·`commit-unparsed`) → 여러 커밋 → 중첩 셸 → `GIT_` 환경변수 순으로 하나를 낸다. 셋 다 경로 해석과 우회 판정보다 앞이다.
  - **히어독 본문을 따로 빼지 않는다.** 모든 줄을 명령 줄로 센다 — 커밋 호출 개수·중첩 셸·전역 옵션·해석 불가·`GIT_` 환경변수 판정 모두.
    대가는 메시지 글 과탐이다: 커밋 메시지(여러 줄 `-m`, `-m "$(cat <<'X'`, `-F - <<'X'`) 본문에 `git commit`·`bash -c 'git commit'`·
    `eval git commit` 글이 있으면 `commit-multiple`·`commit-nested-shell` 로 막힌다. 우회는 메시지를 파일로 써서 `-F <파일>` 로 넘기는 것이고,
    두 거부 문구가 그렇게 안내한다.
    경위: 따옴표 구분자 히어독 본문을 개수(와 중첩 판정)에서 빼는 규칙을 다섯 판 거쳤고 다섯 번 다 뚫렸다 — 셸 따옴표·실행 문맥을 줄 글 정규식으로
    흉내 내는 한 그 흉내를 속이는 형태가 나왔다. ① 본문 전체를 판정에서 건너뜀 → 따옴표 없는 본문의 `$(git --git-dir=… commit)`·가짜 히어독 뒤
    `--git-dir` 커밋이 `commit-global-option` 없이 통과. ② 개수만 빼고 같은 줄 셸 단어(`(?=\s|$)`)면 셈 → `| bash; true`·`(… | bash)`·`> >(bash)`·
    줄잇기의 `| bash` 를 놓침. ③ 실행 형태 금지 목록 → `bash<<'X'`·`cat <<'X' >f; f` 를 놓침. ④ 메시지 전달 두 꼴만 받는 화이트리스트 →
    `-m "$(cat <<'X' >f; chmod +x f; f; …` 처럼 토큰 뒤에서 실행하는 형태를 놓침. ⑤ 토큰 뒤 공백 조건까지 넣은 판 → 작은따옴표 안
    `'$(cat <<'X'`·`'x -F - <<'X'` 가짜 히어독 뒤 둘째 커밋이 개수에서 빠짐(PR 게이트 리뷰). 셋은 커밋 게이트 리뷰, 둘은 PR 게이트 리뷰가 재현했다.
    사용자 결정으로 제외 장치(`uncounted_lines`·`message_opener` 등)를 통째로 지웠다.
  - 판정기(python)가 예외로 죽으면 훅은 exit 0 으로 침묵한다. 그래서 판정 중 예외는 명령에 `git … commit` 글이 있으면 `commit-unparsed` 로 거부한다.
    첫 판은 `git --git-dir=X commit` 에서 IndexError 로 죽어 세 형태가 통과했고, 기존 「전역 옵션」 단언 3개가 잡았다.
- **줄잇기**: 판정을 두 번 낸다 — 원문 그대로, 그리고 홀수 개 백슬래시+줄바꿈을 합친 글 — 그리고 엄격한 쪽을 쓴다(형태 거부는 어느 쪽이든,
  커밋 수는 큰 값, 중첩·`GIT_` 환경변수는 OR, 첫 호출의 `-C` 값은 원문 것). 합친 판정을 원문 판정에 더하기만 하는 것은 셸의 주석·따옴표 안
  줄잇기 규칙을 흉내 내지 않기 위해서다. 원문만 보면 `bash -c \⏎'…'`·`bash \⏎-c '…'`·`eval \⏎'…'` 의 인자가 다음 줄로 넘어가 중첩 셸·여러 커밋
  판정을 빠져나갔고(PR 게이트 리뷰), 합친 글만 보면 짝수 개 백슬래시(`echo a\\⏎`)나 주석 안 `\⏎`(`… # note \⏎`) 가 다음 줄 커밋을 앞 단어·주석에
  붙여 삼켰다(커밋 게이트 리뷰 두 번). 중첩 셸 인자 글도 같은 두 판정을 거친다. 경로 해석용 STRICT 정규식(명령 전체)은 그대로다.
- **한계**: 중첩 셸은 셸 단어 여덟(`sh|bash|zsh|dash|ksh|fish|csh|tcsh`)·변수 확장 명령 단어의 c 옵션 인자와 `eval` 만 본다. 문자열을 명령으로
  실행하는 그 밖의 것 — `su -c`·`script -c`·`xargs`·`python3 -c 'os.system(…)'`·`ssh host '…'`·`bash <<<` — 은 보지 않는다.
  c 옵션이 있는 셸 호출은 그 뒤 인자 전부를 보므로 `bash -c 'echo $0' 'git commit'` 처럼 명령 문자열이 아닌 인자의 커밋 글도 중첩으로 거부한다(과탐, 거부 쪽).
  `echo "git commit"` 처럼 셸·eval 이 아닌 명령의 인자 글은 지금처럼 판정하지 않는다. 메시지 본문의 커밋 글은 거부된다(위, 과탐 — 우회는
  `-F <파일>`). 남은 갈래는 docs/backlog.md 「커밋 판정의 남은 갈래 — …」.
- **재생(2026-11-01~26 전사, 커밋 글이 든 Bash 호출 4212건, 직전 훅 대비)**: allow→deny 0, deny→allow 0. 사유만 바뀐 것 19건 — 해석 불가 경로·해석 불가 형태·영수증
  미통과로 막히던 여러 커밋 명령이 `commit-multiple` 로 막힌다.
- **회귀**: `meta-test/engine.sh` 「deny 하는 자리는 전부 기록된다」 69개(가드 1 포함). deny 57형태는 사유 로그까지 본다 — 여러 커밋 5(백로그 4형태·두 줄 두 커밋),
  `GIT_` 4(`GIT_DIR`·`env GIT_WORK_TREE`·`export GIT_INDEX_FILE`·`GIT_CONFIG_*`), 중첩 셸 11(`bash -c`·`sh -lc`·`/bin/zsh -c`·`eval`·이중 `bash -c`·
  `bash -c --`·`bash --rcfile X -c`·`fish -c`·`tcsh -c`·여러 줄 인자 2), 줄잇기·변수 셸 단어 10(`bash -c \⏎'…'`·`bash \⏎-c '…'`·`eval \⏎'…'` →
  `commit-nested-shell`, 대조 `&& \⏎git … commit`·짝수 백슬래시 `echo a\\⏎git … commit`·주석 안 `# c \⏎git … commit`·작은따옴표 안 `-m 'x \⏎y'; git … commit` → `commit-multiple`, `$SHELL -c`·`"$BASH" -c`·여러 줄 인자의 `${SHELL} -c` → `commit-nested-shell`), 히어독 22(따옴표 없는 본문의 `$(git --git-dir=…)`·가짜 히어독 뒤 `--git-dir` 커밋 →
  `commit-global-option`, 가짜 히어독 뒤·백틱 안 `GIT_DIR=` → `commit-git-env`, 셸이 실행하거나 파일로 써서 실행하는 본문·메시지 꼴 뒤에 명령이 붙은
  본문의 둘째 커밋·`bash -c` 커밋 → `commit-multiple`·`commit-nested-shell`), 메시지 본문 5(`-F - <<'X'`·`-m "$(cat <<'X'` 본문의 `git commit` 글 →
  `commit-multiple`, `bash -c 'git commit'` 글 → `commit-nested-shell`, `eval git commit` 글 → `commit-multiple`).
  영수증 검증(`게이트 실행 기록 없음`)까지 가는 6개 — 작성자·날짜 변수 2, 한 줄 메시지 안 글, `-F <파일>`, 가짜 따옴표 히어독 뒤의 유일한 커밋,
  따옴표 히어독 본문 안 `eval "$(…)"` 뒤의 커밋. 판정 없음 4(`echo "git commit; git commit"`·`bash -c 'git status'`·`bash --rcfile X -c -- 'git status'`·`$SHELL -c 'git status'`),
  사유 있는 우회 1. 직전 훅으로는 deny 중 55개가 실패했다(나머지 2개는 직전 훅도 막던 `commit-global-option` 형태). 통과 쪽은 직전 훅에서도 통과한다.
  변이 — 세 검사를 하나씩 끔, `GIT_` 화이트리스트 끔, 셸 `-c` 를 옛 옵션 루프(첫 인자)로 되돌림, 셸 목록에서 fish·csh·tcsh 뺌, 폴백 인자 글을
  첫 단어만 봄, 줄잇기 합친 판정을 끔(원문만), 원문 판정을 끔(합친 글만 — 주석 안 줄잇기 단언이 실패), 변수 셸 단어 처리를 끔(토큰 경로·폴백 각각) — 에서 각각 해당 단언이 실패했다. 가드: 훅의 판정 python 블록(bash `"$( … )"` 안)에 `$(` 글이 없다 — 있으면 macOS bash 3.2 가
  짝 괄호로 읽어 훅 전체가 깨진다(이 작업 중 두 번 그렇게 깨졌다). 블록 주석에 `$(y)` 를 넣은 변이에서 실패한다.
- **어디**: `hooks/preflight-gate.sh`(`commit_calls`·`scan`·`commit_verdict`, 거부 분기 셋), `meta-test/engine.sh`, `docs/backlog.md`(두 항목 닫힘).
  `ENGINE_VERSION` 은 그대로(훅의 거부 갈래 — 영수증·프로필 계약 무관).
