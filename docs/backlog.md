# 백로그 — 게이트가 남긴 참고

**참고(`blocking: false`)는 다음 라운드로 끌고 가지 않는다.** 고치면 새 코드가 생기고, 새 코드는
새 검토 표면이라 또 참고가 나온다 — 무한 회귀다. 여기 쌓아 두고 별도 커밋으로 한 번에 처리한다.

판단 근거: 이 하네스를 처음 커밋할 때 첫 커밋에 6라운드, 두 번째에 4라운드가 들었고 그중 절반이
blocking 없이 끝났다. 게이트가 요구한 것이 아니라 참고를 쫓아서 돈 라운드다.

---

## 열림

### 엔진 단독 스위트에 조직 카테고리 의존 단언이 없다
엔진을 오버레이 레포에서 떼어 낼 때(2026-11-17), vault 등록 조회·QA 안내·관례 범위처럼 **카테고리 규칙 훅을
거쳐야 드러나는** 엔진 동작의 단언은 그 규칙을 가진 오버레이 카테고리 스위트로 옮겼다. 오버레이와 함께 돌리면
그대로 검증되지만, 엔진만 돌리면 그 훅 경로(`vault_link`·`QA_HINT`·`convention`·`vault_docs`)는 검사되지 않는다.

→ 닫는 방법: 엔진 meta-test 안에 조직 용어 없는 **테스트 전용 카테고리 픽스처**를 두고, 옮긴 단언을 그 픽스처로 다시 쓴다.

### 기준을 고치는 비용 — `agents/*.md` 변경의 라운드 수
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

