#!/bin/bash
# 카테고리 조회 — 레포 경로를 받아 그 레포의 카테고리·근거 신호·절차 요구를 JSON 으로 낸다.
#
# 판정은 classify.sh 와 같은 코드다(classify.sh category 모드). 따로 판정하면 조회와 게이트가 다른
# 카테고리를 말하게 된다. 입력은 classify.sh commit 모드와 같다 — 소속 판정은 인덱스 스냅숏,
# 워킹트리 표식(VAULT_RULES.md)은 워킹트리.
# 읽기 전용이다: classify.json·영수증·관측 로그를 쓰지 않고 vault 를 fetch 하지 않는다.
#
# usage: category.sh <repo>
#   stdout : {"repo", "category"(없으면 null), "evidence": {<이름>: [신호…]}, "procedures": [{id, text}…], "profile", "origin"(슬러그, 없으면 null), "basis"}
#   exit   : 0 정상 · 2 인자 오류 · 3 카테고리 겹침·적재 실패(stderr 에 걸린 카테고리와 근거)
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: category.sh <repo>" >&2; exit 2; }
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/classify.sh" "$1" category
