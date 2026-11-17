# 재측정(③) 원 사건 위상의 미등록 변형 — API 레포 하나(api-8)가 등록되지 않았다. 코퍼스 일부를 읽을 수 없으므로
# ③ 의 기대는 측정 불가다. 문서 레포의 .md 수치로 대신하면 안 된다.
. "$(dirname "$0")/_apis.sh" "$1" api-8
echo '{"warn":{"claim/no-source":2},"info":{},"verified":0,"remeasure":"unmeasurable"}' > "$R/expect.json"
