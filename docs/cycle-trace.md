# 한 주기 추적 — 설계 (draft)

요구 → 계획 → 계획 리뷰 → 구현 → QA → PR → 머지를 **같은 ID 로 잇는다.** 지금 게이트는
"제대로 만들었나" 를 보지만 "약속한 것을 만들었나" 는 보지 못한다. 이 문서는 그 빈칸을 메우는
최소 구성을 정한다.

리뷰를 받으려고 쓴 문서다. § 8 의 열린 질문이 정해지기 전에는 구현하지 않는다.

---

## 1. 지금 무엇이 끊겨 있나

부품은 있다. `change-planner`(claim 작성) · `requirements-tracer`(claim 닫힘 추적) ·
`classify.sh`(계획이 있으면 PR 게이트에서 tracer 선택) · `receipt.sh`(영수증에 plan 참조 기록).
**이어지지 않는다.** 끊긴 자리가 넷이다.

### 1-1. 계획을 쓰는 경로가 없다

`classify.sh` 와 `receipt.sh` 는 `.git/claude-plans/<branch>.json` 을 **읽지만** 거기에 쓰는 진입점이
없다. 관측 로그에서 계획이 발견된 기록은 0건이다.

```bash
python3 -c 'import json,os;r=[json.loads(l) for l in open(os.path.expanduser("~/.claude/preflight-log.jsonl")) if l.strip()];v=[x for x in r if x["event"]=="record" and "plan" in x];print(len(v),sum(x["plan"]=="FOUND" for x in v))'
```

2026-10-21 출력: `1038 0` (분모는 로그가 자라면 커진다).

### 1-2. 손으로 쓴 계획 하나는 브랜치 키가 어긋나 버려졌다

로컬 전수(`find ~/dev -maxdepth 6 -path '*/.git/claude-plans'`)에서 계획 파일은
결제 API 레포 하나의 `.git/claude-plans/develop.json` 하나다 — requirement 10 · invariant 7 의 실질적인
계획이다(`python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d["requirements"]),len(d["invariants"]))' <그 파일>`). 그러나 **`develop` 브랜치 이름으로 저장됐고** 작업은 기능 브랜치에서 했다. 분류기는
브랜치 이름이 정확히 같은 파일만 찾으므로 이 계획은 한 번도 읽히지 않았다.

**계획은 브랜치보다 오래 산다.** 스택 PR·브랜치 재생성·`develop` 에서 시작한 작업에서 같은
계획이 여러 브랜치에 걸친다. 키가 브랜치 이름 하나면 이 경우가 전부 끊긴다.

### 1-3. 고위험 정의가 좁다

`plan_advisory`(고위험인데 계획 없음)는 300건, repo+branch 로 dedupe 하면 **60개 브랜치**다.

```bash
python3 -c 'import json,os;r=[json.loads(l) for l in open(os.path.expanduser("~/.claude/preflight-log.jsonl")) if l.strip()];a=[x for x in r if x["event"]=="plan_advisory"];print(len(a),len({(x["repo"],x["branch"]) for x in a}))'
```

2026-10-21 출력: `300 60`.
그러나 고위험 신호는 `crossrepo-impact` 하나뿐이다(`classify.sh` `HIGH_RISK_LANES`). `change-planner.md`
가 계획이 필요했던 대표 사례로 든 **결제 멱등 처리**(부수효과·재시도) 같은 변경은 타입 표면을
안 건드리면 고위험으로 잡히지 않는다.

### 1-4. QA 결과가 PR 게이트까지 오지 않는다

tracer 의 세 축 중 validate(QA 에서 실측됐나)는 **QA 보고를 읽어야** 닫힌다. 그런데 영수증은
lane 마다 `status` 와 160자로 자른 `reason` 만 남긴다(`receipt.sh` `_detail`). QA 는 커밋 게이트에서
돌고 tracer 는 PR 게이트에서 돌므로, **tracer 가 볼 수 있는 QA 증거가 없다.** 계획이 있었어도
QA 축은 늘 `NOT_RUN` 이 됐을 것이다.

---

## 2. 목표와 비목표

**목표**

1. 작업 시작 시 계획(claim 목록)을 만드는 **진입점**이 있다
2. 계획이 구현 전에 **리뷰**된다 — 판정 가능한가, 검증 수단이 짝지어졌나, 불변식이 빠지지 않았나
3. 계획이 **브랜치와 무관하게** 작업에 결속된다
4. 각 claim 이 구현 · 테스트 · QA 로 닫혔는지 PR 시점에 **ID 단위로** 보인다
5. 머지 보고에 "claim N개 중 M개 닫힘" 이 QA 상태처럼 함께 간다

**비목표**

- 모든 변경에 계획을 강제하지 않는다. 느리면 우회한다(설계 원칙, `docs/design.md` § 1)
- 계획 **내용이 옳은지**는 판정하지 않는다. 요구사항의 타당성은 사람의 몫이다
- 설계 문서의 사실 주장 검사는 이 설계 범위가 아니다(`docs/design.md` § 6 첫 한계는 그대로 남는다)
- 회사 레포에 파일을 넣지 않는다 — 이 하네스는 개인 도구다(README)

---

## 3. 주기

```
 /plan          계획 리뷰        구현          커밋 게이트 --qa       PR 게이트           머지 보고
 ───────▶ plan ───────▶ approved ───────▶ commit ───────────▶ qa-report ───────▶ trace ───────▶ N/M closed
 change-      plan.sh check               (기존 그대로)    qa-runner 가          requirements-
 planner      + plan-reviewer                             R-id 로 보고·저장      tracer
              + 사용자 승인
```

**planner 는 작업 전 통제, preflight 는 커밋 전 통제다**(`docs/backlog.md` 의 경계). 계획 리뷰는
preflight lane 이 아니라 `/plan` 안에서 끝난다. preflight 는 계획을 **소비**만 한다.

---

## 4. 산출물과 결속

### 4-1. 계획 artifact

스키마는 `change-planner.md` 의 것을 그대로 쓰고 필드 셋을 더한다:

```json
{
  "planId": "pay-cancel-idempotency-20261021",
  "revision": 2,
  "designDoc": { "path": "projects/face-access/design.md", "repo": "wiki", "sha": "489b989" },
  "approval": { "by": "user", "at": 1792500000000, "digest": "<requirements·invariants 의 해시>" },
  "...": "기존 필드 그대로"
}
```

- `designDoc` — 설계 문서가 있으면 그 경로와 **커밋 sha**. 설계 문서가 바뀌면 계획이 낡았는지 알 수
  있어야 한다(아래 4-3)
- `approval.digest` — 승인 시점의 claim 집합. 승인 뒤 claim 이 조용히 바뀌는 것을 잡는다
- `revision` — 계획을 고치면 올린다. ID 계약(의미를 바꾸지 말고 새 ID 를 발급)은 그대로다

### 4-2. 저장 위치와 결속 — 브랜치 키를 버린다

```
~/.claude/plans/<repo-slug>/<planId>.json          계획 본체 (머신 로컬)
<repo>/.git/claude-plans/<branch>.json             결속 포인터: {"planId": "..."}
```

- 본체를 `.git` 밖으로 뺀다 — 계획이 브랜치 삭제·worktree 정리와 함께 사라지지 않는다
- 브랜치는 **포인터**만 갖는다. 한 계획을 여러 브랜치가 가리킬 수 있다(스택 PR, `develop` 에서 시작한 작업)
- 분류기는 포인터 → 본체 순으로 찾는다. 포인터가 없으면 지금처럼 `NONE`
- 기존 `.git/claude-plans/<branch>.json` 에 본체가 직접 있으면(1-2 의 `develop.json`) 그대로 읽는다 — 이전 호환

`/plan` 은 새 브랜치에서 시작할 때 포인터를 쓰고, 이미 계획이 있는 브랜치에서 파생된 브랜치는
`/plan --attach <planId>` 로 같은 계획을 붙인다.

### 4-3. 낡은 계획 감지

PR 게이트에서 결정론적으로 본다(LLM 아님):

| 조건 | 결과 |
|---|---|
| `approval` 없음 | tracer 는 돌되 보고에 "미승인 계획" 을 표시. 막지 않는다 |
| 현재 claim 해시 ≠ `approval.digest` | **blocking** — 승인 뒤 claim 이 바뀌었다. 재승인하거나 `revision` 을 올려 재승인 |
| `designDoc.sha` 이후 그 파일에 커밋이 있다 | 참고 — 설계가 바뀌었는데 계획이 따라갔는지 사람에게 묻는다 |

설계 문서 sha 비교는 vault 가 로컬에 있을 때만 한다. 없으면 `UNKNOWN` 으로 넘긴다
(vault 연결 판정의 `UNKNOWN` 과 같은 이유).

---

## 5. 단계별 설계

### 5-1. `/plan` — 계획 작성

새 스킬. 하는 일:

1. `change-planner` 를 **별도 컨텍스트(서브에이전트)** 로 부른다 — planner 계약의 `INDEPENDENCE`
2. 설계 문서 경로를 받으면 planner 에게 넘기고 `designDoc` 을 채운다
3. 5-2 를 돌린다
4. 사용자에게 요약을 보이고 **승인을 받아** `approval` 을 쓴다
5. 포인터를 쓴다

`BLOCKED`(열린 질문 있음)면 승인 단계로 가지 않는다.

### 5-2. 계획 리뷰 — 기계 판정 먼저

설계 원칙 2(기계로 표현되는 판정은 기계로)에 따라 둘로 나눈다.

**`plan.sh check` (결정론)** — 계획 ID 규칙(`_ID`)과 한 파일에 두려고 결속 스크립트의 하위 명령으로 넣었다

- 스키마 유효, ID 유일, `R*`/`I*` 접두 규칙
- 모든 requirement·invariant 에 `verification` 이 1개 이상
- `how` 가 `test|qa|review|manual` 안에 있음
- `manual` 비율 상한(초안: 30%) — 넘으면 tracer 가 아무것도 못 닫는다
- `outOfScope` 비어 있지 않음, `openQuestions` 비어 있음
- `affectedArtifacts` 의 경로가 실제로 존재(레포 상대) — **경고만** 한다. 새로 만들 파일·URL 이 정당하게 들어온다

**`plan-reviewer` (LLM, 새 에이전트)** — 기계로 못 보는 것만:

- claim 이 **판정 가능한가**("안정적으로 처리한다" 류를 잡는다)
- 부수효과가 있는 변경인데 재시도·중복·부분 실패 불변식이 없는가
- `designDoc` 이 있으면, 설계 문서의 결정 사항 중 계획에 대응 claim 이 없는 것

planner 와 다른 컨텍스트에서 돈다. 판정은 `READY` / `REVISE(사유)` 둘. 리뷰 → 수정 반복은 최대 3회로
끊고 넘으면 사람에게 넘긴다 — 라운드 종료 조건이 없어 46라운드가 돈 전례가 있다.

### 5-3. QA — R-id 로 보고하고 저장한다 (1-4 를 닫는다)

- 커밋 게이트 `--qa` 때 계획이 있으면 `qa-runner` 프롬프트에 `how: qa` 인 verification 목록을 넣는다
- `qa-runner` 는 시나리오마다 대응 ID 를 단다(`R2/qa#1`)
- 워크플로가 QA 결과를 **파일로 남긴다**: `.git/claude-preflight.qa/<indexTree>.json`
  (시나리오 · ID · 요청 · 상태코드 · 판정). 영수증의 160자 reason 으로는 부족하다
- PR 게이트의 tracer 는 브랜치 커밋들의 indexTree 로 이 파일들을 찾아 validate 축을 판정한다

QA 를 커밋 게이트에 둔 이유(결과가 커밋될 내용에 묶인다)가 여기서도 그대로 유지된다.

### 5-4. PR 게이트 — tracer

선택 조건은 지금 그대로(계획 `FOUND`). 바뀌는 것:

- 계획을 포인터 → 본체로 찾는다(4-2)
- 4-3 의 낡은 계획 검사가 먼저 돈다
- tracer 에게 test-runner 결과와 5-3 의 QA 파일 경로를 넘긴다 — 지금은 넘기지 않아 tracer 가 다시 찾거나 추정해야 한다

### 5-5. 머지 보고

머지 확인을 요청할 때 QA 상태와 나란히:

> claim 12개 중 10개 닫힘 · 열림: R4(verify MISSING), I2(validate NOT_RUN) · QA: qa-done-at-commit-gate

계획이 없는 **고위험** PR 이면 "계획 없음" 을 같은 자리에 쓴다 — 막지는 않는다.

---

## 6. 강제 정책 — 단계적으로

| 단계 | 무엇 | 넘어가는 조건 |
|---|---|---|
| 0 (지금) | `plan_advisory` 를 센다 | — |
| 1 | `/plan` 제공. 계획이 있으면 끝까지 추적. 고위험 무계획은 PR 게이트 참고 + 머지 보고 | 구현 완료 |
| 2 | 고위험 정의를 넓힌다(1-3). 신호 후보: 부수효과 경로(결제·발송·재고), 영속 스키마 변경, 재시도 로직 | 1 단계 표본 검사 |
| 3 | 고위험 + 무계획을 PR 게이트에서 **blocking** | 아래 표본에서 누락 반복이 확인될 때만 |

**1 → 3 의 근거는 표본 검사로 얻는다.** 고위험 무계획 60개 브랜치 중 10개를 골라, 머지 후
요구사항·영향 누락으로 고친 커밋이 있었는지 사람이 본다. 이건 **관찰**이지 수치가 아니다
(수치 규칙, `skills/preflight/SKILL.md`). 누락이 반복되면 3, 아니면 2 에 머문다 — backlog 의 판단 기준
그대로다.

강제를 너무 일찍 걸면 QA 강제 때처럼(면제율 10/10, 그중 2건은 게이트 전체 우회) 계획이 아니라
우회가 생긴다.

---

## 7. 비용과 위험

- **작성 비용** — planner 1회 + `plan.sh check`(초 단위) + plan-reviewer 1~3회. 커밋 게이트 lane 하나와
  비슷한 자릿수로 본다(미측정). 1 단계에서 실측해 이 칸을 고친다
- **계획이 형식이 된다** — 통과용 claim 을 쓰는 것. plan-reviewer 의 "판정 가능한가" 가 1차 방어이고,
  근본적으로는 막지 못한다
- **tracer 도 LLM 이다** — "닫혔다" 판정 자체가 self-report 다. evidence 를 지목 가능한 것(파일·줄·
  테스트 이름·QA 파일의 시나리오)으로 제한하고, receipt 가 지목된 테스트 이름이 test-runner 결과에
  실제로 있는지는 코드로 대조할 수 있다(후속)
- **자기 참조 비용** — 이 레포를 고치는 PR 에도 이 주기가 걸린다. 이 레포는 고위험 신호에 안 걸리므로
  1·2 단계에서는 영향이 없다

---

## 8. 열린 질문

1. **계획 본체를 어디에 둘까.** 이 문서는 머신 로컬(`~/.claude/plans/`)을 제안했다. 클라우드 세션에서는
   보이지 않는다. 대안은 vault `projects/<name>/plans/` 인데 회사 위키에 에이전트용 JSON 이 쌓인다. 둘 중
   무엇이 맞나, 혹은 설계 문서(vault)와 계획(로컬)을 나누는 지금 안으로 충분한가
2. **설계 문서는 언제 필요한가.** 모든 계획에 설계 문서를 요구하지 않는다. 기준 후보: 레포 2개 이상에
   걸친 변경, 외부 연동, 영속 모델 신설. 이 기준이 맞나
3. **승인은 누가 하나.** 지금은 사용자 한 명이 승인자이자 구현자다. 계획 승인이 의미가 있으려면 최소한
   다른 세션(컨텍스트)이 리뷰해야 한다 — 5-2 의 plan-reviewer 로 충분한가
4. **고위험 신호 후보(6 의 2 단계)** 중 무엇부터 넣을까. 경로 패턴으로 잡을 수 있어야 분류기에 들어간다

---

## 9. 구현 순서 (PR 단위)

1. 결속 — 포인터 + 본체 위치 + 이전 호환 읽기 (`classify.sh`, `receipt.sh`) · 메타테스트
   — `skills/preflight/plan.sh` (`resolve`·`attach`·`adopt`). 본체 위치는 § 8-1 이 정해지기 전까지
   이 문서의 안(머신 로컬 `~/.claude/plans/`)으로 둔다 — 바꾸면 `plan.sh` 의 `store` 한 줄이다
2. 형식 검사 · 메타테스트(결함을 심은 계획 fixture)
   — `plan.sh check`. 판정은 `READY` / `REVISE`(형식 오류) / `BLOCKED`(열린 질문). 실재 계획 1건에서
   오류 0 · 경고 0 · `BLOCKED`(열린 질문 5). 영향 경로가 레포에 없으면 경고만 한다 — 새로 만들 파일이 정당하게 들어온다
3. `/plan` 스킬 + `plan-reviewer` 에이전트
   — `skills/plan/SKILL.md`, `agents/plan-reviewer.md`, `plan.sh approve`. 승인자는 § 8-3 의 안대로 다른 컨텍스트의
   리뷰(`READY`) + 사용자 명시 승인이다. 승인은 claim 집합 다이제스트에 묶이고 `resolve` 가 `approval` 을
   `APPROVED`/`CHANGED`/`NONE` 으로 낸다 — 막는 것은 5 단계다. 누가 승인했는지는 코드가 검증하지 못한다
4. QA 결과 파일 저장 + `qa-runner` 의 R-id 보고 (5-3)
   — `plan.sh qa` 가 참조(`R2/qa#1`)를 만들고, 분류기가 실행자·심사자에게 넘긴다. 실행자는 `scenarios[].claimRefs`
   로 답한다(스키마 필수). 영수증이 **전사의** 출력에서 시나리오를 읽어 `<common-dir>/claude-preflight.qa/<indexTree>.json`
   에 남기고 덮임(통과·실패·미실행·덮이지 않음·계획에 없는 참조)을 센다. 읽는 쪽(tracer)은 5 단계다
5. tracer 입력 보강 + 낡은 계획 검사 (5-4, 4-3)
   — 분류기가 브랜치 커밋 tree 로 QA 기록을 모아 계획 항목별 **최신** 상태(PASS/FAIL/NOT_RUN/MISSING)와 승인 상태,
   설계 문서 드리프트(`CURRENT`/`CHANGED`/`UNKNOWN`)를 tracer 에 넘긴다. 승인 뒤 claim 이 바뀐 계획은 PR 기록이
   `plan-changed` 로 거부한다. 미승인은 표시만 한다. **test-runner 결과는 넘기지 않았다** — 두 lane 이 병렬이라 결과가
   없고, 순차 체인으로 묶으면 뒤 lane 이 앞 보고를 "심사" 하는 기존 체인 의미와 섞인다. tracer 가 테스트를 직접 확인한다
6. 머지 보고 (5-5)
   — 추적자 출력에 claim 별 `claims[]`(impl·verify·validate) 가 필수가 됐다. PR 기록이 **전사의** 출력에서 이를 읽어
   계획의 claim 목록(`plan.sh claims`)을 분모로 닫힘을 세고 영수증에 남긴다. `receipt.sh report pr <repo>` 가 머지 보고
   한 덩어리(계획 닫힘 · 열린 claim · QA 상태 · 기록 뒤 커밋 여부)를 낸다. 막지 않는다 — 머지는 사람이 정한다

각 단계가 단독으로 쓸모 있게 나눴다. 1 만으로도 1-2 처럼 손으로 쓴 계획이 버려지는 일은 없어진다.
