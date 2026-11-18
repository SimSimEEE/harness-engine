#!/bin/bash
# preflight meta-test — 게이트 자신을 검사한다.
#
# 대상은 **결정론적 코어**(receipt.sh, 훅)뿐이다. 에이전트 lane 은 LLM 이라 fixture 가
# flaky 하므로 회귀 게이트로 쓰지 않는다 — 그쪽은 스모크로만 본다.
# 여기 있는 케이스는 전부 2026-09-02 에 실제로 발생했거나 발생할 뻔한 것이다.
#
# 이 파일은 진입점이다. 단언은 아래 파일들에 있고, 한 셸에서 이 순서로 source 된다(상태를 이어 쓴다):
#   meta-test/lib.sh                          공용 머리 — 헬퍼·$T·공용 픽스처 레포
#   meta-test/engine.sh                       엔진 — receipt·훅·분류 공통·plan·QA 기록·스냅숏·사실 주장 검사
#   categories/<이름>/meta-test.sh            카테고리 규칙 — categories.json 의 선언 순서. 파일이 없는 카테고리는 건너뛴다
#   <오버레이>/categories/<이름>/meta-test.sh  오버레이 카테고리 규칙(lib.sh pf_overlay_dir) — 엔진 카테고리 다음, 그 선언 순서
#   meta-test/category-hook.sh                요청 시점 카테고리 표시 훅(#47)
#   meta-test/edit-observe.sh                 메인 편집 관측 훅·구현 위임 정의(#88)
#   meta-test/edit-guard.sh                   메인 세션 레포 편집 차단 훅
#   meta-test/profile-init.sh                 처음 보는 레포 확인 절차(#47)
#   meta-test/profile-measure.sh              프로필 생성기 — 현황 점검·이력 실측·승인 조정 기록(#47)
#   meta-test/overlay.sh                      오버레이 루트·기본 카테고리(fallback)·루트 사이 겹침
#   <오버레이>/meta-test.d/*.sh                오버레이 레포의 추가 스위트 — 이름 순, 맨 마지막
# 새 단언은 그 규칙이 사는 파일에 넣는다. meta-test/ 에 위 목록 밖의 .sh 를 두면 아무것도 돌리기 전에 멈춘다.
set -uo pipefail

# 스크립트가 중간에 cd 하므로 **시작 시점에** 절대경로를 잡는다.
MT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_mt_engine=(lib.sh engine.sh category-hook.sh edit-observe.sh edit-guard.sh profile-init.sh profile-measure.sh overlay.sh)
for _f in "$MT_DIR"/meta-test/*.sh; do
    case " ${_mt_engine[*]} " in *" ${_f##*/} "*) ;; *) echo "meta-test: 목록에 없는 파일 — 드라이버에 넣거나 지워라: $_f" >&2; exit 2 ;; esac
done
_mt_cats=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["categories"]))' "$MT_DIR/categories/categories.json") \
    || { echo "meta-test: categories.json 을 못 읽었다" >&2; exit 2; }
MT_FILES=("$MT_DIR/meta-test.sh" "$MT_DIR/meta-test/lib.sh" "$MT_DIR/meta-test/engine.sh")
while IFS= read -r _c; do
    [ -f "$MT_DIR/categories/$_c/meta-test.sh" ] && MT_FILES+=("$MT_DIR/categories/$_c/meta-test.sh")
done <<< "$_mt_cats"
# 오버레이 카테고리 — 분류기가 읽는 것과 같은 해석(lib.sh pf_overlay_dir)으로 찾는다.
MT_OVERLAY=$(bash -c '. "$1/lib.sh"; pf_overlay_dir' _ "$MT_DIR")
if [ -n "$MT_OVERLAY" ] && [ -f "$MT_OVERLAY/categories/categories.json" ]; then
    _mt_ocats=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["categories"]))' "$MT_OVERLAY/categories/categories.json") \
        || { echo "meta-test: 오버레이 categories.json 을 못 읽었다" >&2; exit 2; }
    while IFS= read -r _c; do
        [ -f "$MT_OVERLAY/categories/$_c/meta-test.sh" ] && MT_FILES+=("$MT_OVERLAY/categories/$_c/meta-test.sh")
    done <<< "$_mt_ocats"
fi
MT_FILES+=("$MT_DIR/meta-test/category-hook.sh" "$MT_DIR/meta-test/edit-observe.sh" "$MT_DIR/meta-test/edit-guard.sh" "$MT_DIR/meta-test/profile-init.sh" "$MT_DIR/meta-test/profile-measure.sh" "$MT_DIR/meta-test/overlay.sh")
if [ -n "$MT_OVERLAY" ] && [ -d "$MT_OVERLAY/meta-test.d" ]; then
    for _f in "$MT_OVERLAY"/meta-test.d/*.sh; do [ -f "$_f" ] && MT_FILES+=("$_f"); done
fi

for _f in "${MT_FILES[@]:1}"; do
    # shellcheck disable=SC1090
    . "$_f"
done

echo
echo "  통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ]
