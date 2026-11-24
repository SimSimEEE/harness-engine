---
name: preflight
description: 커밋·PR 전 품질 게이트. 결정론적 분류기가 lane 을 고르고 워크플로가 병렬 실행·집계하며, 통과 시 게이트 기록을 남긴다. git commit / gh pr create 는 PreToolUse 훅이 이 기록을 확인하므로, 커밋·PR 전에 반드시 실행한다.
---

# Preflight Gate

커밋·PR 전 단일 진입점.

**절차를 눈으로 따라 하지 마라 — 하네스가 실행한다.** 네가 하는 일은 셋뿐이다:
분류기를 돌리고, 워크플로를 띄우고, 결과를 영수증에 기록한다.

**무엇을 검사할지 네가 고르지 않는다.** lane 선택은 `classify.sh` 가 결정한다.
같은 변경에 매번 같은 lane 이 도는 것이 이 구조의 전제다.

**기본 경로 — 분류 한 번.** 스테이징 뒤 `$P/preflight-run.sh prepare <repo> commit|pr|all [--round=N] [--prior=<findingIds 파일>] [classify.sh 플래그…]`
한 번 — 분류하고 다음 행동을 JSON 한 줄로 낸다. `action=recorded` 면 선택 lane 이 0개인 커밋이라 단축 경로 기록(`via: fast-path`)까지
끝났다 — 출력의 `next` 대로 커밋한다(별도 호출). `action=workflow` 면 출력의 `scriptPath`·`args` 를 **그대로** Workflow 에 넣고(§ 2),
결과를 기록한다(§ 4). 분류가 실패하면 stdout 이 비고 classify.sh 의 종료코드로 끝난다. 단축 경로 조건은 `preflight-fast.sh` 와
같다(commit 이고 `--msg-file` 말고 플래그가 없을 때). worktree 세션이면 `PF_CLS_DIR=<scratchpad>` 를 준다 — `preflight.js` 사본도 거기 생긴다.
근거는 DECISIONS.md 「분류 한 번 — preflight-run.sh prepare」.

**단축 경로만(커밋).** `$P/preflight-fast.sh <repo> commit [--msg-file=<초안>]` 는 같은 판정을 하고, 선택이 있으면 기록하지 않고
exit 10 으로 끝난다. 근거는 DECISIONS.md 「빈 게이트 단축 경로」.

## 0. 순서 — QA 는 배포된 것을 검사한다

```
코드 작성 → dev 배포 → 커밋 게이트 `--qa` → 보고·검토·수정 → 커밋 → PR 게이트 → PR 생성
```

**QA 를 커밋 게이트에서 돌리는 것이 기본이다.** 배포는 커밋을 요구하지 않으므로
(`npm run deploy.<profile>` 는 워킹트리를 빌드해 패키징한다) 이 순서가 가능하고, 이렇게 하면:

- QA 결과가 `indexTree` 로 **커밋될 내용에 묶인다.** PR 게이트에서 돌리면 이미 커밋된 뒤라
  그 사이 워킹트리 변경을 잡지 못한다
- 지적을 fix-up 커밋이 아니라 **커밋 전 수정**으로 처리하므로 커밋이 양산되지 않는다
- 게이트 보고가 커밋 **전에** 오므로 사용자가 무엇을 담을지 검토할 수 있다

`--qa` 는 **선택**이다. 모든 커밋이 배포를 요구하면 과하다 — 배포 후 **마지막 커밋**에 쓴다.

**PR 게이트는 QA 를 강제하지 않는다.** 2026-09-04~09 실측에서 QA 가 걸린 PR 게이트 10건이
전부 면제됐고(면제율 100%), 면제가 번거로운 두 번은 게이트 전체 우회로 갔다 — `pr-quality`·
`vault-sync` 까지 함께 날아갔다. 강제가 QA 를 만들지 못하면서 우회 유인만 낳았으므로,
지금은 사유를 기록한다:

- 커밋 게이트에서 QA 가 통과했으면 → `qa-done-at-commit-gate`
- 아니면 → 카테고리의 PR 게이트 QA 안내(`QA_HINT` — 예: `not-deployed-at-pr-gate`, dev 배포가 있는 카테고리). 그 밖의 레포는 카테고리 비해당 사유

**강제를 뺀 대신 확인 지점은 머지로 옮긴다.** 강제하던 때는 면제할 때마다 사람이 승인했지만
이제는 조용히 넘어가므로, **code 변경 PR 의 머지 확인을 요청할 때 QA 상태를 반드시 함께 보고한다.**

> 이 PR 은 QA 가 실행되지 않았습니다 (`not-deployed-at-pr-gate`). 머지할까요?

**머지 확인 요청에는 `$P/receipt.sh report pr <repo>` 의 출력을 그대로 붙인다.** 계획이 결속된 PR 이면
"claim N개 중 M개 닫힘 · 열림: …" 이 함께 나온다 — 분모는 계획의 claim 목록이고 닫힘은 전사의 추적 결과로
코드가 센다. 열린 claim 이 있으면 그 목록을 사용자에게 보이고, 그대로 머지할지는 사람이 정한다.
기본은 지금 체크아웃된 브랜치의 기록이다 — 머지 뒤 base 로 돌아왔으면 `report pr <repo> <branch>` 로 브랜치를 넘긴다.

QA 없이 머지할지는 사람이 정한다 — 다만 **모르는 채로 머지되게 두지는 않는다.**
`qa-done-at-commit-gate` 면 그 사실을 보고한다.

vault 등록 레포면 같은 출력에 **`vault 미반영 N건`** 이 함께 나온다 — 그 레포의 대기 목록 항목 수다
(아래 § vault 대기 목록). **머지·배포 뒤 vault 프로젝트 노트에 반영할 일은 대기 목록에 적재하고, 남은 일로 vault PR 을 적지 않는다.**
머지됨·운영 배포됨·마일스톤 완료처럼 게이트가 못 본 관측은 그 레포 카테고리의 `vault-queue.sh add <org/repo> @<항목.json>`
(`kind: "session"`, `observation: "merged"|"deployed"|"milestone"`)로 적재하고, 노트 반영은 `vault-batch-sync`
스킬이 여러 레포를 모아 vault 커밋 하나로 한다. 작업 메모리에도 "남은 것: vault 노트 갱신(wiki PR)" 을 적지 않는다.

vault 문서만 바뀐 PR 은 code 변경이 없으므로 애초에 QA 대상이 아니다.

**리뷰어 승인을 면제받은 vault PR 은 생성에서 끝나지 않는다.** 조직이 vault 레포의 리뷰어 승인 요건을 면제했으면
(그 사실은 vault 카테고리 절차 — 조회 출력의 `procedures` — 에 적힌다) 지정 리뷰어는 승인 게이트가 아니라 알림 대상이 된다.

**면제된 것은 리뷰어 승인이지 사용자 승인이 아니다.** 자체 리뷰 결과를 **사용자에게 보고하고**
확인받은 뒤 머지한다 — 머지는 되돌리기 어려운 외부 행위다.

**자체 리뷰를 PR 코멘트로 올리지 마라.** 리뷰는 사용자에게 하는 것이고, PR 에 쌓으면
리뷰어가 코멘트 체인을 따라가며 진실을 재구성해야 한다. 정정할 일이 생기면 코멘트를
덧붙이지 말고 **PR 본문과 커밋을 고쳐라.**

자체 리뷰는 형식이 아니라 실제 리뷰다: 게이트가 통과했어도 diff 를 직접 읽고, 판단 근거와
**검증하지 못한 것**을 사용자에게 말한다.
**코드 레포는 해당 없다** — 리뷰어 승인도 종전대로 필요하다.

**머지된 원격 브랜치는 지운다** — vault 와 코드 레포 모두 (사용자 정정,
2026-10-15). 머지됐는지 확인한 뒤에만 지운다:

```bash
git fetch origin
git merge-base --is-ancestor origin/<branch> origin/<base> && git push origin --delete <branch>
```

## 1. 분류 (결정론적)

순서는 **고친다 → `git add` → classify → lane → record → commit** 이다. 분류는 워킹트리가 아니라
**커밋될 인덱스**를 검사 대상으로 잡으므로 스테이징이 먼저다. 워킹트리에만 있는 수정과 미추적
파일은 대상이 아니다(미추적은 `untrackedCount` 로 개수만 보인다). PR 모드는 base..HEAD 의 커밋만 본다.
**분류 뒤 인덱스가 바뀌면 재분류한다** — `git add` 를 더 했거나 다른 세션이 스테이징했으면
`record` 가 `index-changed` 로 거부한다.

```bash
P=<이 스킬의 Base directory>   # 로컬 설치는 ~/.claude/skills/preflight, 플러그인이면 <plugin>/skills/preflight
git -C <repo> add <커밋할 파일들>
$P/preflight-run.sh prepare <repo> commit|pr|all [--qa] [--review] [--body-file=<PR 본문 초안>] [--msg-file=<커밋 메시지 초안>]
```

플래그는 `classify.sh` 의 것을 그대로 넘긴다. 분류를 따로 돌린 뒤 다시 돌리지 마라 — prepare 가 분류 결과로 다음 행동(기록 또는 Workflow 인자)까지 낸다.

- `selected` — 돌릴 lane 과 그 lane 이 볼 파일
- `notSelected` — **안 돌리는 lane 과 사유** (기록의 일부다)
- `category` — 대상 레포의 카테고리(`categories/<이름>`, 없으면 `null`). 카테고리에 속한 규칙만 걸린다
- 같은 내용이 `<repo>/.git/claude-preflight.classify.json` 에도 남는다 → 영수증이 자동으로 읽는다.
  쓰기를 마치면 stderr 에 `classify-sha256: <hex>` 한 줄이 나온다 — 그 파일 바이트의 sha256 이다(§ 2 파일 경로 입력)

**카테고리.** 레포 성격별 규칙은 `$P/categories/<이름>/` 와 오버레이의 `categories/<이름>/` 에 있다(오버레이 루트는
`config.json` 의 `overlayDir` 또는 `PF_OVERLAY_DIR` — 조직 전용 카테고리를 엔진 밖에 둔다). 엔진은 `shell-tool`(스냅숏에
`skills/preflight/meta-test.sh` 와 `hooks/preflight-gate.sh`: 자체 회귀 스위트)과 `generic`(기본 — 어느 카테고리에도 신호가
없을 때, 근거 `fallback`)을 싣는다. 관례 판정·QA 엔드포인트·dev 배포 안내·vault 등록 조회와 `vault-sync`·vault 문서 판정은
그 규칙을 가진 카테고리에서만 걸리고, 기본 카테고리는 공통 규칙만 걸린다. **둘 이상에 걸리면 분류하지 않고 exit 3** 이다 — stderr 에
걸린 카테고리와 근거가 나온다. 카테고리 디렉터리가 빠졌거나 선언(`categories/categories.json`)과 어긋나도 exit 3 이다.

레포의 카테고리·근거·그 카테고리의 절차 요구를 미리 보려면 조회 명령을 쓴다(읽기 전용 — 분류 파일·영수증·로그를 쓰지 않고
vault 를 fetch 하지 않는다). 판정은 classify.sh 와 같은 코드이고 입력은 commit 모드와 같다:

```bash
$P/category.sh <repo>   # → {"category", "evidence": {<이름>: [신호…]}, "procedures": [{id, text}…], "profile", "basis"}
```

**요청 시점 표시 훅.** `hooks/category-context.sh`(UserPromptSubmit)가 요청마다 이 조회 결과를 컨텍스트에 붙인다 —
`[하네스 카테고리] <레포>: <이름> (근거: …)` 와 절차 줄, 카테고리가 없으면 `없음`, 겹침이면 `겹침 — <걸린 카테고리 이름>`, 카테고리 적재 실패(같은 exit 3)면 `분류 불가 — <원인>`.
레포는 훅 입력의 `cwd` 가 속한 git 레포다. 따로 판정하지 않으므로 이 표시와 게이트가 다른 카테고리를 말하지 않는다.
git 레포가 아니거나 조회가 실패하면 아무것도 내지 않고, 언제나 exit 0 이라 요청을 막지 않는다. 다른 레포를 `git -C`
로 다루는 세션에서는 그 레포가 아니라 세션 작업 디렉터리의 카테고리가 나온다 — 대상 레포는 위 조회 명령으로 본다.
등록은 `settings.hooks.json`(install.sh 가 병합)과 플러그인 `hooks.json` 이다. 근거는 DECISIONS.md 2026-11-16.

**프로필.** 레포 하나에 붙는 설정은 `$P/profiles/<owner>/<repo>.json`(origin 슬러그를 소문자로 쓴 자리)이다:

```json
{"repo": "Owner/Repo", "category": "shell-tool", "engineVersion": "2.0",
 "adjustments": [{"id": "A1", "kind": "force-lane", "lane": "code-reviewer", "modes": ["commit"],
                  "approved": "YYYY-MM-DD", "evidence": "<실측 명령과 결과>"}]}
```

- `category` 는 신호 추론을 **고정**한다. 신호가 다른 카테고리이거나 아무 카테고리에도 걸리지 않으면 분류·조회가 exit 3 이고
  stderr 에 두 판정이 나온다 — 신호가 맞으면 프로필을, 프로필이 맞으면 레포를 고친다. 프로필은 카테고리 겹침을 풀지 않는다.
- `adjustments` 는 그 레포에서 승인된 규칙 조정이다. 지금 받는 종류는 `force-lane`(대상이 없어도 `code-reviewer`·`test-runner`·
  `crossrepo-impact` 를 그 모드에서 돌린다) 하나다 — 더 도는 쪽만 있다. 승인일·근거가 없으면 받지 않는다.
- 프로필 파일 하나라도 형식이 틀리면 어느 레포도 분류하지 않는다(exit 3, `프로필 적재 실패`).
- 근거는 분류 출력의 `categoryBasis`·`profile`, 조회 출력의 `basis`·`profile` 에 남는다. 프로필이 없으면 지금처럼 신호로 추론한다.

**처음 보는 레포.** 프로필이 없는 레포는 요청 시점 훅이 카테고리 줄 아래에 한 줄을 더 낸다 —
``프로필 없음 — 추론 카테고리 <이름>(근거: …) — 사용자가 확인하면 `/harness-profile`(이력 실측·규칙 승인 뒤 생성), 조정 없이 바로 만들려면 `bash $P/profile.sh init <레포>` ``.
origin 리모트가 없으면 프로필 키(`<owner>/<repo>`)를 정할 수 없어 안내만 하고, 카테고리 없음·겹침이면 이 줄이 없다.
**훅은 프로필을 쓰지 않는다.** 기본 경로는 생성기 스킬 `harness-profile` 이다 — 이력을 실측해 규칙 조정 후보를 보이고,
사용자가 승인한 것만 `--adjustments` 로 넘겨 아래 명령을 부른다. 조정 없이 만들 때만 사용자가 추론 카테고리를 확인한 뒤 명령을 직접 실행한다:

```bash
$P/profile.sh init <repo> [--category <이름>] [--adjustments <파일>]   # → $P/profiles/<owner>/<repo>.json
```

- 카테고리는 추론값을 쓴다. `--category` 는 확인의 명시이고, 추론과 다르면 만들지 않는다(프로필이 추론과 다르면 그 레포는 분류되지 않는다).
- 만들지 않는 경우(exit 3): origin 없음, 카테고리 없음, 겹침, `--category` 불일치, 이미 있음, `ENGINE_VERSION` 을 읽지 못함.
- 내용은 `{"repo": <origin 슬러그 원문>, "category", "engineVersion": <ENGINE_VERSION>, "adjustments": <--adjustments 파일, 없으면 []>}` 다.
  `--adjustments` 는 JSON 목록인지만 보고 항목 형식은 적재기(아래 확인)에 맡긴다 — 거부되면 쓴 파일을 지운다.
- 규칙 조정 후보를 고르는 절차는 생성기 스킬 `harness-profile` 이다 — `$P/profile-measure.sh` 가 현황 점검(`status`),
  이력 재분류로 force-lane 후보의 4축 실측(`measure`), 표(`table`), 승인 id 의 조정 항목 조립(`select`)을 한다.
  근거는 DECISIONS.md 「프로필 생성기」.
- 쓴 뒤 조회(`category.sh`)로 다시 읽어 그 레포의 프로필로 적재되는지 확인하고, 아니면 쓴 파일을 지운다.
- 파일은 자기 설치본의 `profiles/` 에 생긴다. 다른 설치본에 퍼지려면 이 레포에 커밋한다.
- 조회 출력에 `origin`(슬러그, 없으면 null)이 있다 — 훅과 이 명령이 프로필 키로 쓴다. 근거는 DECISIONS.md 「처음 보는 레포 확인 절차」.

`--qa` 는 dev 배포가 **실제로 끝난 뒤에만** 붙인다.

`--review` 는 `code-reviewer` 를 부른다. **커밋마다 돌지 않는다** — 리뷰의 기본 자리는 PR
게이트이고, 거기서는 플래그 없이도 돈다. 커밋 게이트에서는 리뷰를 받고 싶은 커밋에만 붙인다.

옮긴 이유는 **비용**이다. 리뷰 lane 은 변경 파일과 참조 구현을 읽으므로 커밋 하나에 붙는
비용이 다른 lane 과 자릿수가 다르고, 그것이 커밋마다 반복됐다.

**PR 생성 이후 구간은 분류기가 알아서 덮는다.** 훅은 커밋과 PR 생성 두 자리에만 걸려 PR
게이트는 **생성 한 번뿐**이다 — 그 뒤 쌓는 커밋(리뷰 지적을 반영하는 커밋이 정확히 여기다)을
덮는 것은 커밋 게이트밖에 없다. 그래서 이 브랜치에 **PR 게이트 기록이 있으면 플래그 없이도
리뷰한다** (`laneMeta['code-reviewer'].forcedBy = pr-gate-recorded`).

그 기록에 **만료는 두지 않는다.** PR 은 며칠씩 열려 있고, 낡았다는 이유로 리뷰를 멈추면
오래된 PR 일수록 안 보게 된다 — 판단이 안 서면 더 도는 쪽으로 기우는 이 파일의 원칙 그대로다.

- **붙인다**: 설계가 바뀌는 커밋, 영속·재시도·부수효과를 건드린 커밋, PR 직전 마지막 커밋
- **안 붙여도 된다**: PR 생성 **전에** 쌓아 올리는 중간 커밋 — PR 게이트가 합쳐서 본다.
  PR 생성 **이후** 커밋은 자동으로 붙으므로 신경 쓸 필요 없다

모르는 플래그는 **거부한다**(exit 2). `--reveiw` 오타가 조용히 무시되면 리뷰를 붙였다고
믿는데 안 도는 것이 이 플래그의 최악의 실패 모드다.

## 2. 게이트 (워크플로)

이 스킬은 Workflow 호출을 지시한다 — 사용자 opt-in 으로 간주한다.

**`preflight-run.sh prepare` 의 출력(`action=workflow`)이 이 호출의 인자다** — `Workflow({ scriptPath: <출력의 scriptPath>, args: <출력의 args> })`.
`round`·`priorFindings`·`prBodyFile` 은 prepare 의 `--round=N`·`--prior=<파일>`·`--body-file=<초안>` 에서 채워진다. 아래는 그 인자의 뜻이다.

```
Workflow({ scriptPath: "$P/preflight.js" 의 절대경로 (심링크면 원본 경로; 읽을 수 있는 파일이어야 한다),
           args: { repo, mode, round, classification: <1번의 JSON 그대로>,
                   priorFindings: <직전 라운드 결과의 findingIds>,
                   prBodyFile: <PR 게이트: 본문 초안 파일의 절대경로>,
                   runId: <같은 분류·라운드를 겹쳐 돌릴 때만 — 실행마다 다른 문자열> } })
```

**`runId` 는 보통 넘기지 않는다.** 실행마다 갈라야 하는 값(재측정 스냅숏 폴더 이름의 꼬리)은 1번의 분류가
호출마다 뽑는 `classification.runNonce` 에서 온다 — 워크플로 스크립트는 `Math.random()`·`Date.now()` 를
쓸 수 없어서(resume 이 같은 값을 재현해야 한다) 난수를 분류기가 만든다. 그래서 **게이트마다 분류를 새로
돌린다.** 같은 분류 JSON 을 겹쳐 돌리는 실측(`eval/flip.sh`)만 실행마다 다른 `runId` 를 넣는다 — 넣으면
`runNonce` 보다 우선한다. 둘 다 없으면 꼬리는 `shared` 다.

**분류 JSON 이 커서 인라인으로 못 넘기면**(PR 모드 분류가 100KB 를 넘는 경우 등) `classification` 대신 데이터 스크립트 경로와
내용 해시를 넘긴다 — `classificationScript`(아래 블록이 쓰는 `claude-preflight.classify.wf.js` 의 절대경로)와
`classificationSha256`(그 classify.sh 실행이 stderr 에 낸 `classify-sha256:` 값). 데이터 스크립트는 classify.json 을 문자열
리터럴 하나로 담은 Workflow 스크립트이고, 워크플로가 `workflow({scriptPath})` 로 불러 바이트를 그대로 받는다 — 에이전트가
내용을 중계하지 않는다. 둘을 함께 주거나 인라인과 섞으면, 또는 옛 `classificationFile` 을 주면 워크플로가 오류로 끝난다.
워크플로는 받은 바이트의 sha256 을 이 값과 대조해 다르면 lane 을 하나도 돌리지 않는다 — 블록을 다시 돌려(같은 인덱스의
`--qa` 재분류 포함) 데이터 스크립트가 덮어써진 경우다.

**데이터 스크립트를 쓰는 폴더는 세션이 읽을 수 있어야 한다** — Workflow 는 작업 폴더와 추가된 폴더 밖의 scriptPath 를
거부한다. 기본값은 대상 레포의 gitdir 이다. worktree 세션처럼 gitdir 가 작업 폴더 밖이면 `PF_CLS_DIR=<세션 scratchpad>` 를
준다. 대상 레포 작업 트리 안(그 `.git` 아래는 제외)은 거부한다 — 작업 트리 파일이 되면 다음 분류에 섞인다.
**중첩은 한 단계다** — `preflight.js` 를 다른 워크플로의 자식으로 돌리면 `workflow()` 가 던져 데이터 스크립트 적재가
실패한다. 그때는 인라인 `classification` 만 쓸 수 있다.
classify.sh 가 0 이 아닌 코드로 끝나면 **args 를 만들지 않고 멈춘다** — 실패한 분류는 파일을 갱신하지 않아 낡은 분류가
남아 있다. 아래 블록이 그 절차다 (1번의 classify 호출을 이것으로 대신한다):

<!-- BEGIN gate-args -->
```bash
# usage: [PF_CLS_DIR=<폴더>] pf_gate_args <repo> <classify.sh 인자…>
#   → stdout: Workflow args 에 합칠 {classificationScript, classificationSha256}
# 절차(분류 실패면 같은 rc·출력 없음, classify-sha256 필수, 데이터 스크립트 쓰기)는 preflight-run.sh 한 벌이다 — prepare 와 같다.
pf_gate_args() { "$P/preflight-run.sh" gate-args "$@"; }
```
<!-- END gate-args -->

`pf_gate_args <repo> pr --body-file=<초안>` 처럼 1번과 같은 인자로 부르고, 나온 두 키를 `classification` 자리에 넣는다.
`selected`·`notSelected` 는 분류 파일에서 읽는다.

**PR 게이트에서는 본문 초안을 먼저 파일로 쓰고 `prBodyFile` 로 넘긴다** — 분류기에도 `--body-file=<같은 파일>` 로 준다(본문만 고친 라운드가 라운드로 세진다). 그리고 PR 은 **그 파일로**
만든다(`gh pr create --body-file <같은 파일>`) — 검사한 본문과 올라가는 본문이 같아진다.
안 넘기면 본문 섹션은 검사되지 않고 `pr-quality` 가 `body/not-provided` 참고 하나만 남긴다
(막지 않는다). 넘긴 파일을 못 읽거나 비어 있으면 `body/unreadable` 로 막는다.

**사실 주장 검사(`claimCheck`)** 는 lane 이 아니라 분류기가 직접 돈다 — 바뀐 `.md`, PR 모드의 커밋
메시지(merge-base..HEAD), `--body-file` 본문, 그리고 커밋 게이트에서 `--msg-file=<커밋 메시지 초안>` 을
주면 그 초안에서 비율·백분율·건수·부재 주장을 뽑고, 붙은 `$ 명령` 블록을 읽기 전용 허용 목록 안에서
다시 돌려 숫자를 대조한다(`claim-extract.sh` → `claim-verify.sh`). 재실행은 OS 샌드박스(macOS `sandbox-exec`: 쓰기·네트워크·허용 밖 실행 금지 / Linux `/usr/bin/bwrap` 최소 루트: 같은 성질, 단 레포 안 실행 파일은 막지 못한다 — DECISIONS.md 「Linux 샌드박스(bwrap)」) 안에서만 하고, 샌드박스가 없는 플랫폼에서는 실행하지 않는다. **판정에 영향이 없다** — 경고는
보고서의 "참고" 로만 나온다. 출처 없는 수치를 지적받으면 명령과 출력을 주장 바로 아래 코드 블록에
`$ 명령` 형태로 붙이거나, 명령을 적을 수 없으면 수치가 아니라 관찰로 고쳐 써라.

**재측정(③)** 은 ②가 못 잡는 경우 — 명령 자체가 틀려 다시 돌려도 같은 숫자가 나오는 경우 — 를 위한 층이다. 분류기가
`claim-remeasure.sh select` 로 대상을 고른다: 추적 중인 `.md` 의 **규칙 줄**(체크리스트 항목, 또는 `하지 마라`·`해야 한다`·
`금지`·`반드시`·`must` 같은 명령·금지 어미가 있는 줄)을 지우거나 바꾼 변경의 비율·백분율·부재 주장이다(`claimCheck.remeasure`).
대상이 있으면 워크플로가 `claim-remeasurer` 에이전트를 **한 번** 부르고(대상은 앞에서부터 상한 K=5 까지, 넘친 수는 보고서에
남는다), 대상이 없으면 부르지 않는다. 에이전트에는 수치를 자리표로 가린 주장 문장과 출처만 가고 원래 명령·출력·숫자는
가지 않는다. 에이전트는 다른 방법으로 다시 재서 모집단·with·without 과 자리 해석만 내고, 일치·불일치·모집단 다름은
워크플로 코드가 숫자로 정한다. 원래 출처 명령과 같은 grep 패턴으로 잰 측정은 `독립성 미확보` 다.
레포 밖 코퍼스는 **등록된 로컬 레포만** 읽는다 — 머신 로컬 `config.json` 의 `remeasureRepos`(`{이름: 경로}`) 또는
`PF_REMEASURE_REPOS=이름=경로,…`. 게이트는 등록 레포를 fetch 하지 않고, 이미 fetch 된 origin 기본 브랜치를 `git archive` 로
임시 폴더에 풀어 그 경로만 에이전트에 준다(마지막 fetch 가 7일을 넘었거나 FETCH_HEAD 가 없으면 사용 불가). 게이트가 끝나면
지운다. **판정에 영향이 없다** — ③은 lane 이 아니고 영수증에 들어가지 않으며, 불일치·모집단 다름·측정 불가·독립성 미확보·
재측정 실패·상한 초과가 전부 보고서의 "참고" 로만 나온다. 불일치를 지적받으면 보고된 측정 방법과 정의를 보고 원래 측정을
다시 확인해라. 근거·한계는 `DECISIONS.md` 2026-11-12.

**lane 은 스냅숏을 읽는다(#8).** 체크아웃이 필요한 lane(test-runner)이 있으면 워크플로가 먼저 `snapshot.sh` 로
분류가 본 트리(커밋 모드 인덱스, PR 모드 HEAD)를 격리 체크아웃으로 풀고 트리 id 를 대조한 뒤 그 경로만 lane 에 준다 —
원본 워킹트리의 미스테이징·미추적 파일은 검사에 들어가지 않는다. 나머지 lane 은 트리 참조(`git show <트리>:<경로>`)로 읽는다.
못 만들면 원본으로 대체하지 않고 그 lane 을 결과 없음(ERROR)으로 둔다. 게이트가 끝나면 지운다.

lane 은 병렬로, qa 는 순차로 돈다. 테스트 lane 이 있으면 merge-base 기준선을 먼저 잡는다.
계획에 `how: review` 항목이 있으면 `requirements-tracer` 는 `code-reviewer` 가 끝난 뒤 그 보고를 받아 돈다.
`how: test` 항목이 있으면 `test-runner` 도 같은 방식으로 앞에 선다 — 이때 tracer 는 기준선과 테스트 실행을
기다리므로 게이트가 그만큼 길어진다 (나머지 lane 과는 여전히 병렬이다).

**"변이 확인" 테스트 항목은 변이 명세가 있어야 닫힌다.** 계획 본체 옆에 `<planId>.mutations.json` 을 둔다
(`plan.sh mutations <repo>` 가 경로를 알려 주고 형식을 검사한다):

```json
{"planId": "<계획과 같은 값>", "cmd": "<변이마다 돌릴 테스트 명령>",
 "mutations": [{"name": "M1", "refs": ["R15/test#3"], "patches": [{"file": "src/x.ts", "find": "<정확히 한 번 나오는 원문>", "replace": "<변이>"}]}]}
```

분류기가 명세를 찾으면 `mutate.sh` 를 test-runner 의 회귀 명령으로 확정하고, test-runner 가 격리 worktree 에서
돌린다(원본 경로면 하네스가 거부한다). 기준 실행이 먼저 통과해야 하고, 참조는 그 변이가 **전부** 테스트를 실패시켜야
닫힌다. 컴파일이 잡은 변이(`compile-error`)와 시간 초과(`timeout`)는 테스트가 잡은 것이 아니라 닫지 않는다. 명세를 계획 본문에 넣지 않는 것은 patch 가 코드와 함께 바뀌기 때문이다 — 본문에 넣으면 고칠 때마다 재승인이다.
집계는 코드가 한다 — **결과를 받아 네가 판정을 다시 내리지 마라.**

## 3. 판정 처리

| verdict | 할 일 |
|---|---|
| `PASS` | **보고하고 승인받은 뒤** 4 로 간다 (아래 § 커밋 전 보고) |
| `FAIL` | blocking 을 고치고 **1번부터** 다시. 부분 재실행 금지 |
| `NEEDS_CONFIRM` | warning 을 사용자에게 보이고 승인받는다. **승인 없이 넘기지 마라** |

**다음 라운드에는 직전 결과의 `findingIds` 를 `priorFindings` 로, `round` 를 +1 해서 넘긴다.**
FAIL 이든 참고만 남은 PASS 든 같다. 그래야 결과의 `recurrence` 가 직전 지적 중 무엇이 다시
나왔고(재발) 무엇이 사라졌는지(해소) 코드로 센다 — 안 넘기면 `null` 이고 아무도 세지 않는다.
재발이 있으면 보고에 그 id 를 그대로 적는다. 한 브랜치에서 9라운드를 두 인자 없이 돌려
같은 부류가 라운드를 넘어 반복됐는데 아무도 몰랐던 적이 있다(2026-09-10).

### 참고(`blocking: false`)는 라운드를 열지 않는다

**blocking 이 0이면 참고가 몇 건이든 그것을 이유로 라운드를 다시 열지 마라.** 보고서의
"참고 (판정에 영향 없음)" 절은 다음 라운드의 할 일 목록이 아니다 — 고치면 새 코드가 생기고
새 코드는 새 검토 표면이라 또 참고가 나온다. 이 회귀의 실측 근거는 `docs/backlog.md` 첫머리에
있다(그쪽이 정본이다. 여기는 게이트를 돌리는 자리에서 그 자리를 가리킬 뿐이다).

참고를 **버리라는 말이 아니다.** `docs/backlog.md` 의 열림 항목으로 등록한다 — 재현 명령·
닫는 방법·**먼저 셀 지표**까지 함께 적어야 나중에 근거 없이 손대지 않는다. 쌓인 것은
따로 모아 한 커밋으로 처리한다.

**예외는 이번 변경이 만든 회귀다.** 비차단으로 보고됐어도 그건 이번 라운드에서 고친다 —
내가 넣은 결함을 백로그로 미루는 것은 남에게 넘기는 것이다. 2026-09-16 에 `--review` 를
넣으면서 `all` 모드의 리뷰 대상이 `logic` 에서 `changed` 로 넓어진 것이 참고로 올라왔고,
이번 변경이 만든 것이라 그 자리에서 고쳤다.

### `FAIL` 을 고치기 전에 — 집합을 먼저 세라

**지목된 사례를 고치지 마라. 그 통제가 걸리는 집합 전체를 열거하고, 열거한 것을 보인 뒤 고쳐라.**

2026-09-10 하루에 같은 부류가 **네 번** 재발했다 — 매번 지적된 한 갈래만 고쳐서다:

| 고친 것 | 놓친 갈래 |
|---|---|
| 저작권 정규식의 한 표기 | JSDoc 태그형·어순 변형 |
| `concealed-promotion` 의 `dict`+`PASS` | 문자열 형태 · `SKIPPED` · `NOT_APPLICABLE` |
| `preflight.js` 의 열거 밖 verdict | `receipt.sh` 의 같은 입력 |
| 전사 **간** 병합의 tie-break | 전사 **내** 채택의 tie-break |

열거하는 방법은 통제의 성격이 정한다 — 값의 집합이면 그 어휘의 **정본 한 곳**에서 파생시키고
(손으로 적으면 갈린다), 코드 위치의 집합이면 `grep` 으로 같은 판정을 하는 자리를 전부 찾는다.

실제로 마지막 사례에서 열거가 리뷰어보다 **한 곳을 더** 찾았다 — 승격 트리거가 어휘를 손으로
적어 `_RANK` 와 갈려 있었다.

### 커밋 전 보고 — `PASS` 도 예외가 아니다

**게이트 통과는 커밋 허가가 아니다.** `PASS` 는 "검사한 lane 이 결함을 못 찾았다" 이지
"이 변경을 담아도 된다" 가 아니다. 무엇을 담을지 보고하고 **사용자 승인을 받은 뒤** 커밋한다.

보고에 넣을 것:

- **동작이 무엇이 바뀌는가** — 파일 목록이 아니라 동작으로 쓴다
- 게이트가 이번에 **무엇을 잡았고 어떻게 고쳤는가**
- **검증하지 못한 것** — 라이브로 못 태운 경로, 스텁으로만 덮은 것, 외삽 불가 범위
- **계약·공개 표면이 바뀌면** 그 사실과 영향 범위

`NEEDS_CONFIRM` 의 warning 승인과는 **별개다** — 그건 waiver 이고 이건 커밋 자체의 승인이다.
`PASS` 인데 warning 이 없어도 보고는 한다.

근거: 같은 세션에서 게이트가 `PASS` 를 준 뒤에도 설계 방향을 통째로 뒤집은 적이 있고
(토큰 영속 → `orderNo` 재조회), `PASS` 상태의 커밋 메시지에 검증되지 않은 주장을 적은 적도 있다.
범위·설계 판단은 게이트가 아니라 사람이 한다.

승인받았으면 그 lane 만 이렇게 바꿔 기록한다 — 승인 사실이 기록에 남아야 한다:

```json
{"status":"PASS","waived":true,"originalStatus":"WARNING","reason":"<사용자가 승인한 내용>"}
```

## 4. 기록 (PASS 일 때만)

**워크플로 결과의 `recorded.status` 가 `RECORDED` 면 기록은 끝났다** — PASS 면 워크플로의 기록 에이전트가 아래와 같은
검사로 `receipt.sh record` 를 이미 돌렸다(로그·영수증 `via: workflow`). record 를 다시 부르지 말고 커밋 전 보고(§ 3)를 거쳐
커밋으로 간다(별도 Bash 호출). `REFUSED`·`ERROR`·`SKIPPED` 면 아래 절차대로 메인이 기록한다 — `recorded.output` 에 거부 사유가 있다.
근거는 DECISIONS.md 「워크플로 안에서 기록」.

```bash
$P/receipt.sh record commit|pr <repo> @<lanes.json> "" <워크플로 전사 디렉터리>
```

`lanes.json` 은 워크플로가 준 `receiptLanes` 를 **그대로** 쓴다. 손으로 줄이거나 채우지 마라.

**전사 디렉터리는 Workflow 결과의 `Transcript dir` 을 그대로 넘긴다.** 이걸 넘기면 기록이
lane 의 **보고**가 아니라 **실행 사실**을 본다 — 각 lane 이 실제로 도구를 실행했는지, 순차 lane 의
순서가 맞았는지, 승인 흔적 없이 통과로 승격되지 않았는지.

안 넘겨도 기록은 되지만 그만큼 검증이 약해진다. **넘겼는데 경로를 못 읽으면 거부한다** —
"안 넘긴 것"(약한 검증을 의도적으로 택함)과 "넘겼는데 못 읽은 것"(사고)은 다르기 때문이다.

최소 증거는 **실행 명령 + 실행 시각 + 종료 상태 + 대상**까지다. 출력 내용이 옳은지는 보지
않는다 — 그건 별도 artifact 가 필요하고 최소 증거의 범위를 넘는다.

**`--qa` 커밋 게이트는 QA 기록을 남긴다** — `<git-common-dir>/claude-preflight.qa/<indexTree>.json`.
시나리오는 전사의 QA 출력에서만 읽는다(전사를 안 넘기면 남지 않는다). 브랜치에 계획이 결속돼 있으면
계획의 `how: qa` 항목(`R2/qa#1`) 중 통과·실패·미실행·덮이지 않음을 코드가 세어 기록 출력에 보인다.
**덮이지 않은 항목이 있으면 커밋 전 보고에 넣는다** — 지금은 막지 않는다.

기록은 결과만 보지 않는다. **분류가 요구한 절차를 밟았는지**도 본다 — 아래 중 하나라도 어긋나면 거부된다:

| 검사 | 거부 사유 |
|---|---|
| 분류 근거가 있는가 | classify.sh 를 안 돌렸다 — 무엇을 검사해야 했는지 모르면 무엇을 안 했는지도 모른다 |
| 분류가 **이 작업 상태**에 대한 것인가 | `index-changed` — 분류 이후 커밋될 내용(인덱스)이 바뀌었다 → 1번부터 다시 |
| 분류가 **이 브랜치**의 것인가 | `branch-mismatch` — 다른 브랜치에서 만든 분류다 |
| 분류가 **이 모드**의 것인가 | `mode-mismatch` — commit 분류로 `record pr` 하면 PR 전용 lane 이 필수 집합에서 통째로 빠진다. `all` 도 PR 을 대신하지 못한다 |
| 분류가 **이 커밋** 위의 것인가 | `stale-head` — `--amend` 처럼 내용은 같고 커밋만 바뀐 경우 |
| 분류가 **진짜 분류 artifact 인가** | `classify-schema-old` — 위 세 결속은 필드의 **값**에 걸려 있어 값이 비면 조용히 꺼진다. `mode` 는 항상, `branch`·`head` 는 커밋이 있는 레포에서 값을 요구하고, `hasHead` 는 키 자체가 없으면 거부한다 |
| **(PR 게이트) vault 에 연결됐는가** | 미등록 레포다 — `github-project-link` 로 먼저 등록하거나, 추적 대상이 아니면 `config.json` 의 `vaultExempt` 에 슬러그를 넣어 **제외로 기록해라**(개인 도구 레포 등). 통과하는 상태는 `REGISTERED`·`SELF`·`EXEMPT`·`UNKNOWN`(등록 대상을 특정할 수 없음)·`NOT_APPLICABLE`(등록 조회는 그 규칙(`vault_link`)을 가진 카테고리만 하므로 그 밖의 레포는 조회하지 않음)이다. 추적 노트가 없으면 드리프트를 감지할 대상조차 없다. 커밋 게이트는 영향 없다 |
| **(PR 게이트) 계획이 승인된 그대로인가** | `plan-changed` — 승인 뒤 claim(requirements·invariants)이 바뀌었다. `/plan` 으로 새 planId 를 만들어 다시 승인받는다. 미승인(`NONE`)은 막지 않고 추적 보고에 표시만 한다 |
| `selected` lane 이 **전부** 기록됐는가 | 결과 없는 lane 은 통과가 아니라 미실행이다 |
| (전사를 넘겼을 때) lane 이 **실제로 도구를 실행**했는가 | `no-lane-evidence` — 보고는 있으나 검사는 없었다 |
| (전사를 넘겼을 때) 순차 lane 의 **순서**가 맞았는가 | `sequence-violated` — 뒤 lane 이 앞 결과 없이 판정했다 |
| (전사를 넘겼을 때) 승인 흔적 없이 **통과로 승격**되지 않았는가 | `concealed-promotion` — 전사 verdict 는 WARNING/FAIL 인데 `waived` 없이 통과로 기록 |
| 넘긴 전사 경로를 **읽을 수 있는가** | `transcripts-unreadable` — 넘겼는데 못 읽으면 위 검사 셋이 조용히 건너뛰어진다 |
| 커밋될 인덱스가 **분류 때와 같은가** | `index-changed` — 분류 뒤 `git add`·인덱스까지 치우는 `git stash` 로 인덱스가 바뀌었다(다른 세션 포함). 1번부터 다시 |
| 레포 루트에 `make-harness-view.sh` 가 있으면 **인덱스의** README 하네스 뷰가 최신인가 | `harness-view-stale` — `--stdout-from-index` 의 생성 블록이 인덱스 README 의 블록과 다르다. `make-harness-view.sh --write-from-index` 로 재생성하고 **마커 블록만** 스테이징한 뒤(`git add -p README.md`) 1번부터 다시(인덱스가 바뀐다). 통째로 `add` 하면 마커 밖에 있던 미스테이징 수정까지 커밋된다 — 재생성은 마커 밖 본문을 워킹트리에서 그대로 다시 쓴다. 어긋난 줄이 출력과 로그에 남는다. **인자 없이 재생성하면 안 된다** — 그 모드는 워킹트리 입력을 읽으므로 입력에 미스테이징 수정이 있으면 거부가 반복된다. **판정의 입력 셋이 모두 인덱스일 때만 판정한다** — 생성 입력(`agents`·`settings.hooks.json`), 대조 대상(README), 그리고 표를 만드는 **생성기 스크립트 자체**. 워킹트리를 보면 재생성 후 `git add` 를 잊은 커밋을 통과시키고, 남의 미스테이징 수정으로 거부한다. **판정하지 않는 경우**(레포 루트에 생성기가 아예 없는 경우만 조용히 넘기고, 나머지는 사유를 출력한다): `make-harness-view.sh` 가 추적되지 않거나 인덱스와 다른 경우, 인덱스에 README 가 없거나 마커가 없는 경우, 생성기가 0 이 아닌 코드로 끝난 경우(2 인자 오류 · 4 판단 불가)와 실행 실패 |
| (`--qa` 커밋 게이트) 커밋될 경로의 워킹트리가 인덱스와 같은가 | `qa-worktree-differs` — dev 배포는 워킹트리를 빌드하므로 QA 가 본 것과 커밋될 것이 갈렸다. `git add` 로 맞추거나 되돌린 뒤 배포·`--qa` 분류부터 다시. `--qa` 여부는 분류 artifact 에서 읽는다 |

분류 뒤 인덱스가 바뀌면 재분류한다 — 결속은 커밋될 인덱스(= lane 이 읽은 스냅숏) 하나에 걸려 있다.
**워킹트리에만 있는 차이는 막지 않는다** — 다른 세션의 미스테이징 수정·미추적 파일, 내 파일의 부분 스테이징,
분류 뒤 남의 파일을 `git stash push -u -- <경로>`·`--keep-index` 로 치우는 것 모두 커밋될 내용을 바꾸지 않는다.
대신 `record` 가 **인덱스와 워킹트리 내용이 다른 경로 목록**을 보여 준다 — 고친 뒤 `git add` 를 잊은 내 파일이
그 목록에 있으면 add 하고 1번부터 다시 한다. 영수증의 `seenTree`(lane 이 본 상태)는 분류의 스냅숏 트리다.
대상 아닌 lane 을 더 돌린 것은 막지 않고 `extraLanes` 로 남긴다.

영수증은 **인덱스 트리**에 묶이고, 훅이 읽을 때 lane 완전성을 한 번 더 검사한다 —
`record` 를 거치지 않고 영수증 파일을 직접 써 넣어도 통과하지 않는다.

## 게이트는 내부 도구다 — 바깥 글에 이름을 쓰지 마라

`secret-scanner`·`vault-linter`·`pr-quality` 같은 lane 이름과 "게이트 통과" 같은 상태는
**이 머신에서만 쓰는 도구**다. **PR 본문·커밋 메시지·PR 코멘트에 쓰지 마라** — 팀은 그게
무엇인지 모르고, 판단에 아무것도 보태지 않으면서 공용 히스토리에 남는다.

- 게이트 실행 결과는 **사용자에게만** 보고한다 (기록은 영수증과 관측 로그에 남는다)
- 변경의 *대상*이 에이전트 정의여도, 바깥 글에는 도구 이름 대신 **무엇이 문제였는지**를 쓴다
  (예: "`code-reviewer.md` 에서 이관" → "규칙이 정본 없이 흩어져 있었다")

## 역할 분담 — 메인은 분해·승인·판정, 구현은 위임

게이트에서 메인이 분류·워크플로 실행·기록만 하고 검사는 lane 에 맡기듯, **구현도 메인이 쥐지 않는다.**
메인 컨텍스트에는 판정에 필요한 것만 남긴다.

| 메인이 한다 | 위임한다 (`agents/implementer.md` 또는 하위 세션) |
|---|---|
| 작업 분해·PR 단위 결정 | 코드·문서 편집 |
| 계획 claim 확정 (`/plan`) | 테스트 작성·변이 확인 |
| 사용자 승인 (커밋·머지·운영 배포) | rebase·충돌 해결 |
| 보고 판정 — diff·PR 상태·테스트 출력과 대조 | 회귀 실행 |

메인이 직접 편집하는 예외는 둘뿐이다.

- **한두 줄 수정** — 지시서를 쓰는 비용이 수정 비용보다 큰 경우
- **메인이 방금 진단한 결함** — 넘기면 받는 쪽이 같은 조사를 다시 한다

위임받은 쪽은 커밋·푸시·머지를 하지 않고 승인을 대신하지 않는다. 승인은 사용자가 메인에 준다.
`implementer` 에는 계획 claim·대상 파일·작업 위치(격리 워크트리)를 넘기고, 돌아온 diff 요약·검증 명령·
검증하지 못한 것을 `git diff --cached` 와 테스트 출력에 대조해 판정한다.

메인의 직접 편집은 `edit-observe.sh` 가 관측 로그에 `event: edit` 로 남긴다(아래 「관측 로그」).
세는 것은 이 관측이 생긴 뒤부터다 — 그 전 수치는 쓰지 않는다.

## 하드 규칙

- **`git add` 와 `git commit` 을 같은 Bash 호출에 넣지 마라.** 훅은 명령 실행 **전**에 인덱스를
  검증하므로 `git add x && git commit` 은 검사되지 않은 내용을 통과시킨다. 훅이 이 형태를 deny 한다.
- `git commit -a` / `-am` 도 같은 이유로 deny 된다. 스테이징은 언제나 별도 호출이다.
- **커밋·PR 대상 레포는 리터럴 절대경로로 적어라: `git -C /abs/repo commit …`.** 훅은 명령을
  실행하지 않고 읽으므로 `$repo`·`$W` 같은 셸 변수나 같은 줄의 `R=/x; cd $R` 대입을 풀지 못하고
  deny 한다. 훅 deny 93건 중 71건이 이 `unresolvable-dir` 였다 — 실수가 아니라 표기 습관이 막힌 것이다.
  재현: `python3 -c 'import json,os;r=[json.loads(l) for l in open(os.path.expanduser("~/.claude/preflight-log.jsonl")) if l.strip()];h=[x for x in r if x["event"]=="hook" and x["outcome"]=="denied"];print(len(h),sum((x.get("reason") or "").startswith("unresolvable-dir:") for x in h))'` (2026-10-21)
- FAIL 이거나 승인 없는 WARNING 상태에서는 **절대 record 하지 마라.**
- 우회에는 **사유가 필요하다**: `PREFLIGHT_SKIP="revert commit" git commit -m "..."`.
  `PREFLIGHT_SKIP=1` 같은 형식적 값(4자 미만, `1`/`y`/`true`/`skip`)은 **deny 된다.**
  사유는 관측 로그에 남는다 — 흔적만 남고 이유가 없으면 나중에 "왜 건너뛰었나"를 셀 수 없다.
- **사용자 확인 없이 우회하지 마라.** 정당한 경우: 게이트와 무관한 파일만 바뀐 경우
  (`.gitignore` 등), 충돌 해결 커밋, revert.

## lane 요약 (진실원은 `classify.sh`, 아래는 읽는 사람을 위한 요약이다)

| 변경 | lane |
|---|---|
| `src` 아래 `.ts/.tsx/.js` 로직 (주석·포맷만이면 제외) | `test-runner` |
| 게이트 자신의 레포(`shell-tool` 카테고리)에서 `hooks/`·`skills/`·`agents/` 변경 | `test-runner` + 분류기가 확정한 회귀 명령(`meta-test`·`lane-contract-check`) — lane 이 고르지 않고, 기록이 전사에서 실행을 센다(`suite-not-run`) |
| `.py` 로직 변경 (주석·공백만이면 제외) + 스냅숏에 `test_*.py`·`*_test.py` (카테고리 무관) | `test-runner` + 분류기가 확정한 Python 회귀 명령(`python-tests…` — pytest 신호(설정·`conftest.py`·구문 트리로 본 함수형/클래스형 테스트·파싱 실패)가 있으면 `python3 -B -m pytest -q -p no:cacheprovider <dirs>`, 없으면 테스트 파일이 있는 디렉터리마다 `python3 -B -m unittest discover -s <dir> [-t <가장 위 패키지의 부모>] -p <패턴>`, 상위 discover 가 이미 수집하는 디렉터리는 뺀다). 카테고리 회귀 명령에 더해지고, `suite-not-run` 으로 실행을 센다. 테스트가 없으면 지금처럼 빠진다 |
| **커밋 게이트 + `--review`** | `code-reviewer` — 플래그 없으면 `no-review-flag` 로 사유만 남는다 |
| **커밋 게이트 + PR 생성 이후** | `code-reviewer` (**플래그 없이도 돈다** — 영수증의 PR 기록으로 판정, 만료 없음) |
| **PR 게이트 + code 변경** | `code-reviewer` (**플래그 없이도 돈다** — PR 생성 시점까지를 합쳐서 본다) |
| `wiki/ projects/ outputs/ areas/` 의 `.md` (`vault` 카테고리) | `vault-linter` |
| `@types/**`, `package.json` 의 version·의존성 | `crossrepo-impact` |
| `@types/tsconfig.build.json` 이 전이적으로 닿는 소스 | `crossrepo-impact` |
| 무엇이 바뀌든 | `secret-scanner` — 카테고리가 `SECRET_SCAN = 'auto'` 면 결정론 스캔(`secret-scan.sh`, 패턴 정본 `secret-patterns.json`)이 `HITS`·`SENSITIVE_PATH`·`SCAN_ERROR` 일 때만 돈다(`CLEAN` 이면 `secret-scan-clean` 사유). 상수가 없거나 `'always'`, 또는 `all` 모드면 **항상**. 기록이 같은 대상을 다시 스캔해 분류와 다르면 `secret-scan-mismatch` 로 거부한다(PR 모드에서 분류 뒤 base 가 움직였으면 `secret-scan-base-moved`). 기록은 선언 카테고리의 `rules.py` 로 모드를 다시 구해, always 인데 `secret-scanner` 결과가 없거나 선언 모드와 다르면 `secret-scan-mode-mismatch` 로 거부한다. 그 앞에서 같은 대상으로 카테고리 소속을 다시 판정해 선언과 다르면 `category-mismatch` 로 거부한다 |
| PR 게이트 | `pr-quality`, (등록 조회 규칙이 있는 카테고리이고 vault 등록 레포면) `vault-sync` — **미등록이면 lane 이 아니라 기록 자체가 거부된다** (다른 카테고리는 등록 조회를 하지 않는다 — `vaultLink.status = NOT_APPLICABLE`) |
| PR 게이트 + 계획 artifact 존재 | `requirements-tracer` (계획에 `how: review` 항목이 있으면 `code-reviewer` → `requirements-tracer`, `how: test` 항목이 있으면 `test-runner` → `requirements-tracer` 순차) |
| **커밋 게이트 + `--qa`** (배포 후) | `qa-runner` → `qa-reviewer` (순차, **prod 접근 금지**). QA 의 기본 자리다 |
| PR 게이트 + code 변경 | QA 는 **강제하지 않는다** — 사유만 기록 (`qa-done-at-commit-gate` / `not-deployed-at-pr-gate`). 위 § 0 |

## 규칙을 넣을 때 — blocking 은 위반율만으로 정하지 않는다

규칙을 **넣는 것**과 **막는 것**은 다른 결정이다. 넷을 함께 본다:

| 축 | 묻는 것 |
|---|---|
| **위반율** | 지금 작업 흐름을 얼마나 막는가 — **강제 비용**의 축이지 정당성의 축이 아니다 |
| **영향도** | 위반이 실제 사고·품질 저하로 이어지는 크기 |
| **복구 비용** | 나중에 고치기 얼마나 어려운가 |
| **자동 수정 가능성** | 게이트가 즉시 해결해줄 수 있는가 |

위반율만 쓰면 **"이미 다들 지키는 규칙만 강제한다"** 는 편향이 생긴다 — 아무도 안 지켰지만
지켜야 하는 규칙이 영원히 advisory 로 남는다. 실제로 이 게이트는 이미 4축을 쓰고 있었다:
`secret-scanner` 는 위반율과 무관하게 돈다(영향도가 재앙적이고 복구 비용이 크다) — 결정론 스캔이 깨끗하다고 판정한 변경만 LLM 단계를 건너뛰고, 그 판정은 기록 단계가 다시 확인한다.
명문화된 규칙이 실무보다 좁았던 것이다.

기존 판정의 근거는 각 검사기 주석에 있다 — 예: base 브랜치는 위반 7.4%지만 정당한 예외
(릴리즈 PR·스택 PR·신규 레포 초기화)라 advisory, 커밋 언어는 영향도가 낮고 문서 저장소
위반율이 34%라 그쪽만 advisory.

## 수치를 쓸 때 — 재현 가능한 명령의 출력만 수치다

**수치 주장은 재현 가능한 명령의 출력이어야 한다. 명령을 적을 수 없으면 수치를 쓰지 마라.**

일회용 스크립트로 센 값은 수치로 쓰지 말고 **관찰로 적는다.**

| 기록 | 허용 |
|---|---|
| `convention-check.sh` 가 출력한 `400/404` | 수치로 기록 가능 — 명령을 적는다 |
| 그 자리에서 쓴 파이썬으로 센 `400/404` | **금지** — "표본에서 다수가 준수" 로 적는다 |
| "정규식 검증 결과 84% 미준수" | **금지** — 검증 명령이 명시되지 않았다 |

2026-09-09 에 정본 문서의 규칙 하나를 "84% 미준수" 라며 제거하는 변경이 커밋 게이트·PR
게이트를 모두 통과해 머지됐다. 일회용 정규식이 표기 변형 하나를 놓쳐 나온 정반대 결론이었고
(실제 400/404 준수), 잡은 것은 사람이었다. **게이트는 사실 주장을 검사하지 않는다** —
그래서 수치를 쓰는 쪽에 규칙을 건다.

## 알려진 한계 — 알고 쓰는 것과 모르고 당하는 것은 다르다

- `codeLogicChange` 는 diff 라인이 전부 주석/공백인지로 보는 **휴리스틱**이다. 불확실하면 도는 쪽으로 기운다.
- **PR 모드는 `origin/HEAD` 로 해석한 base 와의 merge-base 부터 HEAD 까지의 커밋**을 변경 집합으로 본다
  (commit 모드는 HEAD 대 인덱스). 로컬 base 브랜치가 낡아도 `origin` 기준이라 영향받지 않지만,
  `origin` 을 fetch 하지 않았으면 merge-base 가 뒤처져 변경 집합이 과대해진다. `origin/HEAD` 가 없으면
  `origin/develop|master|main` 순으로 폴백하고, 그마저 없으면 첫 커밋부터 HEAD 까지 전부를 보며
  (덜 보는 쪽이 아니라 더 보는 쪽) 사유를 분류 JSON 의 `base.error` 에 남긴다.
- 공개 타입 표면은 **로컬 상대 import 폐포**다. `paths`/`baseUrl` alias 와 패키지 import 는 따라가지 않는다.
  정확한 표면이 필요해지면 `tsc --listFiles` 로 바꾼다.
- 훅의 커밋 경로는 `indexTree` 만 대조한다. **통과 후 같은 인덱스 트리로 하는 재커밋·`--amend` 는
  같은 영수증으로 다시 통과한다** (실측: record→verify→커밋→verify→amend→verify 전부 rc=0).
  `record` 의 `stale-head` 는 이 경로를 막지 못한다 — 훅이 `record` 를 다시 거치지 않기 때문이다.
- 훅은 명령 문자열 어디에든 `git commit` 리터럴이 있으면 잡는다(echo 안이라도). 과탐이지만 fail-closed 다.
- 커밋 메시지에 `-a` 가 들어가면 스테이징 플래그로 오인해 deny 한다.
- vault 연결 판정은 `projects/@<org>/<repo>/README.md` 의 **frontmatter `repo:` 값**으로 확정한다.
  폴더명이 달라도 `repo:` 가 맞으면 등록으로 본다. origin 리모트가 없으면 `UNKNOWN` 이라 막지 않는다 —
  등록할 대상을 특정할 수 없는 것을 미등록으로 취급하면 로컬 전용 레포가 영원히 막힌다.
- `vault-sync` 는 드리프트로 PR 을 **막지 않는다** — 종류(이번 변경 / 원래 있던 / 확인 필요)와 무관하게 참고이고
  verdict 는 PASS 다. 드리프트는 아래 § vault 대기 목록에 적재된다. 예전에는 기존 드리프트가 WARNING 이라
  승인을 받아야 했는데, 기록된 실행 187건 중 126건이 그 승인이었다 — 거의 매번 넘기는 승인은 진짜 경고도
  같이 넘기게 만든다. 그 뒤 이번 변경 드리프트만 막던 단계에서는 기능 하나에 브랜치·머지·배포마다 vault 커밋이 생겼다.
  재현(출력: 실행 수 · 승인 수): `python3 -c 'import json,os;r=[json.loads(l) for l in open(os.path.expanduser("~/.claude/preflight-log.jsonl")) if l.strip()];v=[(x.get("laneDetail") or {}).get("vault-sync") for x in r if x["event"]=="record" and x["outcome"]=="recorded"];v=[d for d in v if isinstance(d,dict) and d.get("status")!="SKIPPED"];print(len(v),sum(bool(d.get("waived")) for d in v))'` (2026-10-27, 이 변경 전 기준 — 이후 기록은 승인이 0 이어야 한다)

## vault 대기 목록 — 드리프트는 모았다가 한 번에 반영한다

PR 시점에는 마일스톤 완료가 아직 참이 아니다. 그때 노트 갱신을 강제하면 기능 하나에 vault 커밋이 여러 개 생긴다.
그래서 PR 게이트는 드리프트를 막지 않고 **적재**하고, 반영은 머지 뒤 한 번에 한다.

- **적재** — `record pr` 이 전사의 `vault-sync` 출력(`drifts[]`)을 읽어 그 레포의 대기 목록에 쓴다. lane 이 아니라
  하네스가 쓴다(`vault-sync` 는 `writes: false` 그대로). 등록 레포(`REGISTERED`)만 대상이다 — 미등록·`EXEMPT`·
  `SELF`·`UNKNOWN` 은 파일을 만들지 않는다. 전사를 안 넘기면 드리프트를 읽을 수 없어 그 사실이 보고된다.
- **위치** — `~/.claude/vault-queue/<org>__<repo>.json`. 머신 로컬, origin 슬러그마다 파일 하나(클론·워크트리가 달라도
  같은 파일). 쓰기는 잠금으로 직렬화하고 최대 10초 기다린다. **vault 레포 안에 두지 않는다.**
  같은 레포·노트·필드의 대기 항목은 하나만 남는다(게이트를 다시 돌려도 늘지 않는다). `PF_VAULT_QUEUE_DIR` 로 바꾼다.
- **적재 실패는 기록을 막지 않는다** — 대신 `record` 출력과 관측 로그(`vaultQueue`)에 미기록 건수·사유
  (`lock-timeout`·`io-error`·`no-transcripts` …)·레포가 남는다. 보고에 이 줄이 보이면 사용자에게 전한다.
- **경고** — 그 레포의 가장 오래된 대기 항목 뒤 **머지된 PR 3건 이상** 또는 **7일 이상**이면 `record pr` 이
  `⚠️ vault 미반영 N건` 을 낸다. 막지도, 승인을 요구하지도 않는다. 머지 수는 **근사**다 — gh 를 부르지 않고 이
  체크아웃의 PR 게이트 기록(영수증)으로 센다. 게이트 없이 머지된 PR·다른 클론의 게이트는 빠지고, 게이트만 돌리고
  머지하지 않은 PR 은 들어간다. 7일 기준이 바닥을 받친다.
- **머지 보고** — `report pr` 에 `vault 미반영 N건` 줄(등록 레포만). N 은 반영 중인 항목도 센다 — 반영 vault PR 이
  머지돼야 빠진다.
- **반영** — `vault-batch-sync` 스킬. 대기 목록을 실행 시점의 원격 상태(대상 레포 추적 브랜치·vault `origin/master`)로
  다시 대조해 반영 대상·보류·폐기를 가르고, 사용자 승인 뒤 등록 레포 전체를 vault 커밋 하나·PR 하나로 반영한다.
  결정론 단계(적재·분류·정리·커밋 조립)는 그 카테고리의 `vault-queue.sh` 가 한다.
- `requirements-tracer` 는 이 브랜치에 계획이 결속돼 있을 때만 돈다(`plan.sh resolve` 가 `FOUND`).
  계획이 없거나(`NONE`) 포인터가 가리키는 본체가 없으면(`DANGLING`) 게이트를 막지 않고 사유를 남긴다.
- 절차 검증은 **lane 의 존재 여부**만 본다. 실행 순서(qa-runner → qa-reviewer)는 artifact 로
  관찰되지 않으므로 검증되지 않는다 — 순서가 실제로 문제가 된 적이 생기면 그때 실행 기록을 남긴다.

## 관측 로그 (`~/.claude/preflight-log.jsonl`)

`record` 와 `verify` 는 결과를 append-only 로 남긴다. **판정에는 개입하지 않는다** —
로그를 못 써도 게이트 동작은 조금도 달라지지 않는다 (메타테스트로 고정).

- `event: record` / `outcome: recorded` — 통과. `required`·`recorded`·`extraLanes`·`notRun`·`waived`,
  PR 게이트의 등록 레포면 `vaultQueue`(적재 건수 또는 미기록 건수·사유, 경고). 단축 경로 기록이면 `via: fast-path`,
  워크플로 안 기록(`--transcripts-marker`)이면 `via: workflow` (record 이벤트 전부 — 거부 포함)
- `event: record` / `outcome: refused` — 거부와 **사유**
  (`lane-status`, `index-changed`, `qa-worktree-differs`, `no-classification`,
   `branch-mismatch`·`mode-mismatch`·`stale-head`·`classify-schema-old` — 분류가 지금 대상의 것이 아님,
   `no-gate-run` — 워크플로를 안 돌려 lane 결과가 전무, `incomplete-lanes` — 일부 미보고,
   `qa-not-executed` — QA 가 통과로 보고됐는데 전사에 URL 이 실린 실행 명령이 0건,
   `suite-not-run` — 분류기가 정한 회귀 명령을 test-runner 가 부르지 않았다,
   `harness-view-stale` — README 의 하네스 뷰가 뒤처졌다,
   `vault-unregistered`, `plan-changed` — PR 게이트에서 결속된 계획의 claim 이 승인 뒤 바뀜,
   `secret-scan-mismatch` — 기록 단계 재스캔이 분류의 결정론 시크릿 스캔과 다르다(분류 artifact 가 바뀜),
   `secret-scan-base-moved` — PR 모드에서 분류 이후 base 브랜치가 움직여 재스캔 범위가 달라졌다,
   `secret-scan-mode-mismatch` — 기록 단계가 선언 카테고리의 `SECRET_SCAN`(all 분류는 always)으로 다시 구한 모드가
   분류의 `secretScan.mode` 와 다르거나, always 인데 `secret-scanner` 결과가 없거나 SKIPPED·NOT_APPLICABLE 이다
   (`detail` 은 원인 코드 목록 — `lane-missing` 재분류 · `lane-skipped` lane 재실행 · `lane-not-applicable` 카테고리 확인 뒤
   lane 재실행 · `mode-differs` 카테고리 규칙 확인 뒤 재분류),
   `category-mismatch` — 기록 단계가 같은 대상(커밋: 인덱스, PR: HEAD)으로 다시 판정한 카테고리가 분류 artifact 의
   `category` 와 다르다(`declared`·`rejudged`),
   `category-unresolved` — 기록 단계의 카테고리 재판정이 끝나지 못했다(`detail`: `overlap` 겹침 · `load-failed` 적재 실패 ·
   `profile` 프로필 적재 실패·신호 불일치 · `error` 실행 실패),
   `fast-path-not-empty` — 단축 경로(`via: fast-path`) 기록인데 분류의 필수 lane 이 있거나 실행 결과를 보고했다,
   `via-unknown` — 모르는 기록 경로 표시(`workflow` 를 표식 없이 붙인 경우 포함),
   `lanes-digest-mismatch` — 기록 에이전트 프롬프트의 `pf-record-lanes=` 줄(또는 `--lanes-b64`)의 디코드 바이트가
   `--lanes-sha256` 과 다르거나 lane 결과의 출처 없이 `--lanes-sha256` 만 왔다(워크플로 안 기록),
   `lanes-payload-unresolved` — 표식이 든 기록 에이전트 프롬프트 또는 그 안의 `pf-record-lanes=` 줄이 하나가 아니다(워크플로 안 기록),
   `transcripts-marker-unresolved` — 표식이 든 최근 워크플로 전사 디렉터리가 하나가 아니다(워크플로 안 기록),
   전사를 넘겼을 때만: `no-lane-evidence`·`sequence-violated`·`concealed-promotion`·`transcripts-unreadable`)
- `event: verify` / `outcome: allowed|denied` — 훅이 실제로 무엇을 통과·차단했는가
- `event: hook` / `outcome: bypassed` — **`PREFLIGHT_SKIP="<사유>"` 로 게이트를 우회한 사건**
  (사유가 함께 남는다. `=1` 같은 형식적 값은 우회가 아니라 `denied` 다)
- `event: hook` / `outcome: denied` — 형태 차단(`add && commit`), 경로 해석 실패, 사유 없는 우회
- `event: hook` / `outcome: hook-unavailable` — receipt.sh 가 없거나 못 돌아 **검사하지 못하고**
  통과시킨 사건. 원인별로 `receipt-missing`·`receipt-not-executable`·`receipt-error` 를 남긴다
- `event: plan_advisory` / `outcome: observed` — 고위험인데 계획이 없는 변경. **분류 시점**에 남으므로
  FAIL 로 끝난 라운드도 표본에 들어간다. 라운드마다 한 건씩 쌓이니 **집계할 때 `repo`+`branch` 로
  dedupe 해라** — `classificationId` 는 내용 해시라 라운드마다 바뀌어 합쳐지지 않는다
- `event: round` / `outcome: classified` — **한 라운드가 시작했다.** 같은 이유로 분류 시점에 남는다:
  세려는 값이 "이 변경에 몇 라운드가 들었는가" 인데 `record` 는 통과한 라운드만 보므로 거기 두면
  셀 수 없다. **결말은 말하지 않는다** — 그건 `record`·`verify` 의 자리다. 집계는
  `repo`+`branch`+`head` 로 묶고 그 안의 서로 다른 `contentDigest` 가짓수를 센다
  (세는 명령은 `docs/backlog.md` 의 `기준을 고치는 비용` 항목에 있다)

위 두 이벤트는 `receipt.sh` 도 훅도 아닌 **`classify.sh`** 가 직접 남긴다 — 게이트 통과를
기다리지 않아야 하는 것들이다. `event: hook` 셋은 훅이 남긴다.

- `event: edit` / `outcome: main|subagent` — 파일 편집 한 번. **`hooks/edit-observe.sh`**(PostToolUse)가 남긴다.
  훅 입력에 `agent_id` 가 있으면 `subagent`(그때 `agentType`), 없으면 `main`. `tool`·`path`·`repo`·`branch`·`sessionId`.
  Bash 는 명령이 편집 모양일 때만 남기고 걸린 패턴을 `bashPattern` 에 적는다(모양 판정이라 근사값).
  **사이드 세션의 편집도 `main` 이다** — 자기 프로세스에서 최상위라서. 판정·차단에는 개입하지 않는다.
  **`subagent` 줄을 통째로 "위임한 편집"으로 세지 마라.** 게이트·QA lane(`test-runner`·`qa-runner` 등)도 검사 중
  임시 폴더를 만들고 지워 같은 `subagent` 로 찍힌다. 위임 구현은 `agentType: implementer` 줄만 센다.
  `general-purpose` 는 구현인지 조사인지 로그로 가를 수 없으므로 따로 둔다. 메인 편집(`main`)은 이 영향을 받지 않는다.
  집계(`outcome`×`agentType`): `python3 -c 'import json,os,collections;r=[json.loads(l) for l in open(os.path.expanduser("~/.claude/preflight-log.jsonl")) if l.strip()];print(collections.Counter((x["outcome"],x.get("agentType")) for x in r if x.get("event")=="edit"))'`

영수증(`.git/claude-preflight.json`)은 매 실행마다 덮어써지므로 **누적 데이터는 이 로그에만 남는다.**
Rev.5 를 논하기 전에 여기서 세어야 할 것: 거부 사유 분포, waiver 빈도, 불필요하게 돈 lane,
게이트 미통과 커밋 시도 횟수. `PF_LOG` 환경변수로 경로를 바꿀 수 있다.

## 엔진 버전 (`ENGINE_VERSION`)

`$P/ENGINE_VERSION` 의 첫 줄(`MAJOR.MINOR`)이 이 게이트 엔진의 버전이다. **손으로 올린다** — 내용 해시로 파생하지 않는
이유는 `DECISIONS.md` 「엔진 버전 표식」.

- `MAJOR` — 기존 레포별 프로필·카테고리가 기대는 엔진 계약을 깨는 변경. `MINOR` — 호환되는 추가.
  그 밖의 엔진 변경(버그 수정·주석·리팩터)은 버전을 올리지 않는다.
- `receipt.sh record` 가 영수증의 브랜치 항목과 관측 로그의 `event: record`(recorded·refused 모두)에
  `engineVersion` 으로 남긴다. 값은 `lib.sh` 의 `pf_engine_version` 하나가 읽는다.
- **기록에서는 판정에 쓰지 않는다.** 파일이 없거나 `MAJOR.MINOR` 형식이 아니면 `null` 로 남기고 기록은 그대로 진행된다
  (meta-test 고정). 단 프로필(엔진·오버레이 `profiles/`)이 있으면 기록의 카테고리 재판정(CONTRACT `category-recheck-at-record`)이
  아래 프로필 결속에서 멈춰 `category-unresolved`(detail `profile`)로 거부된다 — 분류도 같은 이유로 exit 3 이다(meta-test 고정).
- **프로필 결속.** 레포별 프로필은 자기를 만든 엔진 버전을 `engineVersion`(필수, `"MAJOR.MINOR"` 문자열)으로 적는다.
  분류·조회가 프로필을 읽을 때 지금 엔진과 대조해 **MAJOR 가 같고 프로필 MINOR ≤ 엔진 MINOR** 일 때만 적재한다.
  - 프로필 MAJOR 가 낮다 → 엔진 계약이 깨졌다. `DECISIONS.md` 에서 그 MAJOR 의 계약 변경을 보고 프로필을 고친 뒤
    `engineVersion` 을 지금 엔진 버전으로 올린다.
  - 프로필이 엔진보다 새롭다(MAJOR 가 높거나, 같은 MAJOR 에서 MINOR 가 높다) → 설치본 엔진을 그 버전 이상으로 갱신한다.
  - 필드가 없거나 형식이 틀리거나, 프로필이 있는데 `ENGINE_VERSION` 을 못 읽으면 적재하지 않는다.
  - 어느 경우든 형식이 틀린 프로필과 같이 다룬다 — **어느 레포도 분류·조회하지 않고 exit 3**, stderr 에
    `프로필 적재 실패 — …` 와 위 갱신 방법이 나온다. 적재되면 분류·조회 출력의 `profile.engineVersion` 에 실린다.
  - `MAJOR` 를 올리는 변경은 같은 변경에서 `profiles/` 의 모든 프로필을 새 계약에 맞추고 `engineVersion` 을 올린다 —
    안 하면 그 변경의 meta-test(PF6)와 이 레포의 게이트가 멈춘다. 근거는 `DECISIONS.md` 「프로필–엔진 버전 결속」.

## 참고

- 게이트 자신에 대한 회귀 테스트: `$P/meta-test.sh`
- lane 판정 흔들림 측정: `$P/eval/flip.sh` — 고정 입력을 `prepare` 하고 각 `args.json` 으로 이
  워크플로를 k 번 돌린 뒤 `score` 에 결과를 넘긴다. **`agents/<lane>.md` 를 고치면 고친 전후로 잰다** —
  메타테스트는 결정론 코드만 덮고, 정의 변경이 판정을 어떻게 바꿨는지는 이것으로만 보인다.
  측정 결과는 영수증으로 기록하지 않는다. 비용이 lane 실행 k 번이라 자동으로 돌리지 않는다
  lane 의 모델·effort 를 바꿔 비교하려면 `prepare <out> --lane-model=<lane>=<model> [--lane-effort=<lane>=<effort>]`
  로 override 마다 `<out>` 을 따로 만든다(워크플로 `args.laneModel`·`args.laneEffort`). override 가 실린 실행은
  verdict·lane 상태가 `MEASUREMENT_ONLY` 로 나와 영수증에 기록되지 않고(실제 판정은 `lanes[].measuredStatus`),
  데이터 스크립트 적재(`classificationScript`)와 함께 오면 워크플로가 거부한다. 입력이 `<입력>/overlay` 를 들고 오면
  분류는 그 오버레이만 쓴다 — `vault-*`·`node-*` 입력은 엔진 밖 규칙 없이 lane 을 고르게 하는 측정 전용 카테고리를 싣는다
  `overlay-*` 입력은 오버레이 레포의 훅 변경을 재현한다 — 격리 meta-test 가 통과하는데 `test-runner` 가 `~/.claude` 설치본과의
  차이나 끝나지 않은 실행을 이유로 막는지(기대 PASS, 회귀 짝 `-regress` 는 기대 FAIL) 잰다
  측정되는 에이전트 정의는 이 레포가 아니라 **설치본**(`~/.claude/agents`, 오버레이가 덮었으면 오버레이 것)이다 — manifest 의
  `agentSources` 가 실경로를 남기고, 레포 정의와 다르면 prepare·score 가 경고한다
  실행은 `run <out> [--k=N] [--agent=<lane>=<정의 파일>]` 이 헤드리스 세션(`claude -p`)마다 한 번씩 돌리고 `<out>/runs.txt` 를
  남긴다 — 에이전트 정의는 세션 시작 때 고정되므로, 고친 정의는 `--agent` 로 주입해 잰다(manifest `injected`, 정의가 다른 실행은 섞지 않는다)
- 재측정(③) 측정: `$P/eval/flip.sh remeasure-prepare` 로 `eval/claims/remeasure-*.sh` 입력을 만들고 각 `args.json` 으로
  워크플로를 k(≥5) 번 돌린 뒤 `remeasure-score` 에 결과를 넘긴다 — 픽스처별 일치율·기대 불일치 미보고 수가 나온다
- 각 lane 의 판정 기준: `agents/<lane>.md` (로컬 `~/.claude/agents/`, 플러그인 `<plugin>/agents/`)
