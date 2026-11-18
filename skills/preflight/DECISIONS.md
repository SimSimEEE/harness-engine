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
