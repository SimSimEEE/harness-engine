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
