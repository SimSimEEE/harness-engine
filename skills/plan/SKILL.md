---
name: plan
description: 코드를 쓰기 전에 작업의 약속(claim)을 계획으로 만들고, 다른 컨텍스트의 리뷰와 사용자 승인을 받아 브랜치에 결속한다. PR 게이트의 requirements-tracer 가 이 계획으로 구현·테스트·QA 의 닫힘을 추적한다. 부수효과(결제·발송·재고·외부 쓰기)나 여러 레포에 걸친 변경을 시작할 때, 또는 사용자가 /plan 을 부를 때 쓴다.
---

# Plan — 작업 시작 시점의 약속

```
intent → change-planner(초안) → plan.sh check → plan-reviewer → 사용자 승인 → plan.sh approve → plan.sh adopt
         별도 컨텍스트             결정론          별도 컨텍스트     채팅에서 명시      기록             브랜치에 결속
```

**너는 계획을 쓰지도, 심사하지도 않는다.** 쓰는 것은 `change-planner`, 심사는 `plan-reviewer` 이고 둘은
서로 다른 서브에이전트 컨텍스트다. 너는 둘을 잇고, 사용자에게 보이고, 승인을 기록한다.
계획을 쓴 컨텍스트가 그대로 심사·구현하면 같은 맹점을 공유한다 (docs/cycle-trace.md § 5).

이 단계는 **작업 전 통제**다. 커밋 전 통제(preflight)와 섞지 마라 — preflight 는 결속된 계획을 읽기만 한다.

`P=<이 스킬의 Base directory>/../preflight` — `plan.sh` 가 거기 있다.

## 0. 준비

- 대상 레포와 **작업 브랜치**를 정한다. 계획은 지금 체크아웃된 브랜치에 결속된다 — 기본 브랜치(`develop`·
  `master`)에서 시작하지 마라. 기본 브랜치 이름으로 저장된 계획이 기능 브랜치에서 한 번도 읽히지 않은 전례가 있다
- `$P/plan.sh resolve <repo>` 로 이미 결속된 계획이 있는지 본다. `FOUND` 면 새로 만들지 말고 사용자에게 묻는다
- 초안 경로를 정한다: 세션 scratchpad 디렉터리(없으면 `mktemp -d`)의 `plan-draft.json`. 레포 안에 두지 마라
- 설계 문서가 있으면(예: vault `projects/<name>/design.md`) 경로를 받아 둔다

## 1. 초안 — change-planner

`Agent(subagent_type: "change-planner")` 를 부른다. 프롬프트에 넣을 것:

- 사용자의 요청 **원문** (해석하지 말고)
- 대상 레포 경로, 초안 경로
- 설계 문서 경로 (있으면) — 계획의 `designDoc` 필드에 경로를 넣게 한다
- "초안 경로에만 쓰고 `plan.sh check` 까지 돌려라. `adopt` 하지 마라"

이후 수정 요청은 **같은 planner 에게** `SendMessage` 로 보낸다. 새로 부르면 앞 맥락이 사라진다.

## 2. 형식 — plan.sh check

```bash
$P/plan.sh check <repo> <초안 경로>
```

| 판정 | 할 일 |
|---|---|
| `READY` | 3 으로 |
| `REVISE` | `errors[]` 를 planner 에게 그대로 넘겨 고치게 하고 다시 2 |
| `BLOCKED` | 열린 질문을 **사용자에게** 보이고 멈춘다. 답을 받으면 planner 에게 넘기고 다시 2 |

열린 질문을 네가 추측으로 채우지 마라. 추측으로 채운 계획은 틀린 기준으로 추적된다.

## 3. 의미 — plan-reviewer

`Agent(subagent_type: "plan-reviewer")` 를 **새로** 부른다(planner 와 다른 컨텍스트). 넣을 것: 초안 경로,
대상 레포, 설계 문서 경로(있으면).

| 판정 | 할 일 |
|---|---|
| `READY` | 4 로 |
| `REVISE` | 지적을 planner 에게 넘겨 고치게 하고 **2 부터** 다시 (고치면 형식이 깨질 수 있다) |

**리뷰는 최대 3라운드다.** 3라운드째에도 REVISE 면 멈추고 남은 지적을 사용자에게 넘긴다 — 사용자가
지적을 받아들일지, 계획을 이대로 둘지 정한다. 상한이 없으면 리뷰가 수렴하지 않고 돈다(커밋 게이트에서
한 변경이 46라운드를 돈 전례가 있다). 라운드 사이에 같은 `findings[].id` 가 다시 나오면 그 사실도 보고한다.

## 4. 사용자 승인

사용자에게 보인다:

- 요구사항·불변식 목록 (ID 와 claim 한 줄씩) — **불변식을 먼저**
- 범위 밖으로 둔 것
- 리뷰가 몇 라운드였고 무엇을 고쳤는지, 남은 지적이 있으면 그것
- "이 계획으로 진행할까요?" — 승인하면 이 claim 들이 PR 시점의 추적 기준이 된다는 것

**사용자가 채팅에서 명시적으로 승인한 뒤에만 5 로 간다.** 침묵·다른 화제·"좋아 보인다" 같은 감상은 승인이
아니다. `plan.sh approve` 는 누가 승인했는지 검증하지 못한다 — 이 규칙이 유일한 방어다.

## 5. 기록과 결속

```bash
$P/plan.sh approve <repo> <초안 경로>   # READY 가 아니면 거부한다
$P/plan.sh adopt   <repo> <초안 경로>   # 저장소로 옮기고 이 브랜치에 결속
$P/plan.sh resolve <repo>               # FOUND · approval=APPROVED 인지 확인
```

`approve` 는 claim 집합의 다이제스트를 남긴다. 승인 뒤 claim 이 바뀌면 `resolve` 가 `approval: CHANGED` 를 낸다.

## 6. 보고

planId, 결속된 브랜치, 요구사항·불변식 개수를 보고한다. 구현은 **다른 컨텍스트**에서 시작하라고 권한다 —
`plan.sh resolve <repo>` 가 준 경로를 읽고 시작하면 된다.

## 하드 규칙

- 계획 파일을 네가 직접 고치지 마라. 고치는 것은 planner 다 — 네가 고치면 리뷰가 본 것과 승인될 것이 갈린다
- 리뷰를 건너뛰지 마라. 형식이 READY 여도 의미는 별개다
- 사용자 승인 없이 `approve` 를 부르지 마라
- **승인된 계획을 같은 planId 로 바꿀 수 없다** — `adopt` 가 같은 ID 의 다른 내용을 거부한다(ID 계약).
  의미가 바뀌면 새 planId(예: `<원래 ID>-r2`)로 1 부터 다시 하고, 브랜치의 옛 포인터 파일은 사용자 확인 뒤 지운다
- 다른 파생 브랜치에서 같은 계획을 쓰려면 새로 만들지 말고 `$P/plan.sh attach <repo> <planId>`
