# 백로그 — 게이트가 남긴 참고

**참고(`blocking: false`)는 다음 라운드로 끌고 가지 않는다.** 고치면 새 코드가 생기고, 새 코드는
새 검토 표면이라 또 참고가 나온다 — 무한 회귀다. 여기 쌓아 두고 별도 커밋으로 한 번에 처리한다.

판단 근거: 이 하네스를 처음 커밋할 때 첫 커밋에 6라운드, 두 번째에 4라운드가 들었고 그중 절반이
blocking 없이 끝났다. 게이트가 요구한 것이 아니라 참고를 쫓아서 돈 라운드다.

---

## 열림

### 프로필 영향도가 커밋 제목 형식에 기댄다
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

### flip score 의 드리프트 검사가 prepare·score 사이의 재링크를 못 잡는다
위치: `skills/preflight/eval/flip.sh` score 의 드리프트 계산.

prepare 가 기록한 실경로(`agentSources[l].source`)를 다시 해시하므로, 그 사이 설치본 링크가 다른 정의로 바뀌면 워크플로는
새 정의로 도는데 드리프트는 없다고 나온다.

→ 닫는 방법: 링크 경로(`AGENTS_DIR/<lane>.md`)도 기록하고 score 때 그 실경로가 기록과 다르면 경고한다.

**먼저 셀 것**: 측정 도중 설치를 바꾼 적이 있는지(없으면 우선순위 낮음).

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

---

## 닫힘

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
