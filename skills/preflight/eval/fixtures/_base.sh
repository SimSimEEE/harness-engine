# 고정 입력의 공통 바탕 — 환불 서비스 하나가 있는 develop 브랜치와 그 원격.
# 쓰는 쪽: `. _base.sh <out>` 뒤 브랜치를 따고 변경을 커밋한다. 바탕이 같아야 입력 사이의
# 차이가 기대 판정의 차이 하나로 줄어든다.
set -e
R="$1"; mkdir -p "$R"
git init -q --bare -b develop "$R/origin.git"
git init -q -b develop "$R/r"; cd "$R/r"
git config user.email eval@fixture; git config user.name eval
git remote add origin "$R/origin.git"
mkdir -p src/modules/refunds
printf '{"name":"refunds-api","version":"1.0.0"}\n' > package.json
cat > src/modules/refunds/refund-service.ts <<'TS'
/**
 * `refund-service.ts`
 * @author      fixture <eval@fixture>
 * @date        2026-10-27
 * @copyright   (C) 2026 Acme Co Ltd. - All Rights Reserved.
 */
const NS = 'RFND';

export interface Refund { orderId: string; amount: number; status: 'requested' | 'done' }

export class RefundService {
    constructor(private store: Map<string, Refund>, private pg: { refund(orderId: string, amount: number): Promise<void> }) {}

    public async refund(orderId: string, amount: number): Promise<Refund> {
        const cur = this.store.get(orderId);
        if (cur && cur.status === 'done') return cur;
        await this.pg.refund(orderId, amount);
        const next: Refund = { orderId, amount, status: 'done' };
        this.store.set(orderId, next);
        return next;
    }
}
TS
git add -A; git commit -qm "feat: add refund service"; git push -q origin develop
git remote set-head origin develop

# 금액 검사 — 결함 없는 변경. 두 입력이 같은 코드를 쓴다.
add_amount_guard() {
    python3 - <<'PY'
p='src/modules/refunds/refund-service.ts'; s=open(p).read()
s=s.replace("""        if (cur && cur.status === 'done') return cur;""","""        if (cur && cur.status === 'done') return cur;
        if (!(amount > 0)) throw new Error('400 INVALID - amount:' + amount);""")
open(p,'w').write(s)
PY
}
