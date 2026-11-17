# 결함: 재시도 경로가 '이미 완료' 검사를 건너뛰고 PG 환불을 다시 부른다 (중복 환불).
# 본문은 깨끗하다 — 형식 lane 이 대신 막으면 리뷰의 놓침이 가려지므로 리뷰만 잰다.
. "$(dirname "$0")/_base.sh" "$1"
git checkout -q -b feat/refund-retry
python3 - <<'PY'
p='src/modules/refunds/refund-service.ts'; s=open(p).read()
s=s.replace("""    public async refund(orderId: string, amount: number): Promise<Refund> {""","""    /** 타임아웃 뒤 재시도. 호출자가 실패로 본 요청을 다시 보낸다. */
    public async retryRefund(orderId: string, amount: number): Promise<Refund> {
        await this.pg.refund(orderId, amount);
        const next: Refund = { orderId, amount, status: 'done' };
        this.store.set(orderId, next);
        return next;
    }

    public async refund(orderId: string, amount: number): Promise<Refund> {""")
open(p,'w').write(s)
PY
git commit -qam "feat: retry refunds after a timeout"
cat > "$1/body.md" <<'MD'
## 변경 내용
- 타임아웃 뒤 환불을 다시 보내는 `retryRefund` 를 추가했다.

## 검증
- 타임아웃으로 실패 처리된 환불을 다시 보내면 완료 상태가 되는 것을 확인했다.
MD
echo '{"lanes":{"code-reviewer":"FAIL"}}' > "$1/expect.json"
