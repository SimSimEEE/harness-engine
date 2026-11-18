---
name: harness-profile
description: 처음 보는 레포에 프리플라이트 하네스 프로필을 만든다 — 현황 점검, 이력 실측, 기존 카테고리 확인, force-lane 규칙 후보의 4축 표, 사용자가 승인한 규칙만 프로필에 기록, 스모크, 결정 기록. 요청 시점 훅이 "프로필 없음" 을 띄운 레포에서, 또는 사용자가 "이 레포 하네스 프로필 만들어", "/harness-profile" 을 부를 때 쓴다.
---

# harness-profile — 레포별 프로필 생성기 (#47)

```
status → (카테고리 확인) → measure → table → 사용자 승인 → select → profile.sh init → 스모크 → 결정 기록(프로필이 쓰인 레포)
결정론      사용자            결정론     결정론   채팅에서 명시    결정론    결정론(적재기 확인)    결정론
```

**고르는 것도 세는 것도 스크립트다.** 너는 스크립트를 부르고, 출력을 그대로 사용자에게 보이고, 사용자가 고른 id 를
넘기는 한 칸만 한다. 표의 수치를 고치거나 해석으로 순위를 매기지 마라 — 수치는 재현 명령이 있는 것만 쓴다(design.md § 5).

`P=<이 스킬의 Base directory>/../preflight`, `R=<대상 레포 경로>`.

## 1. 현황 점검

```bash
bash $P/profile-measure.sh status "$R"
```

- `next: "stop"` 이면 **거기서 멈추고** `reason` 과 `stack`(확장자 상위·커밋 수)·`evidence` 를 그대로 보고한다. 멈추는 경우:
  이미 프로필이 있음 · origin 없음 · 맞는 카테고리 없음 · 카테고리 겹침/적재 실패 · 엔진 버전 못 읽음 · 커밋 없음.
- **맞는 카테고리가 없으면 새 카테고리를 만들지 않는다.** 카테고리는 실제로 쓰는 레포가 생겼을 때 따로 만든다 —
  "어느 표식에도 걸리지 않았다" 는 사실과 `stack` 근거를 보고하고 끝낸다.
- 이미 프로필이 있는 레포의 조정 추가는 이 스킬의 범위가 아니다(생성기는 새 프로필만 만든다).

## 2. 카테고리 확인

`next: "measure"` 이면 추론 카테고리(`category`)와 근거(`evidence`)를 사용자에게 보이고 **맞는지 묻는다**.
프로필은 신호 추론을 고정할 뿐이라 다른 카테고리를 고를 수 없다 — 사용자가 다르다고 하면 멈추고, 표식(신호)을 고칠지
사용자와 정한다.

## 3. 이력 실측 → 4축 표

```bash
bash $P/profile-measure.sh measure "$R" > "$TMP/measure.json"     # 기본 비머지 커밋 200개, 창 5커밋 — 커밋당 약 0.6초
bash $P/profile-measure.sh table "$TMP/measure.json"
```

`$TMP` 는 세션 스크래치 디렉터리다(대상 레포·이 레포 안에 두지 않는다). `measure` 는 대상 레포의 공유 클론을 임시로 만들어
**실제 분류기**로 각 커밋을 다시 분류한다 — 대상 레포의 refs·인덱스·워킹트리는 건드리지 않는다.

표를 **그대로** 보인다. 열의 뜻:

| 축 | 값 |
|---|---|
| 위반율(강제 비용) | 커밋 게이트에서 그 lane 이 골라지지 않은 커밋 비율 — 강제하면 이만큼 lane 이 더 돈다 |
| 영향도 | 미선택 커밋 뒤 창 안에 같은 파일을 고친 수정 커밋(`fixPattern`)이 온 비율, 선택된 커밋의 같은 비율과 나란히 |
| 복구 비용 | 그 수정 커밋의 변경 줄 수·커밋 거리 중앙값 |
| 자동 수정 | lane 정의상 없음(셋 다 보고만 한다) |

표 아래 `한계` 줄도 함께 보인다(커밋 재생은 `--review`·PR 게이트 이후 강제를 모른다 등). 후보가 없으면 조정 없는 프로필로 간다.

## 4. 승인

사용자에게 **어느 id 를 넣을지** 묻는다. 채팅에서 id 를 명시한 것만 승인이다 — "다 좋아 보인다" 같은 말을 넓게 읽지 마라.
고르지 않아도 된다(조정 없는 프로필).

```bash
bash $P/profile-measure.sh select "$TMP/measure.json" <id>... > "$TMP/adjustments.json"   # approved = 오늘
```

## 5. 프로필 기록

카테고리 확인과 승인을 받은 뒤에만 실행한다.

```bash
bash $P/profile.sh init "$R" --category <확인한 카테고리> [--adjustments "$TMP/adjustments.json"]
```

`profile.sh` 가 `profiles/<owner>/<repo>.json` 을 쓰고 실제 적재기로 다시 읽어 확인한다 — 적재기가 거부하면 지우고 exit 3.
항목 형식(`id·kind·lane·modes·approved·evidence`)의 정본은 `classify.sh` 의 적재기 하나다.

## 6. 스모크

```bash
bash $P/category.sh "$R"                     # profile.path 가 새 파일, profile.adjustments 가 승인한 항목
bash $P/meta-test-isolated.sh                # 이 레포(하네스) 쪽 — 새 프로필이 모든 레포의 적재를 깨지 않는다(PF6)
```

`meta-test-isolated.sh` 는 하네스 체크아웃(프로필 파일이 생긴 곳)에서 돈다. 실패하면 프로필 파일을 지우고 원인을 보고한다.

## 7. 결정 기록

결정 기록은 **프로필 파일이 쓰인 레포**에 남긴다(대상 레포가 아니다). `profile.sh init` 은 오버레이가 설정돼 있으면
(`config.json` 의 `overlayDir` 또는 `PF_OVERLAY_DIR`) 프로필을 오버레이의 `profiles/` 에, 없으면 엔진의 `$P/profiles/` 에 쓴다.
그래서 결정 기록 자리도 둘로 갈린다:

- 오버레이가 있으면 — 오버레이 레포의 결정 기록 파일(`<오버레이>/docs/DECISIONS.md`) 끝에 절을 더한다.
- 오버레이가 없으면 — 엔진 `$P/DECISIONS.md` 끝에 절을 더한다.

어느 쪽인지는 5단계 `profile.sh init` 출력의 `프로필 생성: <절대 경로>` 줄로 확인한다. `bash $P/category.sh "$R"` 의
`profile.path` 는 `profiles/<owner>/<repo>.json` 상대 경로라 엔진·오버레이를 가르지 못한다.
공개 엔진의 결정 기록에 대상 레포 이름을 남기지 않기 위해서다 — 프로필을 오버레이에 두는 이유와 같다.

```bash
bash $P/profile-measure.sh table "$TMP/measure.json" "$TMP/adjustments.json"   # 승인 열이 붙은 표 — 조정이 없으면 두 번째 인자 생략
```

절 제목은 `## <YYYY-MM-DD> — 프로필 생성: <owner>/<repo>`, 본문은 위 출력 그대로 + 카테고리 확인 사실 한 줄.
그 뒤 프로필 파일과 결정 기록을 **프로필이 쓰인 그 레포**(오버레이 또는 엔진)에 커밋한다 — 커밋은 프리플라이트 게이트를 지난다.

## 하지 않는 것

- 새 카테고리 만들기, 추론과 다른 카테고리로 프로필 쓰기, 기존 프로필 고치기.
- 표에 없는 규칙(관례 검사기·PR 형식 규칙 등)을 프로필에 넣기 — 지금 프로필이 받는 조정은 `force-lane` 하나다.
- 사용자 확인 없이 `profile.sh init` 실행.
