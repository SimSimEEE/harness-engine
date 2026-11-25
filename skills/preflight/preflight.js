export const meta = {
    name: 'preflight',
    description: '분류 결과대로 lane 을 병렬 실행하고 단일 PASS/FAIL 로 집계한다 (커밋·PR 게이트)',
    whenToUse: '/preflight — classify.sh 결과를 받아 게이트를 실행할 때. 직접 부르지 말고 스킬을 통해 호출한다.',
    phases: [{ title: 'Baseline' }, { title: 'Gate' }, { title: 'QA' }],
};

// ─────────────────────────────────────────────────────────────────────────────
// args: { repo, mode, classification | (classificationScript + classificationSha256), baseline?, round?, prBodyFile?, runId?, autoRecord? }
//   classification 은 classify.sh 의 출력 그대로다. 이 워크플로는 lane 을 **고르지 않는다** —
//   고르는 일은 결정론적 스크립트의 몫이고, 여기서는 실행·집계만 한다.
//   분류 JSON 이 커서 인라인으로 못 넘기면 SKILL.md 의 pf_gate_args 가 내는 classificationScript(데이터 스크립트
//   claude-preflight.classify.wf.js 경로)와 classificationSha256(classify.sh 의 `classify-sha256:` 값)을 넘긴다. 둘 중 하나만 준다.
//   prBodyFile 은 PR 본문 초안 파일 경로다 (PR 게이트만). `gh pr create --body-file` 에 그대로
//   쓸 파일을 넘긴다 — 검사한 본문과 올라가는 본문이 같은 파일이 된다.
// 반환: { repo, mode, round, verdict, lanes, receiptLanes, blocking, warnings, notes,
//         findingIds, baseline, report, next }  ← findingIds 가 다음 라운드 args.priorFindings 의 입력이다
//       notes 는 판정을 바꾸지 않는 참고 findings 다 — 없으면 verdict=PASS 로 온 것이 사라진다.
//       claimRemeasure 는 사실 주장 재측정(③)의 대상·결과다 — 판정·영수증에 들어가지 않는다(대상이 없으면 null).
//       measurement 는 측정 전용 lane override(args.laneModel·laneEffort)다 — 있으면 verdict·lane 상태가 MEASUREMENT_ONLY 다.
//       recorded 는 워크플로 안 기록의 결과 {status: RECORDED|REFUSED|ERROR|SKIPPED, reason, output} 다 — PASS 일 때만
//       기록 에이전트가 `receipt.sh record` 를 부른다(args.autoRecord === false 면 끈다). RECORDED 가 아니면 메인이 기록한다.
// ─────────────────────────────────────────────────────────────────────────────
// BEGIN classification-load — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// CONTRACT: classification-file-verified
// 큰 분류는 Workflow args 인라인으로 넘기지 못한다. 그때는 pf_gate_args(SKILL.md)가 classify.json 을 문자열
// 리터럴 하나로 담은 데이터 스크립트(claude-preflight.classify.wf.js)를 쓰고, 여기서 workflow({scriptPath})
// 로 그것을 자식 워크플로로 불러 문자열을 받는다. 바이트가 모델을 거치게 하지 마라 — agent() 가 출력을 옮겨
// 적으면 문자가 바뀐다(측정: DECISIONS.md "파일 경로 입력").
// 받은 문자열의 UTF-8 바이트 sha256 을 classify.sh 가 그 실행에서 낸 값과 대조하고, 한 바이트라도 다르면
// 어떤 lane 도 돌리기 전에 끝낸다(설계 원칙 1). 해시는 필수다. 적재가 실패해도 다른 경로로 되돌아가지 않는다.
function _sha256Hex(bytes) {
    const K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
    const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const n = bytes.length, total = Math.ceil((n + 9) / 64) * 64;
    const m = new Uint8Array(total);
    m.set(bytes); m[n] = 0x80;
    const bits = n * 8;
    for (let i = 0; i < 8; i++) m[total - 1 - i] = Math.floor(bits / 2 ** (8 * i)) & 0xff;
    const W = new Array(64);
    const rotr = (x, r) => (x >>> r) | (x << (32 - r));
    for (let o = 0; o < total; o += 64) {
        for (let i = 0; i < 16; i++) W[i] = (m[o + 4 * i] << 24) | (m[o + 4 * i + 1] << 16) | (m[o + 4 * i + 2] << 8) | m[o + 4 * i + 3];
        for (let i = 16; i < 64; i++) {
            const s0 = rotr(W[i - 15], 7) ^ rotr(W[i - 15], 18) ^ (W[i - 15] >>> 3);
            const s1 = rotr(W[i - 2], 17) ^ rotr(W[i - 2], 19) ^ (W[i - 2] >>> 10);
            W[i] = (W[i - 16] + s0 + W[i - 7] + s1) | 0;
        }
        let [a, b, c, d, e, f, g, h] = H;
        for (let i = 0; i < 64; i++) {
            const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0;
            const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
            h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
        }
        H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
        H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    return H.map(x => (x >>> 0).toString(16).padStart(8, '0')).join('');
}
function _utf8Encode(s) {
    const out = [];
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
            const d = s.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
        }
        if (c >= 0xd800 && c <= 0xdfff) throw new Error(`짝 없는 서로게이트 (문자 ${i})`);
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
        else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
        else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return out;
}
// 반환: { classification, sha256 } — 인라인이면 sha256 === null.
async function loadClassification(a, workflowFn) {
    const inline = a?.classification;
    const script = a?.classificationScript;
    if (a?.classificationFile != null)
        throw new Error('args.classificationFile 은 더 받지 않는다 — pf_gate_args 가 내는 args.classificationScript(데이터 스크립트 경로)와 classificationSha256 을 넘겨라');
    if (inline != null && script != null)
        throw new Error('args.classification 과 args.classificationScript 를 함께 주었다 — 하나만 준다');
    if (script == null) {
        if (!inline) throw new Error('args.repo 와 args.classification (classify.sh 출력) 이 필요하다');
        return { classification: inline, sha256: null };
    }
    const want = a?.classificationSha256;
    if (typeof script !== 'string' || !script.trim()) throw new Error('args.classificationScript 가 비었다');
    if (typeof want !== 'string' || !/^[0-9a-f]{64}$/.test(want))
        throw new Error('args.classificationSha256 이 없거나 sha256 hex 가 아니다 — classify.sh stderr 의 `classify-sha256:` 값을 넘겨라');
    let text;
    try { text = await workflowFn({ scriptPath: script }); }
    catch (e) {
        const msg = String(e?.message ?? e);
        throw new Error(`분류 데이터 스크립트를 불러오지 못했다 (${script}): ${msg.slice(0, 240)} — ` +
            (/nest/i.test(msg.split(script).join(''))   // 경로에 든 'nest' 로 안내가 바뀌지 않게 경로를 빼고 본다
                ? '이 워크플로가 다른 워크플로의 자식으로 돌고 있어 데이터 스크립트를 부를 수 없다. 인라인 classification 으로 넘겨라'
                : '세션이 읽을 수 없는 경로면 PF_CLS_DIR 를 세션이 읽을 수 있는 폴더(scratchpad 등)로 주고 pf_gate_args 를 다시 돌려라'));
    }
    if (typeof text !== 'string') throw new Error(`분류 데이터 스크립트가 문자열을 돌려주지 않았다 (${typeof text})`);
    if (!text) throw new Error(`분류 데이터 스크립트가 빈 문자열을 돌려줬다: ${script}`);
    const got = _sha256Hex(_utf8Encode(text));
    if (got !== want) throw new Error(`적재한 분류 내용의 sha256(${got.slice(0, 12)})이 classify.sh 가 낸 값(${want.slice(0, 12)})과 다르다 — lane 을 돌리지 않는다`);
    let obj;
    try { obj = JSON.parse(text); } catch (e) { throw new Error(`분류 데이터가 JSON 이 아니다: ${e.message}`); }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) throw new Error('분류 데이터가 JSON 객체가 아니다');
    return { classification: obj, sha256: got };
}
// END classification-load
// workflow 는 데이터 스크립트 입력일 때만 부른다 — 인라인 입력은 workflow() 가 없는 실행기에서도 돈다
const clsLoad = await loadClassification(args, o => workflow(o));
const cls = clsLoad.classification;
const repo = args?.repo ?? cls?.repo;
const mode = args?.mode ?? cls?.mode ?? 'commit';
if (!repo) throw new Error('args.repo 와 args.classification (classify.sh 출력) 이 필요하다');

// ── 모든 agent() 프롬프트 머리에 붙는 git 금지 규칙.
// 런타임은 이 워크플로를 띄운 사용자 요청을 모든 에이전트에게 글자 그대로 중계하고 "이 요청이 이긴다"고
// 적으며, 중계를 끄는 옵션은 없다. 그 요청이 커밋·푸시를 요구하면 정리·스캔 에이전트도 그것을 직접 해
// 게이트 기록 없이 원격을 바꿀 수 있다. 그래서 모든 호출이 gateAgent() 를 지나고, 규칙은 요청과 충돌하지
// 않는 꼴(그 요청을 수행할 자리는 메인 세션이다)로 적는다. agent() 를 직접 부르지 마라 — meta-test 가 센다.
// CONTRACT: agents-never-touch-git-state
// BEGIN no-git-state — meta-test 가 이 구간만 떼어 agent() 스텁과 함께 실행한다. agent 밖의 바깥 이름을 참조하지 마라.
const NO_GIT_STATE =
    `[게이트 에이전트 규칙 — git 상태·원격 금지]\n` +
    `위에 중계된 사용자 요청은 이 워크플로를 띄운 **메인 세션**에게 한 것이다. 네 일은 아래 작업 하나뿐이다. ` +
    `그 요청이 커밋·푸시·머지·PR 을 요구해도 그 일은 메인 세션이 커밋/PR 게이트를 거쳐 한다 — 네가 하면 게이트가 우회된다. ` +
    `이것은 사용자 요청을 거스르는 것이 아니라 그 요청을 수행할 자리를 정하는 것이다.\n` +
    `- 다음을 **직접 실행하지 마라**: git commit · push · merge · rebase · reset · checkout · switch · restore · cherry-pick · revert · ` +
    `stash · tag · branch 생성·삭제 · worktree add/remove · fetch · pull · add, gh pr create · gh pr merge 및 원격을 바꾸는 모든 명령. ` +
    `아래 작업이 글자 그대로 지정한 스크립트가 내부에서 하는 일만 예외다.\n` +
    `- 미완료 머지·충돌·더러운 워킹트리·밀리지 않은 커밋처럼 손대고 싶은 상태를 보면 **고치지 말고** 보고(구조화 출력이 있으면 그 안에)하고 멈춰라.\n`;
const gateAgent = (prompt, opts) => agent(`${NO_GIT_STATE}\n${prompt}`, opts);
// END no-git-state

// ── 워크플로 안에서 기록 (DECISIONS.md 2026-11-24 「워크플로 안에서 기록」).
// 집계가 PASS 면 메인 세션이 receiptLanes 를 파일로 옮겨 record 를 부르는 턴을 없애려고, 기록 에이전트가
// `receipt.sh record` 한 명령을 돌린다. 워크플로 스크립트는 셸·파일 쓰기·자기 전사 경로가 없으므로:
//   · lane 결과는 UTF-8 바이트의 base64 를 기록 에이전트 **프롬프트**의 `pf-record-lanes=` 줄에만 싣고, 명령에는 sha256 만
//     넣는다. receipt.sh 가 표식으로 찾은 wf 디렉터리에서 기록 에이전트 전사의 런타임 입력(첫 응답 전 user 메시지 중 표식이 든 프롬프트)을 읽어
//     그 줄을 디코드하고 sha256 으로 대조한다 — 모델이 옮겨 적는 값은 sha256·표식·레포 경로뿐이다
//     (DECISIONS.md 2026-11-24 「lane 결과는 전사에서 읽는다」).
//   · 전사 디렉터리는 표식(marker)으로 찾게 한다 — 이 표식은 기록 에이전트의 프롬프트·명령에만 실리므로
//     receipt.sh 가 최근 전사에서 그것을 grep 해 이 워크플로의 wf 디렉터리 하나를 고르고, 그 디렉터리로
//     기존 전사 검증(no-lane-evidence·concealed-promotion·sequence-violated)을 그대로 돌린다.
// FAIL·NEEDS_CONFIRM·측정 전용·args.autoRecord === false 면 부르지 않는다 — waiver 는 사용자 승인이라 메인 몫이다.
// 기록이 안 되면(REFUSED·ERROR·SKIPPED) 결과의 next 가 지금까지처럼 메인이 record 하라고 안내한다(폴백).
// CONTRACT: auto-record-pass-only
// BEGIN auto-record — meta-test 가 이 구간을 classification-load 구간과 함께 떼어 실행한다. 그 밖의 바깥 이름을 참조하지 마라.
const RECORD_RESULT = {
    type: 'object', required: ['exitCode', 'stdout'],
    properties: { exitCode: { type: 'integer' }, stdout: { type: 'string' }, stderr: { type: 'string' } },
};
function _b64Encode(bytes) {
    const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let s = '';
    for (let i = 0; i < bytes.length; i += 3) {
        const b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
        const n = (b0 << 16) | (b1 << 8) | b2;
        s += A[(n >> 18) & 63] + A[(n >> 12) & 63] +
            (i + 1 < bytes.length ? A[(n >> 6) & 63] : '=') + (i + 2 < bytes.length ? A[n & 63] : '=');
    }
    return s;
}
// 기록할지와 그 명령. 반환: { skip } 또는 { marker, sha256, payload, cmd }. payload 는 프롬프트에만 싣는 줄이다.
// nonce 는 args.runId || classification.runNonce, clsSha 는 분류 바이트 sha256(인라인 입력이면 분류 객체 직렬화의 sha256).
function autoRecordPlan(o) {
    if (o.verdict !== 'PASS') return { skip: `verdict ${o.verdict}` };
    if (o.measureOnly) return { skip: '측정 전용 실행 (laneModel·laneEffort override)' };
    if (o.autoRecord === false) return { skip: 'args.autoRecord === false' };
    if (typeof o.engineDir !== 'string' || !o.engineDir.startsWith('/'))
        return { skip: '분류에 engineDir 이 없다 (이 엔진보다 낡은 classify.sh)' };
    const bytes = _utf8Encode(JSON.stringify(o.receiptLanes));
    const sha256 = _sha256Hex(bytes);
    const tail = String(o.nonce || '').replace(/[^A-Za-z0-9_-]/g, '').slice(-24) || 'shared';
    const marker = `pf-record:${tail}:${String(o.clsSha).slice(0, 16)}`;
    const q = x => `'${String(x).replace(/'/g, `'\\''`)}'`;
    // record 는 commit|pr 만 받는다. all 분류는 commit 기록으로 받는다(lib.sh pf_ok_modes).
    const kind = o.mode === 'pr' ? 'pr' : 'commit';
    const cmd = `bash ${q(o.engineDir.replace(/\/+$/, '') + '/receipt.sh')} record ${kind} ${q(o.repo)} ` +
        `--lanes-sha256=${sha256} --transcripts-marker=${marker}`;
    return { marker, sha256, payload: `pf-record-lanes=${_b64Encode(bytes)}`, cmd };
}
// 기록 에이전트의 구조화 출력 → recorded. 성공은 종료코드 0 과 receipt.sh 의 `recorded: ` 줄 둘 다다.
function autoRecordStatus(r) {
    if (!r || typeof r !== 'object' || !Number.isInteger(r.exitCode))
        return { status: 'ERROR', reason: '기록 에이전트가 결과를 내지 못했다 (사망·타임아웃·스키마 위반)', output: '' };
    const out = String(r.stdout ?? '') + (r.stderr ? `\n${r.stderr}` : '');
    const output = out.split('\n').filter(l => l.trim()).slice(-12).join('\n');
    if (r.exitCode === 0 && /^recorded: /m.test(String(r.stdout ?? '')))
        return { status: 'RECORDED', reason: 'receipt.sh record 통과 (via workflow)', output };
    if (r.exitCode !== 0)
        return { status: 'REFUSED', reason: `receipt.sh record 종료코드 ${r.exitCode}`, output };
    return { status: 'ERROR', reason: '종료코드 0 인데 `recorded: ` 줄이 없다', output };
}
// END auto-record

const selected = cls.selected ?? {};
const notSelected = cls.notSelected ?? {};
const laneMeta = cls.laneMeta ?? {};
const seqPairs = cls.sequential ?? [];
// 체인은 두 종류다. QA 체인은 dev 에 부수효과를 내므로 Gate 뒤 QA 단계에서 따로 돈다. 나머지는
// **증거 체인**이다 — 뒤 lane 이 앞 lane 의 보고를 판정 재료로 쓴다(code-reviewer → requirements-tracer).
// 증거 체인은 Gate 배치 안에서 돌고, 뒤 lane 만 앞 lane 의 결과를 기다린다. 체인 전체를 Gate 뒤로
// 미루면 code-reviewer 가 나머지 lane 과 겹치지 못해 그 시간만큼 게이트가 길어진다.
// CONTRACT: tracer-after-reviewer
const QA_CHAIN_LANES = new Set(['qa-runner', 'qa-reviewer']);
const qaChains = seqPairs.filter(c => c.some(l => QA_CHAIN_LANES.has(l)));
const gateChains = seqPairs.filter(c => !qaChains.includes(c));
const seqLanes = new Set(qaChains.flat());
const needsOf = {};
for (const c of gateChains)
    for (let i = 1; i < c.length; i++) (needsOf[c[i]] ??= []).push(c[i - 1]);
const round = args?.round ?? 1;

// ── 모든 lane 이 같은 형식으로 답한다. 판정 기준은 각자의 에이전트 정의에 있고,
//    여기서는 그 판정을 **집계 가능한 형태**로만 강제한다.
const VERDICT = {
    type: 'object',
    required: ['lane', 'verdict', 'findings'],
    properties: {
        lane: { type: 'string' },
        verdict: { type: 'string', enum: ['PASS', 'WARNING', 'FAIL', 'NOT_APPLICABLE'] },
        findings: {
            type: 'array',
            items: {
                type: 'object',
                required: ['id', 'blocking', 'summary'],
                properties: {
                    id: { type: 'string', description: '안정적 식별자 — 같은 결함이면 실행이 바뀌어도 같은 값 (예: missing-idempotency-marker)' },
                    blocking: { type: 'boolean', description: '커밋·머지를 막아야 하는가. 참고·제안은 false' },
                    file: { type: 'string' },
                    line: { type: 'integer' },
                    summary: { type: 'string' },
                    fix: { type: 'string' },
                },
            },
        },
        metrics: { type: 'string', description: 'lane 고유 수치 요약 (tsc/jest 결과 등). 없으면 생략' },
    },
};

// ── lane 별 판정→verdict 매핑. 에이전트 정의의 어휘와 이 스키마를 잇는 유일한 자리다.
const MAPPING = {
    'secret-scanner': 'ERROR → verdict=FAIL + blocking=true. WARNING → verdict=WARNING + blocking=false. 발견이 없으면 verdict=PASS. 시크릿 값은 앞 6자만 남기고 마스킹해라.',
    'code-reviewer': '체크리스트 FAIL 항목 → verdict=FAIL + blocking=true. "참고" 는 findings 에 넣되 blocking=false 이고, 참고만 있으면 verdict=PASS 다 — 이 lane 에 WARNING 층은 없다.',
    'test-runner': '기준선 대비 **새로** 깨진 것만 verdict=FAIL + blocking=true. 기존 실패는 findings 에 blocking=false 로 남기고, 그것뿐이면 verdict=PASS 다. metrics 에 tsc/jest 수치를 넣어라.',
    'vault-linter': 'ERROR → verdict=FAIL + blocking=true. WARNING → verdict=WARNING + blocking=false. 둘 다 없으면 verdict=PASS (secret-scanner 와 같은 어휘다).',
    'pr-quality': '검사기 출력의 error → verdict=FAIL + blocking=true. warn 은 blocking=false 이고 error 가 0이면 verdict=PASS 다 — advisory 뿐인데 WARNING 을 내면 사람을 세운다. 이 lane 에 WARNING 층은 없다. 본문 초안이 **주어졌는데** 요약 성격·검증 성격 섹션 중 하나라도 없으면 id `missing-pr-body-sections` + blocking=true. 초안이 **없으면** 본문은 판정하지 않는다 — 검사기의 `body/not-provided` warn(blocking=false)을 그대로 옮기는 것이 전부이고, `missing-pr-body-sections` 를 내지 마라 (없는 본문의 섹션은 누락이 아니라 미검사다).',
    'crossrepo-impact': 'BREAKING → verdict=FAIL + blocking=true. VERIFY(소비 레포 tsc 필요) → verdict=WARNING + blocking=false. SAFE → verdict=PASS.',
    'vault-sync': '드리프트를 **이번 변경이 만든 것(kind=change)**·**원래 있던 것(existing)**·**확인 필요(confirm)** 로 갈라 drifts[] 에 하나씩 넣어라. 드리프트는 종류와 무관하게 게이트를 막지 않는다 — findings 에는 blocking=false 참고로만 남기고 verdict=PASS 다(PR 시점에는 마일스톤 완료가 아직 참이 아니다. 하네스가 drifts[] 를 레포별 대기 목록에 적재하고, 노트 반영은 일괄 반영 진입점이 머지 뒤 원격 상태로 다시 대조해 한다). 이 lane 에 WARNING 층은 없다. SYNCED → verdict=PASS, drifts=[]. 막는 것은 에이전트 정의의 ERROR 하나뿐이다 — vault 문서에 개인 게이트 어휘가 있으면 verdict=FAIL + blocking=true. **파일은 여전히 쓰지 마라** — 판정과 제안까지가 네 역할이다.',
    'requirements-tracer': 'claims[] 에 계획의 **모든** requirement/invariant 를 하나씩 넣고 impl·verify·validate 를 각각 판정한다(해당 없는 축은 NA). 계획의 requirement/invariant 중 **닫히지 않은 것**(MISSING/PARTIAL) → verdict=FAIL + blocking=true. 전부 닫혔으면 verdict=PASS. 계획이 없으면(BLOCKED) 요구사항을 지어내지 말고 verdict=NOT_APPLICABLE 로 끝내라. "계획에 없는데 구현된 것" 은 blocking=false 로 남기고, 그것뿐이면 verdict=PASS 다.',
    'qa-runner': '실패한 시나리오 → verdict=FAIL + blocking=true. 대상 변경을 한 번도 실행하지 못한 BLOCKED 도 verdict=FAIL 이다 — 미실행은 통과가 아니다. 전부 통과면 verdict=PASS. scenarios 는 계획이 없어도 실행한(또는 못 한) 시나리오마다 채운다. **운영(prod) 에는 접근하지 마라.**',
    'qa-reviewer': 'INVALID → verdict=FAIL + blocking=true. THIN 은 통과시키면 안 된다고 보면 verdict=FAIL + blocking=true, 아니면 verdict=WARNING + blocking=false 로 사람이 정하게 둔다. ADEQUATE → verdict=PASS.',
};

// 규칙 대조가 전부인 lane 은 추론 깊이가 필요 없다. 임계경로에 있는 것만 낮춘다.
// 이 맵은 낮추는 쪽 전용이다. 올리는 쪽(판단 lane 의 effort: high)은 에이전트 frontmatter 가 정본이다.
// secret-scanner 는 **아무것도 낮추지 않는다** — 임계경로가 아니고, 놓쳤을 때 비용이 비대칭이다.
const EFFORT = { 'vault-linter': 'low', 'pr-quality': 'low' };

// ── 지적 id 는 lane 이 짓지 않는다 (어휘가 있는 lane 만).
// 같은 입력을 5번 돌리면 판정은 같은데 id 는 최빈값이 2~3회뿐이었다 — 직전 라운드 id 와 맞춰
// 재발을 세는 집계가 성립하지 않는다. lane 은 닫힌 어휘에서 rule 을 고르고 결함이 있는 심볼을
// 적는다. id 는 코드가 rule·파일·심볼로 만든다(findingId). 어휘가 없는 lane 은 종전대로 lane 의 id 를 쓴다.
// vault-linter·test-runner 는 haiku 로 내린 뒤 최빈 id 점유가 2/5·1/5 였다(DECISIONS) — 그래서 어휘를 둔다.
// 어휘의 정본은 여기와 검사기(pr-format-check.sh --rules)다 — lane 정의에 옮겨 적지 마라.
// BEGIN finding-rules — meta-test 가 이 구간을 `const laneMeta = {}` 뒤에 붙여 실행한다. laneMeta 밖의 바깥 이름을 참조하지 마라.
// CONTRACT: finding-rules-one-place
const RULES = {
    'code-reviewer': {
        'duplicate-side-effect': '외부 부수효과(결제·환불·발송·외부 쓰기)가 같은 요청·재시도·동시 호출에서 두 번 날 수 있다. 원인이 가드 누락이든 마커 시점이든 결과가 이것이면 이 rule 이다',
        'persistence-timing': '저장돼야 할 상태가 저장되지 않거나 저장 시점이 틀려 다음 요청이 틀린 상태를 본다 (그 결과가 부수효과 중복이면 duplicate-side-effect)',
        'missing-validation': '필수값·범위·형식 검사가 없거나 강제변환($T 등)으로 대신했다',
        'contract': '응답 형태·에러 문자열·타입·공개 API 계약이 어긋난다',
        'time-offset': '타임존 offset 이 실제로 먹지 않는 시간 계산',
        'misplaced-code': '설계상 잘못된 레이어·자리에 놓인 코드',
        'comment-false-claim': '주석의 메커니즘 주장이 코드·호출부와 다르다',
        'comment-history': '주석에 수정 경위·디버깅 과정이 들었다',
        'convention': '관례 문서 체크리스트 위반',
        'other': '위 어디에도 맞지 않는다',
    },
    // 검사기 rule 은 분류기가 검사기에서 받아 온다(laneMeta.checkerRules). 못 받았으면 이 lane 도 어휘 없이 돈다.
    'pr-quality': laneMeta['pr-quality']?.checkerRules?.length ? {
        ...Object.fromEntries(laneMeta['pr-quality'].checkerRules.map(r => [r, '검사기가 낸 rule 그대로'])),
        'missing-pr-body-sections': '본문 초안이 주어졌는데 요약 성격·검증 성격 섹션 중 하나가 없다',
        'gate-exposure': '본문·제목이 이 머신 전용 게이트(lane 이름·게이트 통과·영수증 등)를 드러낸다',
        'other': '위 어디에도 맞지 않는다',
    } : null,
    // vault 규칙의 구체 값(enum·형식·한도)은 vault 마다 다르다 — 어휘는 위반의 **종류**만 가른다.
    // file 은 위반이 있는 문서다(append-only 위반이면 수정·삭제된 그 파일).
    'vault-linter': {
        'frontmatter-enum': 'frontmatter 의 enum 키(type·status 등) 값이 규칙이 정한 집합 밖이다',
        'frontmatter-format': 'frontmatter 값의 형식(날짜·목록형 키의 wikilink 배열/문자열/URL)이 규칙과 다르다',
        'frontmatter-missing-key': '템플릿이 요구하는 frontmatter 키가 빠졌다',
        'wikilink-target-missing': 'wikilink 대상 문서가 없다',
        'wikilink-form': 'wikilink 문법이 규칙과 다르거나, 링크하면 안 되는 대상(원본 보관 영역 등)을 링크했다',
        'language': '본문·헤딩·키의 언어 규약을 어겼다',
        'filename': '파일명이 형식·금지 문자·길이 한도·NFC 정규화 규칙을 어겼다',
        'absolute-path': '머신 절대경로(사용자 홈 아래 경로)가 들었다',
        'size-limit': '크기·항목 수 한도를 넘었거나 실행마다 서술이 누적된다',
        'append-only': 'append-only 영역의 파일이 수정·삭제·rename 됐다',
        'personal-data': '개인 데이터(per-item 레이블·개인 파일 경로·로컬 샘플 폴더명·실명·연락처)가 들었다',
        'gate-vocabulary': '개인 프리플라이트 게이트 어휘(게이트 통과·라운드·영수증·lane 이름 등)가 들었다',
        'other': '위 어디에도 맞지 않는다',
    },
    // 원인 추정이 아니라 **어떤 검사가 새로 깨졌는가** 로 고른다. 깨진 소스 함수가 무엇인지는 summary 에 적는다.
    'test-runner': {
        'new-test-failure': '기준선에서 통과하던 테스트가 새로 실패하거나(회귀 명령으로 받은 테스트 러너 실행 포함) 테스트 파일이 새로 로드·컴파일되지 않는다. file 은 실패한 **테스트 파일**이다 — 같은 파일의 테스트 여럿이 깨져도 지적 하나다',
        'type-error': 'tsc 가 새 타입 오류를 낸다. file 은 오류가 난 소스 파일',
        'lint-error': '변경 파일에 eslint error 가 있다. file 은 그 파일',
        'convention-check': '카테고리 관례 검사기가 변경 파일을 지적했다. file 은 그 파일',
        'regression-suite': '분류기가 준 회귀 명령 중 **테스트 러너가 아닌** 스크립트(계약 검사·meta-test 등)가 실패했다. 회귀 명령이 테스트 러너(jest·node --test 등)면 new-test-failure 다. file 은 그 스크립트의 레포 상대경로',
        'preexisting-failure': '기준선에서도 실패하던 것이다 (blocking=false)',
        'not-verified': '검사를 하지 못했다 — 체크아웃·기준선 없음, 변이 하네스 실행 불가, 검사한 설치본이 레포와 다름 등',
        'other': '위 어디에도 맞지 않는다',
    },
};
const rulesFor = lane => RULES[lane] ?? null;
const SYMBOL_HINT = {
    'code-reviewer': '결함이 있는 함수·메서드 이름만 (클래스·괄호·인자 없이, 예: retryRefund). 파일 전체에 걸리면 비워라',
    'pr-quality': '커밋 지적이면 커밋 sha 앞 7자, 그 밖(브랜치·제목·본문)은 비워라',
    'vault-linter': 'frontmatter 지적이면 그 키 이름(예: status), wikilink 지적이면 링크 대상 slug, 그 밖은 비워라',
    'test-runner': 'type-error 면 TS 오류 코드(예: TS2322), lint-error·convention-check 면 검사기의 rule 이름, 그 밖은 비워라 (테스트 이름·줄 번호를 넣지 마라)',
};
// END finding-rules

// BEGIN finding-id — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// CONTRACT: finding-id-is-one-function
// 표기 변형을 접는다: `RefundService.retryRefund()`·`retryRefund` → retryrefund,
// 레포 절대경로·`./` → 레포 상대경로, PR 본문 초안 경로 → pr-body. 줄 번호는 넣지 않는다 — 실행마다 갈린다.
function findingId(f, ctx) {
    if (!f || !f.rule) return f?.id;
    let file = String(f.file ?? '').trim();
    if (file && ctx.prBodyFile && (file === ctx.prBodyFile || file === ctx.prBodyFile.split('/').pop())) file = 'pr-body';
    if (ctx.repo && file.startsWith(ctx.repo.replace(/\/$/, '') + '/')) file = file.slice(ctx.repo.replace(/\/$/, '').length + 1);
    // 스냅숏 절대경로도 레포 상대경로로 접는다 — 라운드마다 경로가 달라도 같은 결함은 같은 id 다(#8 R22).
    file = file.replace(/^.*\/pf-snap\.[A-Za-z0-9]+\//, '');
    file = file.replace(/^\.\//, '');
    const sym = String(f.symbol ?? '').trim().replace(/\(.*$/, '').split(/::|[.#:]/).pop().toLowerCase().replace(/[^a-z0-9_$-]/g, '');
    return `${f.rule}${file ? `@${file}` : ''}${sym ? `#${sym}` : ''}`;
}
// END finding-id

// BEGIN finding-fold — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// 계산된 id 가 같으면 같은 결함이다 — 한 lane 이 같은 id 를 여럿 내면 하나로 접는다.
// 접지 않으면 같은 결함(예: 한 테스트 파일에서 테스트 2개가 깨짐)이 실행마다 1건·2건으로 세진다.
// 기준은 첫 항목: blocking 은 OR, summary·fix 는 서로 다른 것만 ' / ' 로 잇고, label·line 은 첫 것을 남긴다.
// rule 이 없는 항목(id 를 계산하지 않은 것)은 접지 않는다. 어휘가 없는 lane 에는 부르지 않는다.
// CONTRACT: finding-id-dedup-per-lane
function foldFindings(fs) {
    const out = [], byId = new Map();
    for (const f of fs) {
        const hit = f.rule ? byId.get(f.id) : undefined;
        if (!hit) {
            const g = { ...f };
            out.push(g);
            if (f.rule) byId.set(f.id, { g, seen: { summary: [f.summary].filter(Boolean), fix: [f.fix].filter(Boolean) } });
            continue;
        }
        hit.g.blocking = Boolean(hit.g.blocking || f.blocking);
        for (const k of ['summary', 'fix']) { const s = hit.seen[k]; if (f[k] && !s.includes(f[k])) s.push(f[k]); if (s.length) hit.g[k] = s.join(' / '); }
    }
    return out;
}
// END finding-fold

// baseline 전용 스키마. lane 을 enum 으로 묶어 **검증기가 거절**하게 한다.
// 프롬프트로 부탁만 하면 지켜지는지 아무도 확인하지 않고, baseline 이 lane 에 "test-runner" 를
// 쓰면 그 도구 실행이 test-runner 의 증거로 합산돼 no-lane-evidence 를 통과시킨다.
// CONTRACT: lane-enum-per-call
// 전사의 lane 귀속은 **이 필드 하나**에 근거하고, 그 위에 no-lane-evidence·concealed-promotion·
// sequence-violated 세 검사가 얹혀 있다. 프롬프트로 부탁하면 지켜지는지 아무도 확인하지 않으므로
// 호출부마다 enum 으로 묶어 **검증기가 거절**하게 한다.
// QA 실행자는 시나리오 단위로 답한다 — 영수증이 이것을 전사에서 읽어 커밋될 트리에 묶인 QA 기록으로
// 남기고(receipt.sh), 계획 항목 중 무엇이 덮였는지 센다. findings 만으로는 "무엇을 밟았나" 가 남지 않는다.
const SCENARIOS = {
    type: 'array',
    items: {
        type: 'object',
        required: ['name', 'result', 'claimRefs'],
        properties: {
            name: { type: 'string' },
            request: { type: 'string', description: '메서드와 경로 (토큰·키·개인정보 값은 넣지 않는다)' },
            result: { type: 'string', enum: ['PASS', 'FAIL', 'NOT_RUN'] },
            claimRefs: { type: 'array', items: { type: 'string' },
                         description: '이 시나리오가 닫는 계획 항목 참조(예: R2/qa#1). 계획이 없거나 대응 항목이 없으면 빈 배열' },
            note: { type: 'string', description: 'NOT_RUN 이면 왜 못 밟았는가' },
        },
    },
};
// 추적자는 claim 마다 세 축을 답한다 — 머지 보고의 "N개 중 M개 닫힘" 을 영수증이 이것으로 센다.
// 분모는 계획의 claim 목록이다(plan.sh claims). 여기 없는 claim 은 "보고 없음" 으로 열린다.
const AXIS = { type: 'string', enum: ['FOUND', 'PARTIAL', 'MISSING', 'NOT_RUN', 'MANUAL', 'FAIL', 'NA'] };
const CLAIMS = {
    type: 'array',
    items: {
        type: 'object',
        required: ['id', 'impl', 'verify', 'validate'],
        properties: {
            id: { type: 'string', description: '계획의 claim ID (R1, I2 …) 그대로' },
            impl: AXIS, verify: AXIS,
            validate: { ...AXIS, description: '계획에 how: qa 가 없는 claim 이면 NA' },
            note: { type: 'string' },
        },
    },
};
// 리뷰어는 계획의 리뷰 항목마다 무엇을 봤는지 답한다. tracer 가 리뷰 축을 이것으로만 판정한다 —
// verdict=PASS·빈 findings 는 "그 지점을 봤다" 는 근거가 되지 않는다.
const reviewRefs = (laneMeta['code-reviewer']?.planReview?.items ?? []).map(i => i.ref);
const REVIEWED = {
    type: 'array',
    items: {
        type: 'object',
        required: ['ref', 'seen', 'evidence'],
        properties: {
            ref: { type: 'string', enum: reviewRefs },
            seen: { type: 'boolean', description: '그 지점을 실제로 읽고 판정했는가' },
            evidence: { type: 'string', description: '본 파일:줄과 무엇을 확인했는가. seen=false 면 왜 못 봤는가' },
        },
    },
};
// test-runner 도 같다 — "jest 가 통과했다" 는 계획의 테스트 항목이 실행됐다는 근거가 아니다.
// 항목마다 어떤 테스트가 그것을 검사하고, 이번 실행에서 돌았고 통과했는지를 답하게 한다.
const testRefs = (laneMeta['test-runner']?.planTest?.items ?? []).map(i => i.ref);
const TESTED = {
    type: 'array',
    items: {
        type: 'object',
        required: ['ref', 'test', 'ran', 'passed', 'evidence'],
        properties: {
            ref: { type: 'string', enum: testRefs },
            test: { type: 'string', description: '그 항목을 검사하는 테스트 파일과 이름. 없으면 빈 문자열' },
            ran: { type: 'boolean', description: '이번 실행에서 그 테스트가 실제로 돌았는가' },
            passed: { type: 'boolean', description: '돌았고 통과했는가. ran=false 면 false' },
            evidence: { type: 'string', description: '실행 출력의 해당 줄(통과/실패·건너뜀). 못 찾았거나 안 돌았으면 그 이유' },
        },
    },
};
// vault-sync 는 드리프트를 구조로 낸다 — 하네스(receipt.sh)가 전사에서 이것을 읽어 레포별 대기 목록에 적재한다.
// 일괄 반영이 반영 시점에 다시 대조하려면 노트·필드·현재값·제안값·근거가 필드로 있어야 한다. findings 만으로는
// 산문 요약뿐이라 재대조할 수 없다. 필드 표기: frontmatter 키(`status`·`goal`·`next_action`),
// 마일스톤은 `milestones[<이름>].done`, 본문 절은 `## Status` 처럼 제목 그대로(본문 절은 사람이 판단한다).
const DRIFTS = {
    type: 'array',
    items: {
        type: 'object',
        required: ['id', 'kind', 'note', 'field', 'current', 'proposed', 'evidence'],
        properties: {
            id: { type: 'string', description: '같은 드리프트면 실행이 바뀌어도 같은 값 (예: milestone-room-booking-done)' },
            kind: { type: 'string', enum: ['change', 'existing', 'confirm'],
                    description: 'change=이번 변경이 만든 것, existing=원래 있던 것, confirm=확인 필요' },
            note: { type: 'string', description: 'vault 상대 노트 경로 (projects/@<org>/<repo>/README.md)' },
            field: { type: 'string', description: 'status · goal · next_action · milestones[<이름>].done · ## Status 같은 본문 절 제목' },
            current: { type: 'string', description: '노트의 현재값 (없으면 빈 문자열)' },
            proposed: { type: 'string', description: '제안값. 마일스톤 완료는 "true"/"false", 목록은 JSON 배열 문자열' },
            evidence: { type: 'object', properties: {
                commits: { type: 'array', items: { type: 'string' }, description: '근거 커밋 sha' },
                files: { type: 'array', items: { type: 'string' } } } },
            summary: { type: 'string' },
        },
    },
};
const EXTRA = {
    'qa-runner': { scenarios: SCENARIOS },
    'vault-sync': { drifts: DRIFTS },
    'requirements-tracer': { claims: CLAIMS },
    ...(reviewRefs.length ? { 'code-reviewer': { reviewed: REVIEWED } } : {}),
    ...(testRefs.length ? { 'test-runner': { tested: TESTED } } : {}),
};
// ── WARNING 층이 없는 lane 은 스키마가 WARNING 을 거절한다. MAPPING 에 "WARNING 층은 없다" 고 적기만
// 하면 lane 이 어겨도 받아들여, 기존 드리프트를 참고로 내린 뒤에도 vault-sync 가 WARNING 을 내고
// 승인으로 넘어간 실행이 있었다(2026-10-27 17:02, 다른 레포의 PR 게이트). 이 집합과 MAPPING 문구는
// 함께 움직인다 — meta-test 가 둘을 대조한다.
// CONTRACT: no-warning-lanes-enforced
const NO_WARNING = new Set(['code-reviewer', 'pr-quality', 'vault-sync']);
const verdictsFor = lane => VERDICT.properties.verdict.enum.filter(v => !(v === 'WARNING' && NO_WARNING.has(lane)));
const laneSchema = lane => {
    let base = { ...VERDICT, properties: { ...VERDICT.properties, lane: { type: 'string', enum: [lane] },
                                           verdict: { type: 'string', enum: verdictsFor(lane) } } };
    const rules = rulesFor(lane);
    if (rules) {
        const item = VERDICT.properties.findings.items;
        base = { ...base, properties: { ...base.properties, findings: { type: 'array', items: {
            ...item,
            required: ['rule', 'blocking', 'summary'],
            properties: {
                ...item.properties,
                id: { type: 'string', description: '사람이 읽을 짧은 이름. 집계에는 쓰지 않는다 — id 는 rule·file·symbol 로 계산된다' },
                rule: { type: 'string', enum: Object.keys(rules) },
                symbol: { type: 'string', description: SYMBOL_HINT[lane] ?? '결함이 있는 심볼 이름' },
            },
        } } } };
    }
    const extra = EXTRA[lane];
    return extra
        ? { ...base, required: [...VERDICT.required, ...Object.keys(extra)], properties: { ...base.properties, ...extra } }
        : base;
};
const BASELINE_VERDICT = laneSchema('baseline');

const laneList = [...new Set([...Object.keys(selected), ...gateChains.flat()])].filter(l => !seqLanes.has(l));

// ── 측정 전용 lane 모델·effort override — eval/flip.sh 가 같은 입력을 모델별로 잴 때만 쓴다.
// 형태는 `{lane: 값}` 이다. 에이전트 frontmatter 의 model·effort 를 이 실행의 해당 lane 에서만 바꾼다.
// 게이트를 약하게 만드는 통로가 되지 않게 두 겹으로 막는다:
//   ① 데이터 스크립트 적재(classificationScript — 게이트 전용 경로)와 함께 오면 거부한다.
//   ② override 가 하나라도 있으면 결과가 영수증에 쓸 수 없는 꼴이 된다 — verdict·lanes[].status·
//      receiptLanes[].status 가 전부 MEASUREMENT_ONLY 이고(receipt.sh 의 통과 목록에 없다 → record 거부),
//      실제 판정은 lanes[].measuredStatus 에만 남는다(채점기가 읽는다).
// 키는 이번 실행의 lane 이어야 한다 — 오타가 조용히 무시되면 "haiku 로 쟀다" 가 거짓이 된다.
// CONTRACT: lane-override-measurement-only
// BEGIN lane-override — meta-test 가 이 구간만 떼어 args·laneList·clsLoad 스텁과 함께 실행한다.
const LANE_OVERRIDE_VALUES = {
    laneModel: ['haiku', 'sonnet', 'opus'],
    laneEffort: ['low', 'medium', 'high', 'xhigh', 'max'],
};
const laneOverride = name => {
    const v = args?.[name];
    if (v == null) return {};
    if (typeof v !== 'object' || Array.isArray(v)) throw new Error(`args.${name} 는 {lane: 값} 객체다`);
    for (const [l, x] of Object.entries(v)) {
        // QA 체인(seqLanes)은 이 override 가 닿지 않는 별도 호출이다 — 받으면 적용됐다고 거짓말하게 된다.
        if (!laneList.includes(l))
            throw new Error(`args.${name} 의 lane "${l}" 은 이번 실행의 게이트 lane 이 아니다 (${laneList.join(', ') || '없음'})`);
        if (!LANE_OVERRIDE_VALUES[name].includes(x))
            throw new Error(`args.${name}["${l}"] = ${JSON.stringify(x)} — 허용 값: ${LANE_OVERRIDE_VALUES[name].join(', ')}`);
    }
    return { ...v };
};
const LANE_MODEL = laneOverride('laneModel');
const LANE_EFFORT = laneOverride('laneEffort');
const MEASURE_ONLY = Object.keys(LANE_MODEL).length + Object.keys(LANE_EFFORT).length > 0;
if (MEASURE_ONLY && clsLoad.sha256 !== null)
    throw new Error('args.laneModel·laneEffort 는 측정 전용이다 — 게이트 경로(classificationScript)에서는 받지 않는다');
// 측정 전용 실행의 lane 상태를 영수증에 쓸 수 없는 꼴로 바꾼다. 실제 판정은 measuredStatus 로 옮긴다.
const markMeasurementOnly = lanes => {
    if (!MEASURE_ONLY) return lanes;
    for (const v of Object.values(lanes)) { v.measuredStatus = v.status; v.status = 'MEASUREMENT_ONLY'; }
    return lanes;
};
// END lane-override

// 라운드 간 기억. 게이트는 diff 만 보므로 "이번 것이 저번과 같은 부류인가" 를 아무도 묻지
// 않았고, 같은 부류가 한 층씩 내려가며 네 번 재발했다. 직전 id 를 넘겨 재발을 세게 한다.
// `lane:id` 로 네임스페이스한다. id 만 쓰면 서로 다른 lane 의 같은 문자열이 합쳐지고,
// 남의 lane 의 id 를 물려받는 경로도 열린다.
const priorAll = (args?.priorFindings ?? []).map(f => (typeof f === 'string' ? f : f && `${f.lane ?? '?'}:${f.id}`)).filter(Boolean);
// 접두사 없는 항목은 버린다 — 모든 lane 에 뿌리면 남의 id 를 물려받는 경로가 그대로 열린다.
// 분리는 **첫** ':' 기준이다. pop() 은 id 안에 ':' 가 있으면 뒷조각만 남겨 id 를 자른다.
// CONTRACT: prior-ids-lane-scoped
const priorFor = lane => [...new Set(
    priorAll.filter(k => k.startsWith(`${lane}:`)).map(k => k.slice(k.indexOf(':') + 1)))];

// Gate·QA 두 호출부가 **같이** 쓴다. 한쪽에만 두면 그 lane 은 자기 직전 지적을 못 보고
// 같은 부류를 새 id 로 다시 내, 재발 카운트가 그만큼 빈다.
// CONTRACT: prior-block-shared-by-both-loops
function priorBlock(lane) {
    const p = priorFor(lane);
    if (p.length && rulesFor(lane))
        return `**직전 라운드에서 이 lane 이 낸 지적 id:** ${p.join(', ')}\n` +
               `id 는 \`rule@파일#심볼\` 로 계산된다. 같은 결함을 다시 보면 **같은 rule·file·symbol** 을 내라 — ` +
               `그래야 재발로 세어진다.\n`;
    return p.length
        ? `**직전 라운드에서 이 lane 이 낸 지적 id:** ${p.join(', ')}\n` +
          `이번에 찾은 것이 그중 하나와 **같은 부류**면 (같은 통제의 다른 갈래, 같은 결함의 다른 자리) ` +
          `\`findings[].id\` 를 **그 id 그대로** 내라 — 집합의 일부만 고쳐졌다는 뜻이고, ` +
          `워크플로가 그 id 로 재발을 센다. 새 부류일 때만 새 id 를 지어라.\n`
        : '';
}

// ── 스냅숏(#8 P2): lane 이 내용을 읽고 명령을 돌릴 체크아웃. 만들고 대조하고 지우는 것은
//    결정론 코드(snapshot.sh)다 — 여기서는 그 명령을 그대로 돌리게 하고 결과를 받아 대조만 한다.
//    lane 은 받은 경로만 쓴다. 체크아웃을 못 만들면 원본으로 대체하지 않는다(I4) — 그 체크아웃이
//    필요한 lane 은 돌리지 않고 결과 없음(ERROR)으로 둔다.
const SNAP = cls.snapshot ?? null;
const snaps = {};          // role → { path, tree } — 대조를 통과한 것만. lane 에게는 이것만 준다
const created = [];        // 만들어진 경로 전부 — 대조에 실패한 것도 정리 대상이다
let snapError = null;
const _sq = x => `'${String(x).replace(/'/g, `'\\''`)}'`;
const SNAP_RESULT = {
    type: 'object', required: ['outputs'],
    properties: { outputs: { type: 'array', items: { type: 'object', required: ['role', 'exitCode', 'stdout'],
        properties: { role: { type: 'string' }, exitCode: { type: 'integer' }, stdout: { type: 'string' }, stderr: { type: 'string' } } } } },
};
if (SNAP?.checkout && SNAP.tree) {
    phase('Snapshot');
    const want = [['target', SNAP.tree], ...(SNAP.baseline ? [['baseline', SNAP.baseline]] : []),
                  ...(SNAP.mutation ? [['mutation', SNAP.tree]] : [])];
    const r = await gateAgent(
        `아래 명령을 **글자 그대로** 순서대로 실행하고, 명령마다 role·종료코드·stdout·stderr 를 **고치지 말고** 돌려줘라.\n` +
            `다른 명령은 실행하지 마라. 출력을 요약하거나 해석하지 마라.\n` +
            want.map(([role, ref]) => `- role=${role}: \`bash ${_sq(SNAP.tool)} create ${_sq(repo)} ${ref}\``).join('\n'),
        { label: 'snapshot', phase: 'Snapshot', schema: SNAP_RESULT, model: 'haiku', effort: 'low' },
    ).catch(() => null);
    for (const [role, ref] of want) {
        const o = (r?.outputs ?? []).find(x => x.role === role);
        let got = null;
        try { got = o && o.exitCode === 0 ? JSON.parse(o.stdout) : null; } catch { got = null; }
        // 받은 값을 그대로 믿지 않는다 — 트리가 분류가 본 것과 같고, 경로가 snapshot.sh 가 만드는 모양이어야 한다.
        const okPath = got && typeof got.path === 'string' && /\/pf-snap\.[A-Za-z0-9]+$/.test(got.path);
        const okTree = got && (role === 'baseline' || got.tree === SNAP.tree);
        if (okPath) created.push(got.path);
        if (okPath && okTree) snaps[role] = { path: got.path, tree: got.tree };
        else {
            snapError = snapError ?? `${role} 스냅숏 실패: ${o ? (o.stderr || o.stdout || `exit ${o.exitCode}`).slice(0, 200) : '결과 없음'}`;
        }
    }
    log(snapError ? `⚠️ ${snapError} — 체크아웃이 필요한 lane 은 돌리지 않는다` : `스냅숏: ${Object.entries(snaps).map(([k, v]) => `${k}=${v.path}`).join(' · ')}`);
}
// 만든 것은 게이트가 끝나면 지운다 — 성공·실패 무관. 지우는 것도 snapshot.sh 다(이 스크립트가 만든 경로만 지운다).
async function cleanupSnapshots() {
    const paths = [...new Set(created)];
    if (!paths.length) return;
    await gateAgent(
        `아래 명령을 **글자 그대로** 실행하고 끝내라. 다른 명령은 실행하지 마라.\n` +
            paths.map(p => `- \`bash ${_sq(SNAP.tool)} remove ${_sq(repo)} ${_sq(p)}\``).join('\n'),
        { label: 'snapshot-cleanup', phase: 'Snapshot', model: 'haiku', effort: 'low' },
    ).catch(() => null);
}

// BEGIN snapshot-block — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// CONTRACT: lanes-read-the-snapshot
// lane 에게 **내용을 어디서 읽고 명령을 어디서 돌리는지** 알려 준다. 체크아웃이 있으면 그 경로,
// 없으면 트리 참조다. 어느 쪽이든 원본 워킹트리는 출처가 아니다 — 커밋되지 않을 변경이 섞여 있다.
// 검사 범위는 두 분기 모두 명시한다 — 스냅숏 커밋의 부모가 HEAD 라 체크아웃 안에서는 `--cached`·`diff HEAD`
// 가 둘 다 비어, 범위를 안 주면 diff 를 보는 lane 이 빈 diff 로 통과한다.
function snapshotBlock(s) {
    if (!s || !s.tree) return '';
    const range = `**검사 범위는 \`git -C ${s.repo} diff ${s.from} ${s.tree}\` 다** — 이 범위가 이번 변경의 전부다. ` +
        `\`--cached\`·\`diff HEAD\` 로 다시 구하지 마라(스냅숏 안에서는 비어 있다).\n`;
    if (s.path)
        return `**검사 대상 내용은 스냅숏 \`${s.path}\` 다** (트리 ${s.tree.slice(0, 12)} — 커밋될 내용 그대로).\n` +
            `파일 내용은 이 경로에서 읽고, 명령은 \`cd ${s.path}\` 한 뒤 여기서 돌려라. ` +
            `원본 레포 \`${s.repo}\` 의 파일은 읽지 마라 — 커밋되지 않을 변경이 섞여 있다. ` +
            `이 스냅숏은 게이트가 만들고 지운다 — 만들거나 지우거나 다른 체크아웃을 꾸리지 마라. ` +
            `체크아웃의 HEAD 는 스냅숏 커밋이라 원본 레포의 커밋 해시와 다르다 — 정상이다(내용은 위 트리다).\n` + range;
    return `**검사 대상 내용은 트리 \`${s.tree}\` 다** (커밋될 내용 그대로). ` +
        `파일 내용은 \`git -C ${s.repo} show ${s.tree}:<경로>\` 로 읽어라 — 원본 워킹트리의 파일을 읽지 마라(커밋되지 않을 변경이 섞여 있다).\n` + range;
}
// END snapshot-block
// 스냅숏을 읽지 않는 lane — 브랜치·커밋 메타(pr-quality), vault 원격 기준선(vault-sync), 배포된 API(qa-runner).
const NO_SNAPSHOT = new Set(['pr-quality', 'vault-sync', 'qa-runner']);
const snapFor = lane => NO_SNAPSHOT.has(lane) ? '' : snapshotBlock(SNAP?.tree ? {
    repo, tree: SNAP.tree, path: SNAP.checkout ? snaps.target?.path : null,
    // 커밋 모드는 HEAD, PR 모드는 merge-base. 커밋이 없는 레포는 빈 트리부터다.
    from: (mode === 'pr' ? cls.base?.diffFrom : cls.head) || '4b825dc642cb6eb9a060e54bf8d69288fbee4904',
} : null);
const withSnap = cmd => (snaps.target && SNAP?.token ? String(cmd).split(SNAP.token).join(snaps.target.path) : cmd);

// ── 사실 주장 재측정 (claim-check ③). 규칙 줄을 지우거나 바꾸면서 비율·백분율·부재를 주장한 변경만 대상이다 —
//    고르는 것은 분류기(claim-remeasure.sh select)이고, 여기서는 상한을 걸고 한 번 부르고 결정론으로 대조한다.
//    lane 이 아니다: selected·lanes·receiptLanes 밖이고, 결과는 전부 참고(notes)다. 근거는 DECISIONS.md 2026-11-12.
// CONTRACT: claim-remeasure-is-advisory
// 재측정 상한 K — 게이트 한 번에 ③ 호출 1회, 주장 K건. vault 80커밋 표본에서 커밋당 대상 최댓값이 3이고
// 2026-09-09 사건 커밋은 2건이라, 둘 다 자르지 않는 값이다. 넘는 대상은 개수를 보고서에 남긴다.
const REMEASURE_MAX_CLAIMS = 5;
const RMC = cls.claimCheck?.remeasure ?? null;
const rmAll = Array.isArray(RMC?.targets) ? RMC.targets : [];
const rmPicked = rmAll.slice(0, REMEASURE_MAX_CLAIMS);
const rmOverCap = rmAll.length - rmPicked.length;
// 이 실행의 등록 레포 스냅숏을 담는 상위 폴더 이름(TMPDIR 아래). 스냅숏을 만든 에이전트의 출력을 못 받아도
// 이 이름으로 지운다 — 경로를 그 출력에서만 얻으면 중계가 실패할 때 git archive 트리가 남는다.
// 같은 분류·라운드로 여러 실행이 겹치면(eval/flip.sh 의 반복 실행) 이름이 같아져, 먼저 끝난 실행의
// 정리가 아직 읽고 있는 다른 실행의 스냅숏을 지운다. 그것을 가르는 꼬리는 **args 에서만 온다.**
// 스크립트가 지어낼 수는 없다 — 워크플로 런타임은 `Math.random()`·`Date.now()` 를 금지한다
// (resume 이 같은 스크립트·같은 args 로 같은 결과를 내야 한다). 부르면 워크플로가 즉시 죽는다.
// 입력은 `args.runId`(호출자가 주는 값 — 같은 args.json 을 겹쳐 돌리는 eval/flip.sh), 없으면
// `classification.runNonce`(classify.sh 가 호출마다 새로 뽑는다 — 게이트는 매 실행 분류부터 하므로
// runId 없는 평범한 게이트도 실행마다 갈린다). 빈 값은 없는 것으로 본다. 둘 다 없는 낡은 분류면 `shared` 로 고정이고 겹친 실행이
// 폴더를 공유한다. 둘 다 args 안의 값이라 resume 은 같은 이름을 재현한다.
// 꼬리는 그 값 **전체**의 결정론적 체크섬이다. 앞 n 자만 쓰면 접두가 같은 값들(ISO 타임스탬프 등)이
// 조용히 한 폴더로 접혀, 구분했다고 믿는 실행끼리 서로의 스냅숏을 지운다. 체크섬은 입력만 보므로
// 런타임이 금지하는 비결정 함수와 무관하다.
const _rmNonce = (() => {
    // `||` 다 — 빈 runId('')도 다음 후보로 넘긴다. `??` 면 빈 값이 runNonce 를 가려 shared 로 떨어진다.
    const v = String(args?.runId || cls.runNonce || '');
    if (!v) return 'shared';
    let h = 0;
    for (let i = 0; i < v.length; i++) h = (h * 31 + v.charCodeAt(i)) % 2147483647;
    return 'r' + h.toString(36);
})();
const RM_INTO = `pf-snap.rm_${String(cls.contentDigest ?? cls.classificationId ?? 'x').replace(/[^A-Za-z0-9]/g, '').slice(0, 16)}_${round}_${_rmNonce}`;
let rmSnapTried = false;
let rmRepos = [];          // snapshot 결과 — 대조를 통과한 경로만 snapshot 을 갖는다
let rmRepoError = null;
let rmOut = null;          // ③ 의 구조화 출력. null 이면 실패다
let rmCalls = 0;

// BEGIN remeasure-judge — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// CONTRACT: remeasure-judged-by-code
// lane 은 측정과 자리 해석만 한다. 일치·불일치는 여기서 숫자로 정한다 — 같은 측정값이면 같은 결과다.
// 독립성: lane 이 보고한 명령이 원래 출처 명령과 **같은 패턴**이면 독립 재측정이 아니다. '같은 패턴' 은
// claim-verify.sh 의 tokenize()·patterns() 를 바탕으로 한 추출 규칙(grep 계열 단계의 -e/--regexp 값과 첫 위치 인자,
// 따옴표를 푼 문자열)으로 뽑은 문자열이 앞뒤 공백을 걷고 하나라도 같은 것이다. 어느 쪽이든 -i 면 대소문자를 접는다.
// patterns() 와 같지는 않고 그 상위집합이다: patterns() 는 첫 위치 인자에서 멈추지만 여기서는 그 뒤의 -e 값도 모으고,
// -i 를 추적한다. 더 많이 모을수록 '독립성 미확보' 쪽으로 기울 뿐 독립 측정을 일치로 세지는 않는다.
function _rmTokenize(cmd) {
    const w = String(cmd).replace(/(?<!\S)2>\s*\/dev\/null(?!\S)/g, ' ').replace(/(?<!\S)2>&1(?!\S)/g, ' ');
    const stages = []; let cur = [], tok = null, i = 0;
    const n = w.length;
    const push = () => { if (tok !== null) cur.push(tok.join('')); tok = null; };
    while (i < n) {
        const c = w[i];
        if (c === ' ' || c === '\t') { push(); i++; continue; }
        if (c === "'") {
            const j = w.indexOf("'", i + 1);
            if (j < 0) return null;
            tok = (tok ?? []).concat([...w.slice(i + 1, j)]); i = j + 1; continue;
        }
        if (c === '"') {
            tok = tok ?? []; i++;
            while (i < n && w[i] !== '"') {
                if (w[i] === '\\' && i + 1 < n && '"\\$`\n'.includes(w[i + 1])) { tok.push(w[i + 1]); i += 2; continue; }
                if (w[i] === '$' || w[i] === '`') return null;
                tok.push(w[i]); i++;
            }
            if (i >= n) return null;
            i++; continue;
        }
        if (c === '\\') {
            if (i + 1 >= n || w[i + 1] === '\n') return null;
            tok = (tok ?? []).concat([w[i + 1]]); i += 2; continue;
        }
        if (c === '|') {
            if (w[i + 1] === '|') return null;
            push();
            if (!cur.length) return null;
            stages.push(cur); cur = []; i++; continue;
        }
        if (';&<>()$`\n{}'.includes(c)) return null;
        if (c === '~' && tok === null) return null;
        tok = (tok ?? []).concat([c]); i++;
    }
    push();
    if (!cur.length) return null;
    stages.push(cur);
    return stages;
}
function remeasurePatterns(cmd) {
    const pats = new Set(); let icase = false;
    for (const st of _rmTokenize(cmd) ?? []) {
        let a = st;
        if (a.length && a[0] === 'git' && a.includes('grep')) a = a.slice(a.indexOf('grep'));
        if (!a.length || !['grep', 'egrep', 'fgrep'].includes(a[0])) continue;
        const rest = a.slice(1);
        let found = false;
        for (let i = 0; i < rest.length; i++) {
            const x = rest[i];
            if (x === '--') continue;
            if (x === '-e' || x === '--regexp') { if (i + 1 < rest.length) pats.add(rest[i + 1]); i++; continue; }
            if (x.startsWith('--regexp=')) { pats.add(x.split('=').slice(1).join('=')); continue; }
            if (x === '--ignore-case') { icase = true; continue; }
            if (x.startsWith('-') && !x.startsWith('--') && x.length > 1) { if (x.slice(1).includes('i')) icase = true; continue; }
            if (x.startsWith('-')) continue;
            if (!found) { pats.add(x); found = true; }   // 첫 위치 인자만 패턴이다 — 뒤는 경로다
        }
    }
    return { pats: [...pats], icase };
}
function samePattern(origCmds, laneCmds) {
    for (const o of origCmds) {
        const po = remeasurePatterns(o);
        for (const l of laneCmds) {
            const pl = remeasurePatterns(l);
            const fold = po.icase || pl.icase;
            const norm = s => (fold ? s.trim().toLowerCase() : s.trim());
            const set = new Set(po.pats.map(norm));
            const hit = pl.pats.map(norm).find(p => set.has(p));
            if (hit !== undefined) return hit;
        }
    }
    return null;
}
// targets: 분류기의 대상(K 로 자른 것), out: ③ 출력 또는 null, offered: Map(스냅숏 id → {name, snapshotMayDiffer?}),
// registry: 이번 실행의 등록 레포 {unusable: [사용 불가 이름]} — 판정 구간 밖 이름을 읽지 않으려고 인자로 받는다.
// 반환: 대상마다 {target, file, line, source, text, state, reason?, slots?, measured?, scopeUnverified?} — state 는
//   mismatch · population-differs · match · unmeasurable · not-independent 중 하나.
// 검사 순서: 형식(snapshots) → 측정값 → 코퍼스 범위(excluded·모집단) → 같은 패턴 → 자리 대조.
// 코퍼스 범위가 먼저다 — 잘못된 코퍼스를 잰 측정은 독립성을 따질 대상이 아니다.
function remeasureJudge(targets, out, offered, registry = { unusable: [] }) {
    const ms = Array.isArray(out?.measurements) ? out.measurements : [];
    const isInt = v => Number.isInteger(v) && v >= 0;
    const unusable = (Array.isArray(registry?.unusable) ? registry.unusable : []).filter(n => typeof n === 'string');
    // 측정이 센 스냅숏 목록의 형식 확인. 문제가 있으면 '형식 거부:' 로 시작하는 사유를, 없으면 null 을 낸다.
    const formatReject = c => {
        const sn = c?.snapshots;
        if (sn === undefined && c?.snapshot !== undefined)
            return '형식 거부: 옛 단일 필드(corpus.snapshot)로 적었다 — 센 스냅숏은 corpus.snapshots 배열로 받는다';
        if (!Array.isArray(sn)) return '형식 거부: corpus.snapshots 가 배열이 아니다';
        if (!sn.length) return '형식 거부: corpus.snapshots 가 비었다';
        if (sn.some(x => typeof x !== 'string')) return '형식 거부: corpus.snapshots 원소가 문자열이 아니다';
        const dup = sn.filter((x, i) => sn.indexOf(x) !== i);
        if (dup.length) return `형식 거부: corpus.snapshots 에 같은 스냅숏이 두 번 있다 (${[...new Set(dup)].join(', ')})`;
        const bad = sn.filter(x => !offered.has(x));
        if (bad.length)
            return `형식 거부: 넘기지 않은 스냅숏 ${bad.join(', ')} — 이번 실행에서 넘긴 사용 가능한 스냅숏만 센다`;
        return null;
    };
    return targets.map(t => {
        const base = { target: t.id, file: t.file, line: t.line, source: t.source, text: t.text };
        const m = ms.find(x => x && x.target === t.id);
        if (!m) return { ...base, state: 'unmeasurable', reason: '측정 결과에 이 대상이 없다' };
        if (m.status !== 'measured') return { ...base, state: 'unmeasurable', reason: String(m.reason || '사유 없음') };
        const fr = formatReject(m.corpus);
        if (fr) return { ...base, state: 'unmeasurable', reason: fr };
        const N = m.population, W = m.with, WO = m.without;
        if (!isInt(N) || !isInt(W) || !isInt(WO))
            return { ...base, state: 'unmeasurable', reason: '측정값(population·with·without)이 정수가 아니다' };
        // 서로 어긋난 세 값으로 대조하면 그럴듯한 쪽 자리만 '일치' 로 나오고 측정 오류가 보고에서 사라진다
        if (W + WO !== N)
            return { ...base, state: 'unmeasurable', reason: `측정값이 서로 맞지 않는다 (with ${W} + without ${WO} ≠ population ${N})` };
        // 순서가 달라도 같은 결과가 나오게 정렬한다
        const snapIds = [...m.corpus.snapshots].sort();
        const names = [...new Set(snapIds.map(id => offered.get(id).name))].sort();
        const differ = [...new Set(snapIds.map(id => offered.get(id).snapshotMayDiffer).filter(Boolean))];
        const excluded = (Array.isArray(m.corpus.excluded) ? m.corpus.excluded : [])
            .filter(e => e && typeof e === 'object' && typeof e.repo === 'string')
            .map(e => ({ repo: e.repo, reason: typeof e.reason === 'string' ? e.reason : '' }));
        const measured = { corpus: names.join(', '), corpora: names, snapshots: snapIds, population: N, with: W, without: WO,
                           commands: m.commands ?? [], property: m.property ?? '',
                           ...(excluded.length ? { excluded } : {}),
                           ...(differ.length ? { snapshotMayDiffer: differ.join(' · ') } : {}) };
        // 등록 레포 측정 — 대상 레포가 아닌 등록 레포 스냅숏을 하나라도 셌다. 등록 목록이 주장이 세는 레포 전부라는
        // 보장이 없으므로, 코퍼스 일부가 빠졌는지를 코드가 볼 수 있는 신호(사용 불가 레포 선언·비율 전체 자리)로 확인한다.
        const registered = names.some(n => n !== 'target');
        if (registered) {
            const empty = excluded.filter(e => !e.reason.trim()).map(e => e.repo);
            if (empty.length)
                return { ...base, state: 'unmeasurable', reason: `excluded 사유가 비었다 (${empty.join(', ')})`, measured };
            const both = excluded.map(e => e.repo).filter(n => names.includes(n));
            if (both.length)
                return { ...base, state: 'unmeasurable', reason: `센 레포를 excluded 에도 적었다 (${[...new Set(both)].join(', ')})`, measured };
            const exNames = new Set(excluded.map(e => e.repo));
            const miss = unusable.filter(n => !exNames.has(n));
            if (miss.length)
                return { ...base, state: 'unmeasurable',
                         reason: `사용 불가 등록 레포를 excluded 에 적지 않았다 (${miss.join(', ')}) — 그 레포가 주장의 코퍼스 밖인지 확인되지 않았다`, measured };
        }
        // 사용 불가가 아닌 이름(등록 목록에 없는 이름 포함)의 excluded 항목은 상태를 바꾸지 않는다 — measured 에 남아 보고에 실린다
        const meaning = {};
        for (const s of Array.isArray(m.slots) ? m.slots : []) if (s && s.slot) meaning[s.slot] = s.refersTo;
        const side = sid => (meaning[sid] === 'with' ? W : meaning[sid] === 'without' ? WO : null);
        const slotOf = Object.fromEntries((t.slots ?? []).map(s => [s.id, s]));
        const st = [];
        for (const r of t.ratios ?? []) {
            const part = slotOf[r.part], total = slotOf[r.total];
            if (!part || !total) continue;
            if (meaning[r.total] !== 'population' || side(r.part) === null) {
                st.push({ slot: `${r.part}/${r.total}`, kind: 'ratio', state: 'uninterpreted' }); continue;
            }
            const s = total.value !== N ? 'population-differs' : part.value === side(r.part) ? 'match' : 'mismatch';
            st.push({ slot: `${r.part}/${r.total}`, kind: 'ratio', claimed: `${part.value}/${total.value}`,
                      measured: `${side(r.part)}/${N} (${meaning[r.part]})`, state: s });
        }
        for (const s of (t.slots ?? []).filter(x => x.kind === 'percent')) {
            if (side(s.id) === null || N === 0) { st.push({ slot: s.id, kind: 'percent', state: 'uninterpreted' }); continue; }
            const pct = (100 * side(s.id)) / N;
            // 반올림 허용: 0.5%p 이내이거나, 정수 백분율이 측정 비율을 버림한 값이면 일치다(342/404=84.65% → "84%").
            // 0%·100% 는 "하나도 없다"·"전부" 라는 주장이라 근사로 맞추지 않는다 — 측정 수가 정확히 0 또는 N 이어야 한다.
            const ok = s.value === 0 ? side(s.id) === 0
                : s.value === 100 ? side(s.id) === N
                : Math.abs(pct - s.value) <= 0.5 || (Number.isInteger(s.value) && s.value === Math.floor(pct + 1e-9));
            st.push({ slot: s.id, kind: 'percent', claimed: `${s.value}%`, measured: `${pct.toFixed(1)}% (${meaning[s.id]})`,
                      state: ok ? 'match' : 'mismatch' });
        }
        for (const s of (t.slots ?? []).filter(x => x.kind === 'absence')) {
            if (side(s.id) === null) { st.push({ slot: s.id, kind: 'absence', state: 'uninterpreted' }); continue; }
            st.push({ slot: s.id, kind: 'absence', claimed: '0', measured: `${side(s.id)} (${meaning[s.id]})`,
                      state: side(s.id) === 0 ? 'match' : 'mismatch' });
        }
        // 등록 레포 측정의 모집단 — 주장의 비율 전체 자리가 N 과 다르면, 등록되지 않았거나 사용 불가인 레포가 빠진 것과
        // 주장 모집단이 틀린 것을 코드가 가를 수 없다. 백분율 불일치가 함께 있어도 측정 불가다(대가: 그 불일치를 놓친다).
        const totals = (t.ratios ?? []).filter(r => slotOf[r.part] && slotOf[r.total]).map(r => slotOf[r.total]);
        if (registered) {
            const off = totals.filter(x => x.value !== N);
            if (off.length)
                return { ...base, state: 'unmeasurable',
                         reason: `등록 레포에 걸친 측정의 모집단이 주장과 다르다 (주장 ${off.map(x => x.value).join('·')} · 측정 ${N}) — 코퍼스 일부가 빠진 것과 구별되지 않는다`,
                         slots: st, measured };
        }
        // 비율 전체 자리가 없으면 코드가 코퍼스 범위를 확인할 신호가 없다 — 상태는 그대로 두고 표시만 붙인다
        const scope = registered && !totals.length
            ? { scopeUnverified: '코퍼스 범위를 코드가 확인하지 못했다 (비율 전체 자리가 없다)' } : {};
        const laneCmds = (Array.isArray(m.commands) ? m.commands : []).flatMap(c => String(c).split('\n')).filter(s => s.trim());
        const same = (t.commands ?? []).length ? samePattern(t.commands, laneCmds) : null;
        if (same !== null)
            return { ...base, state: 'not-independent', reason: `원래 출처 명령과 같은 패턴 \`${same}\` 을 썼다 — 같은 오류를 반복할 수 있다`, measured, ...scope };
        if (!st.length || st.some(x => x.state === 'uninterpreted'))
            return { ...base, state: 'unmeasurable', reason: '수치 자리가 무엇을 가리키는지 해석이 없거나 맞지 않는다', slots: st, measured, ...scope };
        // 우선순위: 불일치 > 모집단 다름 > 일치. 백분율은 모집단 크기와 무관하게 비교되므로 N 이 달라도 그 불일치는 신호다.
        const state = st.some(x => x.state === 'mismatch') ? 'mismatch'
            : st.some(x => x.state === 'population-differs') ? 'population-differs' : 'match';
        return { ...base, state, slots: st, measured, ...scope };
    });
}
// END remeasure-judge

// ③ 의 출력 스키마. 측정과 해석만 받는다 — 일치·불일치를 lane 이 적는 필드는 없다.
const REMEASURE_SCHEMA = {
    type: 'object', required: ['measurements'],
    properties: { measurements: { type: 'array', items: {
        type: 'object', required: ['target', 'status'],
        properties: {
            target: { type: 'string', enum: rmPicked.map(t => t.id) },
            status: { type: 'string', enum: ['measured', 'unmeasurable'] },
            reason: { type: 'string', description: 'unmeasurable 이면 왜 못 쟀는가' },
            corpus: { type: 'object', required: ['snapshots'], properties: {
                snapshots: { type: 'array', minItems: 1, items: { type: 'string' },
                             description: '센 스냅숏 id 를 전부, 하나씩 — 프롬프트가 준 값 그대로. 여러 레포를 합산했으면 그 레포들의 스냅숏을 모두 적는다' },
                excluded: { type: 'array', description: '등록 레포를 센 측정에서, 사용 불가 등록 레포마다 그 레포가 주장의 코퍼스 밖인 이유',
                            items: { type: 'object', required: ['repo', 'reason'], properties: {
                                repo: { type: 'string', description: '사용 불가 등록 레포 이름' },
                                reason: { type: 'string', description: '그 레포가 주장의 코퍼스 밖인 이유' } } } },
                tree: { type: 'string', description: '센 트리의 sha (알면)' } } },
            population: { type: 'integer', description: '모집단 크기 N' },
            with: { type: 'integer', description: '성질을 가진 수' },
            without: { type: 'integer', description: '성질을 갖지 않은 수' },
            slots: { type: 'array', items: { type: 'object', required: ['slot', 'refersTo'], properties: {
                slot: { type: 'string', description: '가린 주장의 자리표 (S1, A1 …)' },
                refersTo: { type: 'string', enum: ['population', 'with', 'without'] } } } },
            commands: { type: 'array', items: { type: 'string' }, description: '실제로 돌린 측정 명령, 하나씩' },
            property: { type: 'string', description: '센 성질의 정의 (무엇을 "가졌다" 로 셌는가)' },
        } } } },
};
const RM_SNAP_RESULT = {
    type: 'object', required: ['exitCode', 'stdout'],
    properties: { exitCode: { type: 'integer' }, stdout: { type: 'string' }, stderr: { type: 'string' } },
};
// 등록 레포 스냅숏 — 만드는 것은 claim-remeasure.sh 다(git archive 를 임시 폴더에 푼다, 등록 레포 .git 무변경).
// 받은 값을 그대로 믿지 않는다: 등록 목록에 있는 이름이고 경로가 그 스크립트가 만드는 모양일 때만 쓴다.
async function remeasureSnapshots() {
    const reg = Array.isArray(RMC?.registry) ? RMC.registry : [];
    if (!reg.length || !RMC?.tool) return;
    rmSnapTried = true;
    const r = await gateAgent(
        `아래 명령을 **글자 그대로** 실행하고 종료코드·stdout·stderr 를 **고치지 말고** 돌려줘라.\n` +
            `다른 명령은 실행하지 마라. 출력을 요약하거나 해석하지 마라.\n` +
            `- \`bash ${_sq(RMC.tool)} snapshot --registry ${_sq(JSON.stringify(reg))} --into ${_sq(RM_INTO)}\``,
        { label: 'remeasure-snapshot', phase: 'Gate', schema: RM_SNAP_RESULT, model: 'haiku', effort: 'low' },
    ).catch(() => null);
    let got = null;
    try { got = r && r.exitCode === 0 ? JSON.parse(r.stdout) : null; } catch { got = null; }
    // 이 실행의 상위 폴더 아래 경로만 받는다 — 같은 모양의 대상 레포 스냅숏이 섞여 들어와도 코퍼스로 넘기지 않는다
    const okPath = p => typeof p === 'string' && new RegExp(`/${RM_INTO.replace('.', '\\.')}/pf-snap\\.[A-Za-z0-9_]+$`).test(p);
    if (!got || !Array.isArray(got.repos)) {
        rmRepoError = `등록 레포 스냅숏을 만들지 못했다: ${r ? (r.stderr || r.stdout || `exit ${r.exitCode}`).slice(0, 200) : '결과 없음'}`;
        rmRepos = reg.map(x => ({ name: x.name, status: 'unusable', reason: rmRepoError }));
        return;
    }
    const names = new Set(reg.map(x => x.name));
    rmRepos = got.repos.filter(x => x && names.has(x.name)).map(x => {
        return x.status === 'usable' && okPath(x.snapshot)
            ? { name: x.name, status: 'usable', snapshot: x.snapshot, ref: x.ref, sha: x.sha, fetchedAt: x.fetchedAt,
                ...(x.snapshotMayDiffer ? { snapshotMayDiffer: x.snapshotMayDiffer } : {}) }
            : { name: x.name, status: 'unusable', reason: x.reason || '스냅숏 경로가 없다' };
    });
}
// 대상 레포의 스냅숏 id — 체크아웃이 있으면 그 경로, 없으면 트리 sha. 다른 lane 과 같은 블록으로 읽는 법을 준다.
const rmTargetId = () => snaps.target?.path ?? (SNAP?.tree || null);
function remeasureOffered() {
    const m = new Map();
    if (rmTargetId()) m.set(rmTargetId(), { name: 'target' });
    for (const x of rmRepos) if (x.status === 'usable') m.set(x.snapshot, { name: x.name, ...(x.snapshotMayDiffer ? { snapshotMayDiffer: x.snapshotMayDiffer } : {}) });
    return m;
}
const _rmSlotDesc = { 'ratio-part': '비율의 부분', 'ratio-total': '비율의 전체', percent: '백분율', absence: '부재 표현' };
function remeasurePrompt() {
    const tb = SNAP?.tree ? snapshotBlock({
        repo, tree: SNAP.tree, path: SNAP.checkout ? snaps.target?.path : null,
        from: (mode === 'pr' ? cls.base?.diffFrom : cls.head) || '4b825dc642cb6eb9a060e54bf8d69288fbee4904',
    }) : '';
    return `대상 레포: ${repo}\n게이트 모드: ${mode}\n\n` +
        `**재측정할 주장 (${rmPicked.length}건 — 이 목록 밖은 재지 마라).** 수치 자리는 자리표로 가렸다. ` +
        `원래 숫자·원래 측정 명령을 찾아 맞추지 마라 — 주장이 적힌 문서 줄·커밋 메시지·PR 본문을 열지 마라.\n` +
        rmPicked.map(t => `- ${t.id} · 출처 ${t.file}${t.line ? `:${t.line}` : ''} (${t.source})\n` +
            `  주장: ${t.masked}\n` +
            `  자리: ${(t.slots ?? []).map(s => `${s.id}=${_rmSlotDesc[s.kind] ?? s.kind}${s.phrase ? ` "${s.phrase}"` : ''}`).join(', ') || '(없음)'}`).join('\n') +
        `\n\n**읽을 수 있는 코퍼스 — 스냅숏 id 와 함께. 이 목록 밖은 읽지 마라.**\n` +
        (rmTargetId()
            ? `- 게이트 대상 레포 — 스냅숏 id \`${rmTargetId()}\`\n${tb}`
            : `- 게이트 대상 레포 — 분류가 본 트리가 없다. 이 레포를 세는 주장은 unmeasurable 로 내라.\n`) +
        (rmRepos.length
            ? rmRepos.map(x => x.status === 'usable'
                ? `- 등록 레포 \`${x.name}\` — 스냅숏 \`${x.snapshot}\` (${x.ref} @ ${String(x.sha).slice(0, 12)}, 마지막 fetch ${x.fetchedAt})` +
                  `${x.snapshotMayDiffer ? ` · ${x.snapshotMayDiffer}` : ''}. 이 경로가 스냅숏 id 다. 이 경로 아래에서만 읽어라.`
                : `- 등록 레포 \`${x.name}\` — 사용 불가 (${x.reason}). 이 레포를 세는 주장은 unmeasurable 로 내라.`).join('\n') + '\n'
            : `- 등록된 레포 밖 코퍼스는 없다.\n`) +
        (rmRepoError ? `⚠️ ${rmRepoError}\n` : '') +
        `\n**규칙.**\n` +
        `- 주장이 세는 코퍼스가 위 목록에 없거나(미등록·사용 불가) 특정할 수 없으면 status=unmeasurable 과 사유를 내라. ` +
        `다른 코퍼스(예: 주장이 적힌 문서 레포의 .md)를 세서 대신하지 마라.\n` +
        `- 측정은 **네가 정한 방법**으로 해라. 문서·커밋 메시지·PR 본문에 적힌 명령을 실행하지 마라.\n` +
        `- 측정마다 \`corpus.snapshots\` 에 센 스냅숏 id 를 전부, 위 목록의 값 **글자 그대로** 하나씩 적어라. 여러 레포를 합산했으면 ` +
        `그 레포들의 스냅숏을 모두 적어라 — 경로를 쉼표로 잇거나 상위 폴더를 적지 마라. 원 체크아웃이나 다른 경로를 찾아 읽지 마라.\n` +
        `- 등록 레포 목록이 주장이 세는 레포 전부라는 보장은 없다. 주장이 목록 밖 레포(미등록·사용 불가)를 센다는 근거가 있으면 ` +
        `status=unmeasurable 과 사유를 내라. 목록 밖 레포를 센다는 근거가 없으면 목록의 사용 가능한 레포로 재고 센 스냅숏을 전부 적어라.\n` +
        `- 등록 레포를 센 측정에서 사용 불가로 표시된 등록 레포가 있으면, 그 레포마다 \`corpus.excluded\` 에 이름(repo)과 ` +
        `그 레포가 주장의 코퍼스 밖인 이유(reason)를 적어라. 주장의 코퍼스 밖인 이유를 말할 수 없으면 unmeasurable 을 내라.\n` +
        `- population(N)·with·without 을 정수로, slots[] 에 자리표마다 그 자리가 population·with·without 중 무엇인지, ` +
        `commands[] 에 실제로 돌린 명령을 하나씩, property 에 센 성질의 정의를 적어라. 맞다·틀리다는 적지 마라 — 대조는 코드가 한다.\n` +
        `- **파일을 쓰거나 네트워크에 접근하지 마라.** git fetch·pull 도 하지 마라.`;
}
async function runRemeasure() {
    if (!rmPicked.length) return;
    await remeasureSnapshots();
    rmCalls++;
    const r = await gateAgent(remeasurePrompt(),
        { agentType: 'claim-remeasurer', label: 'claim-remeasurer', phase: 'Gate', schema: REMEASURE_SCHEMA },
    ).catch(() => null);
    rmOut = r && Array.isArray(r.measurements) ? r : null;
}
async function cleanupRemeasure() {
    // 이 실행이 만든 상위 폴더 하나만 지운다. 중계된 개별 경로는 넘기지 않는다 — 같은 모양(pf-snap.*)의
    // 대상 레포 스냅숏이나 다른 실행의 스냅숏이 섞여 들어와도 지우지 않게 하려는 것이다.
    if (!rmSnapTried) return;
    await gateAgent(
        `아래 명령을 **글자 그대로** 실행하고 끝내라. 다른 명령은 실행하지 마라.\n` +
            `- \`bash ${_sq(RMC.tool)} remove --into ${_sq(RM_INTO)}\``,
        { label: 'remeasure-cleanup', phase: 'Gate', model: 'haiku', effort: 'low' },
    ).catch(() => null);
}

// ── 기준선: 테스트 lane 이 있으면 먼저 고정한다. 없으면 "원래 깨져 있던 것"이 회귀로 오판된다.
let baseline = args?.baseline
    ? (typeof args.baseline === 'string' ? { metrics: args.baseline } : args.baseline)
    : null;   // 문자열(이전 라운드의 요약)로 받아도 동작한다
// 기준선은 **test-runner 만** 쓴다. 여기서 await 하면 Gate 전체가 1분 24초 막히고
// 그동안 secret-scanner(21초)가 대기한다. 띄워만 두고 test-runner lane 안에서 기다린다.
let baselinePromise = null;
// 스냅숏 체크아웃의 HEAD 는 snapshot.sh 가 commit-tree 로 만든 커밋이라 기준 커밋 해시와 늘 다르다. 내용(트리)은 기준 커밋의 것이고
// snapshot.sh 가 체크아웃 트리와 대조한다. 이 사실을 모르면 lane 이 HEAD 를 비교해 기준선을 버리고 기존 실패를 새로 깨진 것으로 올린다
// (docs/backlog.md 「기준선 체크아웃의 HEAD 가 …」 — 실제 게이트에서도 기준선 미실행·"확인 필요" 로 나왔다).
const BASE_HEAD_NOTE = `기준선 체크아웃의 HEAD 해시는 기준 커밋과 **다른 것이 정상이다** — snapshot.sh 가 만든 스냅숏 커밋이고, 내용은 기준 커밋의 트리` +
    (snaps.baseline?.tree ? ` ${String(snaps.baseline.tree).slice(0, 12)}` : '') +
    ` 이며 snapshot.sh 가 체크아웃 트리와 대조했다. HEAD 해시가 다르다는 이유로 기준선을 버리거나 의심하지 마라.\n`;
if (!baseline && selected['test-runner'] && !snaps.baseline) {
    // 기준선을 잴 체크아웃이 없다 — package.json 이 없는 레포(tsc/jest 대상 아님)이거나 만들지 못했다.
    baseline = { metrics: SNAP?.baseline ? `기준선 체크아웃을 만들지 못했다 (${snapError ?? '사유 미상'})`
        : 'tsc/jest 기준선 없음 — 분류기가 기준 커밋을 정하지 않았다(스냅숏에 package.json 이 없거나 PR base 를 해석하지 못했다)' };
}
if (!baseline && selected['test-runner']) {
    phase('Baseline');
    baselinePromise = gateAgent(
        `기준선 체크아웃 \`${snaps.baseline?.path}\` (레포 ${repo} 의 기준 커밋 ${SNAP?.baseline}) 에서 tsc/jest 를 실행해 기준선 수치만 기록해라.\n` +
            BASE_HEAD_NOTE +
            `그 체크아웃은 게이트가 만들고 지운다 — 만들거나 지우거나 다른 체크아웃을 꾸리지 마라. 원본 레포의 워킹트리는 건드리지 마라.\n` +
            `판정이 아니라 숫자 기록이 목적이다. verdict 는 항상 PASS, findings 는 빈 배열로 두고 metrics 에만 수치를 넣어라.\n` +
            `**lane 에는 정확히 "baseline" 을 넣어라.** 다른 값은 스키마가 거절한다.`,
        // 판정이 아니라 숫자 수집이다 — 같은 agentType 이지만 이 호출만 낮춘다.
        { agentType: 'test-runner', label: 'baseline', phase: 'Baseline', schema: BASELINE_VERDICT, model: 'haiku' },
    // 아무도 아직 await 하지 않으므로, 거부가 처리되지 않은 채 남지 않게 여기서 흡수한다
    ).catch(() => null);
}

// 분류기가 계산한 대상·메타를 프롬프트로 옮긴다. **Gate 루프와 QA 루프가 공유한다** —
// 한쪽에만 두면 그 lane 에는 classify 가 계산한 값(modules·apiFiles·devBaseUrl·repoNote·
// placement)이 도달하지 않는다.
function laneScope(lane) {
    const files = selected[lane] ?? [];
    return files.length
        ? `네 lane 에 해당하는 파일만 봐라 — **이미 확정된 목록이다**:\n${files.map(f => `  - ${f}`).join('\n')}\n` +
          `이 목록을 다시 찾지 마라. \`git status\`/\`git diff --stat\` 으로 변경 파일을 재발견하는 데 시간을 쓰지 마라.\n` +
          `내용이 필요하면 **한 번의 명령으로 묶어** 읽어라 — 파일당 한 번씩 Read 하면 그만큼 게이트가 느려진다.`
        : `대상 파일 목록은 비어 있다 — 이 lane 은 파일이 아니라 브랜치·커밋·PR 메타를 본다.`;
}

// PR 본문 초안. 없을 때의 결과는 검사기가 고정 warn 하나로 낸다 — 에이전트가 정하지 않는다
// (근거는 pr-format-check.sh 의 같은 CONTRACT).
// 상대경로는 lane 의 cwd 에 따라 갈리므로 레포 기준으로 고정하고, 명령에는 따옴표로 넣는다 —
// 공백이 든 경로가 쪼개지면 실재하는 초안이 `body/unreadable` 로 막힌다.
// CONTRACT: no-body-is-one-fixed-verdict
const _pbf = typeof args?.prBodyFile === 'string' ? args.prBodyFile.trim() : '';
const prBodyFile = _pbf ? (_pbf.startsWith('/') ? _pbf : `${repo}/${_pbf}`) : null;
const shq = s => `'${s.replace(/'/g, `'\\''`)}'`;
function prBodyBlock() {
    return prBodyFile
        ? `**PR 본문 초안: \`${prBodyFile}\`** — 검사기에 \`--body-file\` 로 넘기고, 같은 파일을 읽어 ` +
          `**본문에 요약 성격 · 검증 성격 섹션이 실제로 있는가**를 판정해라. 이것이 네 몫의 전부다 — ` +
          `heading 문자열이 고정이 아니라 정규식으로 못 쓴다. 검사기가 \`body/unreadable\` 을 냈으면 본문 판정은 하지 마라.\n`
        : `**PR 본문 초안은 주어지지 않았다.** 본문 섹션을 판정하지 마라 — 검사기가 \`body/not-provided\` ` +
          `warn 을 내고, 그것을 blocking=false 로 옮기는 것이 이 항목의 고정 결과다. ` +
          `\`gh pr view\`·브랜치 파일 등에서 본문을 찾아 나서지도 마라.\n`;
}

// 결정론 스캔(secret-scan.sh) 결과를 secret-scanner 프롬프트에 싣는다(DECISIONS.md 「시크릿 검사 결정론 우선」).
// 역할을 "걸린 것 판정" 으로 좁히는 것은 auto 카테고리에서 스캔이 HITS·SENSITIVE_PATH 일 때뿐이다 — 그때만 깨끗한 나머지가
// 결정론으로 걸러졌다. always(카테고리가 늘 부른다)·SCAN_ERROR 는 결과를 참고로만 주고 지금처럼 범위 전체를 검사하게 한다.
// 패턴 정본은 secret-patterns.json 이고, 분류에는 값이 없다 — 걸린 위치·패턴 이름·민감 경로만 넘긴다.
// CONTRACT: secret-scan-prompt-has-no-values
function secretScanBlock(s) {
    const hits = Array.isArray(s.hits) ? s.hits : [];
    const sens = Array.isArray(s.sensitivePaths) ? s.sensitivePaths : [];
    const HCAP = 50;
    const narrow = s.mode === 'auto' && (s.status === 'HITS' || s.status === 'SENSITIVE_PATH');
    return (
        `**결정론 시크릿 스캔 결과 (계산됨 — 패턴 v${s.patternsVersion ?? '?'}, ${s.scannedLines ?? '?'}줄, 상태 ${s.status}):**\n` +
        (hits.length
            ? `  걸린 위치 (파일:줄 — 패턴 · 등급):\n` +
              hits.slice(0, HCAP).map(h => `    - ${h.file}:${h.line} — ${h.pattern} · ${h.grade}`).join('\n') + '\n' +
              (hits.length > HCAP || s.hitsTruncated
                  ? `    … 외 ${hits.length - Math.min(hits.length, HCAP) + (s.hitsTruncated || 0)}건 — 같은 패턴으로 diff 를 직접 훑어라\n`
                  : '')
            : `  걸린 위치: 없음\n`) +
        (sens.length ? `  민감 경로 변경(내용을 스캔할 수 없는 바이너리 포함): ${sens.join(', ')}\n` : `  민감 경로 변경: 없음\n`) +
        (narrow
            ? `**네 역할은 걸린 것의 판정과 민감 경로 파일의 내용 확인이다.** 걸린 위치마다 허용 패턴(암호문 표식·플레이스홀더·` +
              `테스트 더미값 등)을 적용해 ERROR/WARNING/제외를 정해라. 등급 removed 는 삭제 라인이다 — 이미 히스토리에 있으므로 WARNING 후보로만 본다. ` +
              `민감 경로 파일은 걸린 위치 밖도 그 파일의 추가 라인을 읽어라(패턴 밖의 기본 비밀번호·키를 찾는다). 바이너리면 무엇인지(키 저장소 등) 판정해라. `
            : `**결정론 결과는 참고로만 보고, 지금처럼 범위 전체를 전수 검사해라** ` +
              (s.status === 'SCAN_ERROR' ? `(스캔이 끝나지 않았다: ${s.reason ?? '사유 미상'}). ` : `(이 카테고리는 결정론 스캔으로 이 lane 을 건너뛰지 않는다). `) +
              `걸린 위치와 민감 경로는 먼저 볼 곳일 뿐 검사 범위가 아니다. `) +
        `패턴 표는 secret-patterns.json 이 정본이다 — 다시 정의하지 마라. 보고에 값을 옮겨 적지 마라.\n`
    );
}

function laneMetaBlock(lane) {
    const m = laneMeta[lane] ?? {};
    return (
        // tscOnly 는 jest 로 돌릴 테스트가 없다는 뜻이다. 분류기가 회귀 명령을 확정했으면(Python 테스트·meta-test 등) "실행 가능한 테스트가
        // 없다·tsc 만" 은 거짓이고, lane 이 따르면 회귀 명령을 건너뛰어 기록이 suite-not-run 으로 거부된다 — 그때는 jest 만 건너뛰라고 한다.
        (m.tscOnly
            ? (m.suites?.some(x => x.name !== 'mutation')
                ? `이 레포에는 jest 로 돌릴 테스트가 없다 — jest 는 건너뛴다고 명시해라. 아래 회귀 명령은 그대로 돌린다.\n`
                : `이 레포에는 실행 가능한 테스트가 없다 — \`tsc --noEmit\` 만 돌리고 jest 는 건너뛴다고 명시해라.\n`)
            : '') +
        (m.eslintConfig === false ? `이 레포에는 eslint 설정이 없다 — 린트 단계는 건너뛰고 그 사실을 보고해라.\n` : '') +
        (m.forcedBy ? `이 lane 은 ${m.forcedBy} 로 강제 실행됐다.\n` : '') +
        (m.conventionScope && lane === 'test-runner'
            ? `**이 레포는 사내 관례의 대상이 아니다** (${m.conventionScope}). 관례 검사(0.5)는 **돌리지 마라** — ` +
              `기본 경로의 convention-check.sh 도 마찬가지다. 건너뛴 사실을 reason 에 한 번만 적고 findings 로 내지 마라.\n`
            : m.conventionScope
            ? `**이 레포는 관례 문서의 대상이 아니다** (${m.conventionScope}). 관례 판정을 하지 말고, ` +
              `문서가 없다·기준이 없다는 사실도 findings 로 내지 마라 — 동작의 결함(영속·부수효과·계약)만 본다.\n`
            : m.conventionDoc
                ? `**관례 문서는 \`${m.conventionDoc}\` 다** (확정값 — \`$VAULT_DIR\` 로 다시 찾지 마라).\n`
                : m.conventionDocMissing
                    ? `관례 문서를 찾지 못했다 (${m.conventionDocMissing}). 관례 판정을 하지 말고 그 사실을 한 번만 남겨라.\n`
                    : '') +
        (m.diffRange
            ? `**검사 범위는 \`git diff ${m.diffRange} HEAD\` 다** (PR 에는 커밋만 들어간다). PR 게이트는 커밋 이후에 돌기 때문에 ` +
              `\`--cached\` 나 \`diff HEAD\` 는 비어 있다 — 그것을 "검사할 것이 없다"로 읽지 마라.\n`
            : '') +
        (m.placement ? `⚠️ ${m.placement}\n` : '') +
        // 결정론 스캔(secret-scan.sh)이 넘긴 것. 값은 분류에 없다 — 위치와 패턴 이름뿐이다.
        (m.scan && lane === 'secret-scanner' ? secretScanBlock(m.scan) : '') +
        (m.modules || m.apiFiles
            ? `**이번 변경이 닿은 곳 (계산됨 — 다시 찾지 마라):**\n` +
              (m.modules?.length ? `  모듈: ${m.modules.join(', ')}\n` : '  모듈: (없음)\n') +
              (m.apiFiles?.length ? `  API 파일: ${m.apiFiles.join(', ')}\n` : '  API 파일: (없음 — 컨트롤러 변경 아님)\n') +
              (m.repoNote ? `  레포가 무엇을 하는 곳인지: ${m.repoNote} 를 읽어라 (코드에서 재구성하지 마라)\n` : '') +
              (m.devBaseUrl
                  ? `  **dev base URL: ${m.devBaseUrl}** (배포된 API Gateway 에서 해석됨 — 확정값이다)\n`
                  : m.devBaseUrlError
                      ? `  dev base URL 미해석: ${m.devBaseUrlError} — 직접 확인하고 근거를 보고에 적어라\n`
                      : '') +
              `\`serverless.yml\`·\`env/*.yml\`·\`git log\`·\`cat docs/*.md\` 로 엔드포인트나 레포를 ` +
              `파악하는 데 시간을 쓰지 마라 — 전사 실측에서 도구호출 82회 중 66회(81%)가 그 재발견이었고 ` +
              `실제 요청은 5회였다. 게다가 그 파일들에는 답이 없다(customDomain 부재, env 는 정확도 1/5).\n`
            : '') +
        (m.suites?.some(x => x.name !== 'mutation')
            ? `**이 레포의 회귀 명령 (계산됨 — 고르지 말고 전부 돌려라):**\n` +
              m.suites.filter(x => x.name !== 'mutation').map(x => `  - ${x.name}: \`${withSnap(x.cmd)}\` (이번 변경: ${x.why.slice(0, 5).join(', ')}${x.why.length > 5 ? ` 외 ${x.why.length - 5}건` : ''})`).join('\n') + '\n' +
              `기준선 비교 없이 하나라도 실패하면 verdict=FAIL + blocking=true 다. 통과·실패 수를 metrics 에 적어라. ` +
              `돌리지 못했으면 그것도 FAIL 이다 — 건너뛴 회귀 명령은 통과가 아니고, 기록 단계가 실행 흔적을 확인한다.\n` +
              `각 명령은 포그라운드로 끝까지 돌려라(Bash \`timeout: 600000\`, \`run_in_background\` 금지) — 종료 코드와 통과·실패 수를 보기 전에 보고하지 마라.\n` +
              (m.suites.some(x => x.name === 'meta-test')
                  ? `meta-test 의 검사 대상은 출력의 "== 격리 실행" 줄로 확인하라 — \`~/.claude\` 설치본과의 차이는 판정 근거가 아니다.\n`
                  : '')
            : '') +
        (m.conventionCheck
            ? `**관례 검사는 \`${m.conventionCheck} <변경 파일>\` 로 돌려라 — 경로는 확정값이다, \`~/.claude\` 를 가정하지 마라.**\n`
            : '') +
        (m.checker
            ? `**포맷 검사는 \`${m.checker} ${repo}${m.base ? ` --base ${m.base}` : ''}${prBodyFile ? ` --body-file ${shq(prBodyFile)}` : ''}\` 로 먼저 돌려라.** ` +
              `브랜치명·커밋 형식·커밋 언어·PR 제목은 그 검사기가 결정론으로 판정한다 — 네가 다시 세지 마라.\n` +
              `브랜치는 \`${m.branch}\`, base 는 \`${m.base ?? '(미해석)'}\` 다. \`git branch\`/\`git log\` 으로 재발견하지 마라.\n` +
              `PR 제목 초안이 주어졌으면 \`--title\` 로 넘겨라.\n` +
              prBodyBlock()
            : '') +
        (m.diffRange === null
            ? `base 를 해석하지 못했다(${m.reason}). 검사 범위를 좁힐 근거가 없으므로 ` +
              `**브랜치 전체 커밋**을 대상으로 보고, 그 사실을 reason 에 남겨라.\n`
            : '') +
        (m.publicTypeSurfaceHits?.length
            ? `공개 타입 표면에 닿은 파일(계산됨): ${m.publicTypeSurfaceHits.join(', ')}\n`
            : '') +
        (m.planQa?.items?.length
            ? `**결속된 계획(${m.planQa.planId})이 QA 로 닫으라고 한 항목 (계산됨 — 다시 찾지 마라):**\n` +
              m.planQa.items.map(i => `  - ${i.ref}: ${i.what} (claim ${i.id}: ${i.claim})`).join('\n') + '\n' +
              (lane === 'qa-runner'
                  ? `시나리오마다 \`scenarios[].claimRefs\` 에 그 시나리오가 닫는 참조를 **위 문자열 그대로** 적어라. ` +
                    `밟지 못한 항목은 result=NOT_RUN 시나리오로 남기고 note 에 이유를 적어라 — 빠뜨리면 기록에 "덮이지 않음" 으로 남는다.\n`
                  : `실행자가 단 \`claimRefs\` 가 그 항목을 **실제로 밟았는지** 심사해라. 참조만 달고 다른 것을 확인했으면 지적이다.\n`)
            : m.planQa?.error
                ? `결속된 계획의 QA 항목을 읽지 못했다: ${m.planQa.error}. 계획 대응 없이 검증하고 그 사실을 보고해라.\n`
                : '') +
        (m.planReview?.items?.length && lane === 'code-reviewer'
            ? `**결속된 계획(${m.planReview.planId})이 리뷰로 닫으라고 한 항목 (계산됨 — 다시 찾지 마라):**\n` +
              m.planReview.items.map(i => `  - ${i.ref}: ${i.what} (claim ${i.id}: ${i.claim})`).join('\n') + '\n' +
              `\`reviewed[]\` 에 **항목마다** ref(위 문자열 그대로)·seen·evidence 를 채워라. evidence 에는 본 파일:줄과 ` +
              `무엇을 확인했는지를 적는다. 못 봤으면 seen=false 와 이유다 — requirements-tracer 가 이 기록으로만 리뷰 축을 닫는다.\n` +
              (prBodyFile
                  ? `PR 본문 초안: \`${prBodyFile}\` — 위 항목 중 PR 본문을 대상으로 하는 것은 이 파일을 읽어 판정해라 ` +
                    `(본문 섹션 형식은 네 몫이 아니다).\n`
                  : '')
            : '') +
        (m.planTest?.items?.length && lane === 'test-runner'
            ? `**결속된 계획(${m.planTest.planId})이 테스트로 닫으라고 한 항목 (계산됨 — 다시 찾지 마라):**\n` +
              m.planTest.items.map(i => `  - ${i.ref}: ${i.what} (claim ${i.id}: ${i.claim})`).join('\n') + '\n' +
              `\`tested[]\` 에 **항목마다** ref(위 문자열 그대로)·test·ran·passed·evidence 를 채워라. test 는 그 항목을 검사하는 ` +
              `테스트 파일과 이름, evidence 는 이번 실행 출력의 해당 줄이다. 대응 테스트가 없거나 돌지 않았으면 ran=false 와 이유다 — ` +
              `requirements-tracer 가 이 기록으로만 테스트 축을 닫는다. 테스트를 새로 쓰지 마라.\n`
            : '') +
        // CONTRACT: mutations-run-in-gate — 변이는 test-runner 가 격리 worktree 에서 하네스로 돌린다.
        (m.mutations && lane === 'test-runner'
            ? `**변이 확인 항목 (계산됨 — 고르지 말고 돌려라):** ${m.mutations.refs.join(', ')}\n` +
              (snaps.mutation
                  ? `게이트가 변이 전용 체크아웃 \`${snaps.mutation.path}\` 를 만들어 두었다 (만들거나 지우지 마라). 다음을 **그대로** 실행해라:\n` +
                    `  \`${((m.suites ?? []).find(x => x.name === 'mutation')?.cmd ?? '').split('<격리 worktree>').join(_sq(snaps.mutation.path))}\`\n`
                  : `**변이 전용 체크아웃을 만들지 못했다** (${snapError ?? '사유 미상'}). 변이를 돌리지 말고 해당 참조를 ran=false 로 남겨라.\n`) +
              `하네스가 변이마다 patch 적용 → \`${m.mutations.cmd}\` → 원복을 하고, stderr 에 \`MUTATION <name> <status>\` 와 ` +
              `\`REF <ref> <status>\` 줄을 낸다. 그 참조의 \`tested[]\` 는 이것으로 채운다: killed → ran=true·passed=true, ` +
              `survived·compile-error·timeout → ran=true·passed=false(compile-error 는 단언이 아니라 컴파일이 잡은 것이다), patch-miss·baseline-failed → ran=false. ` +
              `변이가 여럿이면 오래 걸린다 — 도구 시간 상한에 걸리지 않게 백그라운드로 돌리고 끝을 기다려라. test 에는 변이 이름, evidence 에는 그 MUTATION 줄을 옮겨라.\n` +
              `이 하네스의 exit 1(닫히지 않은 참조가 있음)은 네 verdict 를 FAIL 로 만들지 않는다 — 판정은 요구사항 추적이 tested[] 로 한다. ` +
              `exit 2(사용법·안전 오류)이거나 돌리지 못했으면 FAIL 이다. **변이를 직접 만들거나 고치지 마라** — 명세에 있는 것만 돈다.\n`
            : '') +
        (m.planTest && lane === 'requirements-tracer'
            ? (m.planTest.items?.length
                  ? `**테스트 축(how: test)은 test-runner 보고의 \`tested[]\` 로만 판정한다.** 계획의 테스트 항목: ` +
                    m.planTest.items.map(i => i.ref).join(', ') + '\n' +
                    (m.planTest.testRunnerNotSelected
                        ? `test-runner 는 이번 게이트에서 돌지 않았다 (${m.planTest.testRunnerNotSelected}). 테스트 항목은 MISSING 으로 두고 그 사유를 note 에 적어라.\n`
                        : `ran=true·passed=true 이고 test 가 지목 가능하면 FOUND, ran=true·passed=false 는 실패, 그 밖이거나 보고에 없으면 MISSING 이다. ` +
                          `판정 근거로 그 test·evidence 를 claims[].note 에 **인용**해라. 테스트를 직접 돌리거나 spec 존재만으로 메우지 마라.\n`) +
                    (m.planTest.mutations?.status === 'FOUND'
                        ? `변이 확인 항목(${m.planTest.mutations.refs.join(', ')})은 test-runner 가 게이트 안에서 변이 하네스로 실행한다 — ` +
                          `tested[] 의 evidence 가 \`MUTATION <name> killed\` 줄이면 그 변이가 테스트를 실패시켰다는 실행 근거다. ` +
                          `명세의 patch 가 그 항목이 말하는 변이와 맞는지, 테스트 명령 \`${m.planTest.mutations.cmd ?? '?'}\` 이 그 항목이 가리키는 테스트를 실제로 돌리는지도 보라 ` +
                          `(명세: ${m.planTest.mutations.path}). 명령이 그 항목의 테스트가 아닌 다른 것(예: 원문 grep)을 검사하면 테스트 단언 없이도 변이가 killed 가 된다 — 어느 하나라도 어긋나면 그 항목을 MISSING 으로 두고 note 에 적어라.\n`
                        : m.planTest.mutations?.status === 'NONE'
                            ? `변이 명세가 없다 — 코드를 바꿔 실행해야 하는 "변이 확인" 항목은 게이트 안에서 돌지 않았다. ` +
                              `그 항목은 MISSING 으로 두고, note 에 "변이 명세를 ${m.planTest.mutations.path} 에 두면 게이트가 실행한다" 를 적어라.\n`
                        : m.planTest.mutations
                            ? `변이 명세를 쓰지 못했다 (${m.planTest.mutations.status}: ${(m.planTest.mutations.errors ?? []).join('; ') || m.planTest.mutations.reason || ''}). ` +
                              `"변이 확인" 항목은 MISSING 으로 두고 그 사유를 note 에 적어라.\n`
                            : '')
                  : m.planTest.error
                      ? `계획의 테스트 항목을 읽지 못했다: ${m.planTest.error}. 그 사실을 보고해라.\n`
                      : '')
            : '') +
        (m.planReview && lane === 'requirements-tracer'
            ? (m.planReview.items?.length
                  ? `**리뷰 축(how: review)은 code-reviewer 보고의 \`reviewed[]\` 로만 판정한다.** 계획의 리뷰 항목: ` +
                    m.planReview.items.map(i => i.ref).join(', ') + '\n' +
                    (m.planReview.reviewerNotSelected
                        ? `code-reviewer 는 이번 게이트에서 돌지 않았다 (${m.planReview.reviewerNotSelected}). 리뷰 항목은 MISSING 으로 두고 그 사유를 note 에 적어라.\n`
                        : `seen=true 이고 evidence 가 지목 가능하면 FOUND, seen=false 이거나 보고에 없으면 MISSING 이다. ` +
                          `판정 근거로 그 evidence 를 claims[].note 에 **인용**해라. 코드를 직접 다시 리뷰해 메우지 마라.\n`)
                  : m.planReview.error
                      ? `계획의 리뷰 항목을 읽지 못했다: ${m.planReview.error}. 그 사실을 보고해라.\n`
                      : '')
            : '') +
        (lane === 'requirements-tracer' && m.qaCoverage
            ? (m.approval !== 'APPROVED'
                  ? `⚠️ 이 계획은 **승인되지 않았다** (approval=${m.approval ?? 'NONE'}). 판정은 그대로 내되 reason 첫머리에 "미승인 계획" 을 밝혀라.\n`
                  : '') +
              `**QA 축(validate)은 아래 기록으로만 판정한다 — 계산됨, 다시 찾지 마라.** 브랜치 커밋의 QA 기록 ${m.qaRecords?.length ?? 0}건` +
              (m.qaRecords?.length ? `: ${m.qaRecords.map(r => `${r.commit}${r.error ? ' (읽기 실패)' : r.ignored ? ` (다른 계획 ${r.planId ?? '?'} — 세지 않음)` : ` ${r.verdict ?? '?'}`}`).join(', ')}` : '') + '\n' +
              (Object.keys(m.qaCoverage).length
                  ? `계획 QA 항목별 최신 상태 (가장 늦은 커밋의 기록이 정한다):\n` +
                    Object.entries(m.qaCoverage).map(([r, st]) => `  - ${r}: ${st}`).join('\n') + '\n' +
                    `PASS 만 validate FOUND 다. NOT_RUN 은 NOT_RUN, MISSING 은 MISSING 이다 — QA 보고를 다른 데서 찾아 메우지 마라.\n`
                  : `계획에 how: qa 항목이 없다 — validate 축은 해당 없음(—)이다.\n`) +
              (m.designDoc?.status === 'CHANGED'
                  ? `설계 문서 ${m.designDoc.path} 가 계획이 가리키는 ${String(m.designDoc.sha).slice(0, 12)} 이후 바뀌었다 (${(m.designDoc.commits ?? []).join(', ')}). ` +
                    `계획이 그 변경을 따라갔는지 보고 blocking=false 로 남겨라.\n`
                  : m.designDoc?.status === 'UNKNOWN'
                      ? `설계 문서 변경 여부를 확인하지 못했다 (${m.designDoc.reason ?? ''}) — 그 사실만 남겨라.\n`
                      : '')
            : '') +
        (m.plan ? `계획: ${m.plan.path} (planId ${m.plan.planId}, requirement ${m.plan.requirements} / invariant ${m.plan.invariants})\n` : '') +
        // 로컬 vault 워킹트리는 원격보다 수백 커밋 뒤처져 있을 수 있다. 분류기가 본 기준선을 그대로 쓴다.
        (m.vaultSource?.mode === 'remote'
            ? `**vault 파일은 \`git -C ${shq(m.vaultSource.vaultDir)} show ${m.vaultSource.sha}:<경로>\` 로 읽어라** ` +
              `(${m.vaultSource.ref} @ ${m.vaultSource.sha.slice(0, 12)}, 방금 fetch 함). 위 노트 경로와 스킬·조직 인덱스 모두 같다. ` +
              `워킹트리(\`cat\`·Read)를 읽지 마라 — 로컬 클론은 원격보다 뒤처져 있어 이미 갱신된 노트를 낡았다고 보고하게 된다. ` +
              `워킹트리를 checkout·pull·수정하지도 마라 (다른 세션의 스테이징 작업이 있다).\n`
            : m.vaultSource
                ? `⚠️ vault 원격 기준선을 쓰지 못했다: ${m.vaultSource.stale}. 워킹트리 \`${m.vaultSource.vaultDir}\` 를 읽되, ` +
                  `**reason 첫머리에 "vault 워킹트리 기준 — 낡았을 수 있음" 을 밝히고** 드리프트 지적은 전부 blocking=false 로 내라.\n`
                : '')
    );
}

// 증거 체인의 앞 lane 이 끝나면 풀리는 자리. 뒤 lane 은 agent() 를 부르기 **전에** 기다리므로
// 동시 실행 슬롯을 잡고 있지 않다 — 앞 lane 이 슬롯을 못 얻어 서로 기다리는 일이 없다.
const gateDone = {};
for (const l of laneList) {
    let resolve;
    gateDone[l] = { promise: new Promise(r => { resolve = r; }), resolve };
}
async function upstreamBlock(lane) {
    let out = '';
    for (const a of needsOf[lane] ?? []) {
        if (!gateDone[a]) continue;
        const r = await gateDone[a].promise;
        out += r
            ? `\n[${a} 의 보고 — 이번 라운드, 네가 시작하기 전에 끝났다]\n${JSON.stringify(r, null, 2)}\n`
            : `\n**${a} 의 보고가 없다** (실행 실패). 그 보고로만 닫히는 항목은 MISSING 으로 두고 사유를 적어라.\n`;
    }
    return out;
}

async function runGateLane(lane) {
    const upstream = await upstreamBlock(lane);
    // 기준선을 기다리는 것은 이 lane 하나다. 나머지는 즉시 시작한다.
    // CONTRACT: baseline-awaited-by-test-runner-only
    if (lane === 'test-runner' && baselinePromise) {
        baseline = await baselinePromise;
        // CONTRACT: baseline-discard-on-wrong-lane
        if (baseline && baseline.lane !== 'baseline') {   // 스키마가 뚫렸을 때의 2차 방어
            log(`기준선 폐기 — lane 이 "${baseline.lane}" 이다 (baseline 이어야 한다)`);
            baseline = null;
        }
        log(`기준선: ${baseline?.metrics ?? '(수집 실패 — 회귀 판정을 신뢰하지 마라)'}`);
    }
    // 체크아웃이 필요한 lane 인데 만들지 못했으면 돌리지 않는다 — 결과 없음은 ERROR 로 집계된다(I4).
    if (lane === 'test-runner' && SNAP?.checkout && !snaps.target) {
        log(`test-runner 를 돌리지 않는다 — ${snapError ?? '스냅숏 없음'}`);
        return null;
    }
    return gateAgent(
        `대상 레포: ${repo}\n게이트 모드: ${mode}${round > 1 ? ` (라운드 ${round})` : ''}\n\n${laneScope(lane)}\n\n` +
            snapFor(lane) +
            laneMetaBlock(lane) +
            (lane === 'test-runner'
                ? baseline?.metrics
                    ? `기준선: ${baseline.metrics}\n` + (snaps.baseline ? BASE_HEAD_NOTE : '')
                    : `**기준선 수집에 실패했다.** 회귀 판정의 근거가 없다 — merge-base 기준선을 네가 직접 잡거나, ` +
                      `못 잡으면 그 사실을 findings 에 남기고 기존 실패를 "새로 깨진 것" 으로 올리지 마라.\n`
                : '') +
            upstream +
            priorBlock(lane) +
            `\n네 에이전트 정의의 판정 기준으로 검사하고 **구조화 출력**으로 보고해라.\n` +
            `- lane 에는 "${lane}" 을 넣어라.\n` +
            `- ${MAPPING[lane] ?? 'blocking=true 는 커밋·머지를 막아야 하는 것만.'}\n` +
            (rulesFor(lane)
                ? `- **findings[].rule 은 아래 어휘에서 고른다** — id 는 하네스가 rule·file·symbol 로 만든다. ` +
                  `결함 하나에 rule 하나다. 원인이 아니라 **결과**로 고른다.\n` +
                  Object.entries(rulesFor(lane)).map(([r, d]) => `    · \`${r}\` — ${d}`).join('\n') + '\n' +
                  `- findings[].symbol: ${SYMBOL_HINT[lane] ?? '결함이 있는 심볼 이름'}.\n`
                : `- findings[].id 는 같은 결함이면 항상 같은 값이어야 한다.\n`) +
            `- **파일을 수정하거나 커밋하지 마라.** 판정만 낸다.\n` +
            `- 지적거리를 억지로 만들지 마라. 깨끗하면 findings 를 비우고 PASS 를 내라.`,
        { agentType: lane, label: lane, phase: 'Gate', schema: laneSchema(lane),
          ...(EFFORT[lane] ? { effort: EFFORT[lane] } : {}),
          // 측정 전용 override 가 마지막이다 — 주어진 lane 에서만 위 값을 덮는다(CONTRACT: lane-override-measurement-only)
          ...(LANE_MODEL[lane] ? { model: LANE_MODEL[lane] } : {}),
          ...(LANE_EFFORT[lane] ? { effort: LANE_EFFORT[lane] } : {}) },
    ).catch(() => null);
}

// ── 게이트: 선택된 lane 을 동시에. 증거 체인의 뒤 lane 만 앞 lane 을 기다린다.
// 스냅숏은 게이트와 QA 가 끝나면 지운다 — 도중에 예외가 나도 지운다(CONTRACT: snapshot-cleaned-in-finally).
let results;
const seqResults = [];
let rmPromise = null;
try {
phase('Gate');
// ③ 은 lane 과 겹쳐 돈다 — 기다리는 것은 이 try 의 끝이다. 대상이 0건이면 부르지 않는다.
rmPromise = runRemeasure().catch(() => { rmOut = null; });
results = await parallel(
    laneList.map(lane => async () => {
        let res = null;
        try { res = await runGateLane(lane); } finally { gateDone[lane].resolve(res); }
        return res;
    }),
);

// ── QA: 순차. runner 의 결과를 reviewer 가 심사하는 구조라 병렬로 띄우면 의미가 없다.
for (const chain of qaChains) {
    phase('QA');
    let prior = null;
    for (const lane of chain) {
        const r = await gateAgent(
            `대상 레포: ${repo}\n게이트 모드: ${mode}${round > 1 ? ` (라운드 ${round})` : ''}\n\n${laneScope(lane)}\n\n` +
                snapFor(lane) +
                laneMetaBlock(lane) +
                priorBlock(lane) +
                (prior
                    ? `\n[${chain[0]} 의 보고]\n${JSON.stringify(prior, null, 2)}\n\n이 보고 자체를 심사해라.\n`
                    : `\n배포된 **dev** 환경을 검증해라. **운영(prod) 에는 절대 접근하지 마라.**\n`) +
                //! 검증 대상을 고정하는 통로. 없으면 qa-runner 가 스스로 최신 커밋을 골라
                //!  게이트가 의도한 것과 다른 변경을 검증하고 끝난다.
                (args?.qaFocus ? `\n**검증 대상은 아래로 고정한다. 다른 대상을 스스로 고르지 마라.**\n${args.qaFocus}\n` : '') +
                //! 세션 토큰은 **경로로만** 넘긴다 — 값이 프롬프트·워크플로 로그에 남지 않게 한다.
                //!  이게 없으면 QA 는 주문 생성 경로를 못 타고, 실제로 서명키로 세션을 위조한 적이 있다.
                //!  세션 헤더 이름·함께 보낼 서명 방식은 카테고리 규칙이다(qa_meta 의 sessionHeader·sessionNote).
                (args?.qaSessionFile
                    ? `\n**세션이 필요하면 \`${args.qaSessionFile}\` 의 첫 줄을 ` +
                      (laneMeta['qa-runner']?.sessionHeader
                          ? `\`${laneMeta['qa-runner'].sessionHeader}\` 헤더로 쓴다** `
                          : `세션 값으로 쓴다** (헤더 이름은 카테고리가 주지 않았다 — 레포 문서에서 확인하고 근거를 보고에 적어라) `) +
                      `(\`IDENT=$(head -1 <파일>)\`).${laneMeta['qa-runner']?.sessionNote ? ` ${laneMeta['qa-runner'].sessionNote}` : ''}\n` +
                      `**토큰 값을 보고서에 인용하지 마라.** 세션 만료 응답이면 재발급을 시도하지 말고 ` +
                      `\`세션 만료 — 검증 불가\` 로 보고해라. 서명키로 세션을 직접 발급하는 것은 **금지**다.\n`
                    : '') +
                `\n구조화 출력으로 보고해라. lane 에는 "${lane}" 을 넣어라.\n` +
                `- ${MAPPING[lane] ?? 'blocking=true 는 커밋·머지를 막아야 하는 것만.'}`,
            { agentType: lane, label: lane, phase: 'QA', schema: laneSchema(lane) },
        ).catch(() => null);
        // 앞 lane 이 죽었는데 계속하면 prior 가 null 이라 심사자가 "dev 를 검증해라" 분기를 받아
        // **두 번째 실행자**가 된다 — 부수효과가 두 번 난다. 남은 lane 은 결과 없이 채우고 끊는다.
        // (break 하면 selected 에 있던 lane 이 통째로 빠져 영수증의 lane 완전성 검사에 걸린다)
        // CONTRACT: qa-chain-breaks-on-death
        if (!r) {
            for (const rest of chain.slice(chain.indexOf(lane))) seqResults.push([rest, null]);
            break;
        }
        seqResults.push([lane, r]);
        prior = r;
    }
}

await rmPromise;
} finally {
    // ③ 이 아직 읽고 있을 수 있다 — 끝난 뒤에 지운다. 대상 레포 스냅숏과 등록 레포 스냅숏 둘 다.
    await rmPromise?.catch(() => null);
    await cleanupSnapshots();
    await cleanupRemeasure();
}

// ── 집계: 결정론적. LLM 이 판정을 다시 내리지 않는다.
//    에이전트가 죽어 결과가 없으면 ERROR 다 — 결과가 없는 것은 문제가 없다는 뜻이 아니다.
const pairs = [...laneList.map((l, i) => [l, results[i]]), ...seqResults];
const lanes = {};
const blocking = [];
const warnings = [];   // 승인이 필요한 것 (verdict=WARNING)
const notes = [];      // 참고 — MAPPING 이 verdict 와 무관하게 blocking=false 를 내라고 지시한다
                       // (code-reviewer "참고", test-runner 기존 실패, requirements-tracer 계획 밖 구현).
                       // 이 자리가 없으면 verdict=PASS 로 온 참고가 어디에도 안 담겨 사라진다.

for (const [lane, r] of pairs) {
    // thunk 가 스스로 null 을 돌려주므로(위 Gate·QA 의 `.catch(() => null)`) 이 분기는 도달한다.
    // 런타임의 거부 전파 규약에 기대지 않는다 — 규약이 무엇이든 lane 하나의 사망이
    // 집계·report 를 막지 못한다.
    if (!r) {
        lanes[lane] = { status: 'ERROR', reason: '에이전트가 결과를 내지 못했다 (사망/타임아웃)' };
        continue;
    }
    // 어휘가 있는 lane 은 id 를 계산값으로 바꾼다. lane 이 지은 이름은 label 로 남긴다.
    // 같은 lane 안에서 계산 id 가 같은 지적은 하나로 접는다(foldFindings). 어휘 없는 lane 은 그대로 둔다.
    const mapped = (r.findings ?? []).map(f => rulesFor(lane) && f.rule
        ? { ...f, lane, label: f.id, id: findingId(f, { repo, prBodyFile }) }
        : { ...f, lane });
    const fs = rulesFor(lane) ? foldFindings(mapped) : mapped;
    const blk = fs.filter(f => f.blocking);
    blocking.push(...blk);
    warnings.push(...fs.filter(f => !f.blocking && r.verdict === 'WARNING'));
    // CONTRACT: notes-preserved-regardless-of-verdict
    notes.push(...fs.filter(f => !f.blocking && r.verdict !== 'WARNING'));
    if (blk.length || r.verdict === 'FAIL') {
        lanes[lane] = { status: 'FAIL', reason: `blocking ${blk.length}건` + (r.metrics ? ` · ${r.metrics}` : '') };
    } else if (r.verdict === 'WARNING' && NO_WARNING.has(lane)) {
        // 스키마가 뚫렸을 때의 2차 방어 — 승인으로 넘길 수 있는 상태로 두지 않는다
        lanes[lane] = { status: 'ERROR', reason: `WARNING 층이 없는 lane 이 WARNING 을 냈다 — 막을지 참고로 남길지 다시 판정해야 한다` };
    } else if (r.verdict === 'WARNING') {
        lanes[lane] = { status: 'WARNING', reason: `확인 필요 ${fs.length}건 — 사용자 승인 없이 통과시키지 마라` + (r.metrics ? ` · ${r.metrics}` : '') };
    } else if (r.verdict === 'NOT_APPLICABLE') {
        lanes[lane] = { status: 'NOT_APPLICABLE', reason: '에이전트가 대상 아님으로 판정' };
    // CONTRACT: unknown-verdict-fail-closed
    } else if (r.verdict === 'PASS') {
        lanes[lane] = { status: 'PASS', reason: r.metrics || undefined };
    } else {
        // 열거 밖 값이나 verdict 누락이 PASS 로 떨어지면 fail-open 이다. 게이트의 나머지는
        // 전부 fail-closed 인데 이 자리만 반대였다.
        lanes[lane] = { status: 'ERROR', reason: `알 수 없는 verdict: ${JSON.stringify(r.verdict)}` };
    }
    if (fs.length) {
        // CONTRACT: findings-kept-on-lane
        lanes[lane].findings = fs;   // 판정에는 안 쓰지만 기록에서 사라지면 안 된다
    }
}
for (const [lane, reason] of Object.entries(notSelected)) {
    lanes[lane] = { status: 'SKIPPED', reason };
}

// ── 사실 주장 검사 — 분류기가 결정론으로 이미 돌렸다(cls.claimCheck). lane 이 아니므로 판정·영수증에
//    들어가지 않는다. warn 은 참고로 옮긴다 — 4축 실측 전이라 막지도, 승인을 요구하지도 않는다.
// CONTRACT: claim-check-is-advisory
const claim = cls.claimCheck ?? null;
for (const f of (claim?.findings ?? []).filter(f => f.severity === 'warn')) {
    notes.push({ lane: 'claim-check', file: f.file, line: f.line, rule: f.rule, blocking: false,
                 summary: `${f.message} — "${String(f.text ?? '').slice(0, 80)}"` });
}

// ③ 재측정 — 판정·영수증 밖. 결과가 없거나 독립적이지 않거나 코퍼스가 확인되지 않으면 그 상태 그대로 참고로 낸다
// (어느 것도 "불일치 없음" 으로 보이지 않게 — 일치만 참고에서 빠진다).
// CONTRACT: claim-remeasure-is-advisory
const RM_RULE = { mismatch: '불일치', 'population-differs': '모집단 다름', unmeasurable: '측정 불가', 'not-independent': '독립성 미확보' };
const rmJudged = rmPicked.length && rmOut
    ? remeasureJudge(rmPicked, rmOut, remeasureOffered(), { unusable: rmRepos.filter(x => x.status !== 'usable').map(x => x.name) }) : [];
for (const r of rmJudged.filter(x => x.state !== 'match')) {
    const m = r.measured;
    notes.push({ lane: 'claim-remeasure', file: r.file, line: r.line, rule: `remeasure/${r.state}`, blocking: false,
                 summary: `재측정 ${RM_RULE[r.state]} — "${String(r.text ?? '').slice(0, 80)}"` +
                     (r.slots?.length ? ` · 자리 ${r.slots.map(x => `${x.slot} ${x.claimed ?? '?'}→${x.measured ?? '?'} ${x.state}`).join(', ')}` : '') +
                     (m ? ` · 측정 ${m.corpus}: N=${m.population} with=${m.with} without=${m.without} · 방법 ${(m.commands ?? []).join(' ; ').slice(0, 160)} · 정의 ${String(m.property).slice(0, 80)}` : '') +
                     (m?.excluded?.length ? ` · 제외 ${m.excluded.map(e => `${e.repo}: ${String(e.reason).slice(0, 80)}`).join('; ')}` : '') +
                     (m?.snapshotMayDiffer ? ` · ${m.snapshotMayDiffer}` : '') +
                     (r.scopeUnverified ? ` · ${r.scopeUnverified}` : '') +
                     (r.reason ? ` · ${r.reason}` : '') });
}
if (rmPicked.length && !rmOut)
    notes.push({ lane: 'claim-remeasure', rule: 'remeasure/failed', blocking: false,
                 summary: `재측정 실패 — 대상 ${rmPicked.length}건을 재측정하지 못했다 (에이전트가 결과를 내지 못했다: 사망·타임아웃·스키마 위반). 불일치가 없다는 뜻이 아니다` });
if (rmOverCap > 0)
    notes.push({ lane: 'claim-remeasure', rule: 'remeasure/over-cap', blocking: false,
                 summary: `재측정하지 않은 대상 ${rmOverCap}건 — 게이트 한 번의 상한 ${REMEASURE_MAX_CLAIMS}건을 넘었다` });
const rmUnusable = rmRepos.filter(x => x.status !== 'usable');
if (rmPicked.length && rmUnusable.length)
    notes.push({ lane: 'claim-remeasure', rule: 'remeasure/registry-unusable', blocking: false,
                 summary: `사용하지 못한 등록 레포 ${rmUnusable.length}개 — ` + rmUnusable.map(x => `${x.name}: ${x.reason}`).join('; ') });

const failed = Object.entries(lanes).filter(([, v]) => v.status === 'FAIL' || v.status === 'ERROR');
const warned = Object.entries(lanes).filter(([, v]) => v.status === 'WARNING');
const verdict = failed.length ? 'FAIL' : warned.length ? 'NEEDS_CONFIRM' : 'PASS';

// 다음 라운드 args.priorFindings 의 입력이다.
const findingIds = [...new Set([...blocking, ...warnings, ...notes]
    .filter(f => f.id).map(f => `${f.lane ?? '?'}:${f.id}`))];

// ── 재발: 직전 라운드 id 와 이번 id 를 코드가 맞춘다. lane 에게 "재발이냐" 를 묻지 않는다.
// 해소는 **이번에 그 파일을 실제로 본 lane** 에서만 말한다. 빠진 id 가 안 돈 lane 의 것이거나,
// 돈 lane 이라도 이번 대상 파일 밖이면(커밋 게이트는 라운드마다 스테이징 집합이 바뀐다) 고쳐진 게
// 아니라 안 본 것이다. id 를 스스로 짓는 lane 은 이름만 바꿔도 빠지므로 해소를 말하지 않는다.
// BEGIN recurrence — meta-test 가 이 구간만 떼어 실행한다. 바깥 이름을 참조하지 마라.
// CONTRACT: recurrence-is-computed
// scope: lane → 이번 라운드에 그 lane 이 본 파일 집합 (id 를 계산하는 lane 이 실제로 돌았을 때만 있다)
function recurrence(prior, current, scope) {
    const pri = new Set(prior.filter(k => typeof k === 'string' && k.indexOf(':') > 0));
    if (!pri.size) return null;
    const cur = new Set(current);
    const seen = k => {
        const lane = k.slice(0, k.indexOf(':')), id = k.slice(k.indexOf(':') + 1);
        const files = scope.get(lane);
        if (!files) return false;
        const at = id.indexOf('@');
        if (at < 0) return true;                         // 파일 없는 지적(브랜치·커밋 등)은 lane 이 돌았으면 본 것이다
        const file = id.slice(at + 1).split('#')[0];
        return files.has(file);
    };
    const gone = [...pri].filter(k => !cur.has(k));
    return {
        recurred: [...pri].filter(k => cur.has(k)),
        resolved: gone.filter(seen),
        unchecked: gone.filter(k => !seen(k)),
        new: [...cur].filter(k => !pri.has(k)),
    };
}
// END recurrence
// 본문 초안을 넘겼으면 PR 형식 lane 은 본문을 본 것이다 (findingId 가 그 경로를 pr-body 로 접는다).
const recur = recurrence(priorAll, findingIds, new Map(Object.entries(lanes)
    .filter(([l, v]) => ['PASS', 'FAIL', 'WARNING'].includes(v.status) && rulesFor(l))
    .map(([l]) => [l, new Set([...(selected[l] ?? []), ...(prBodyFile ? ['pr-body'] : [])])])));

const ICON = { PASS: '✅', SKIPPED: '⏭️', NOT_APPLICABLE: '⏭️', WARNING: '⚠️', FAIL: '❌', ERROR: '💥' };
const report =
    `=== PREFLIGHT: ${repo} (${mode}) ===\n` +
    `변경 ${cls.files?.all?.length ?? 0}건 — code ${cls.files?.code?.length ?? 0} / vault ${cls.files?.vault?.length ?? 0} / 타입표면 ${cls.files?.publicTypeSurface?.length ?? 0}\n\n` +
    Object.entries(lanes)
        .map(([l, v]) => `${ICON[v.status] ?? '?'} ${l.padEnd(17)} ${v.status}${v.reason ? ` — ${v.reason}` : ''}`)
        .join('\n') +
    (claim
        ? `\n🔎 ${'claim-check'.padEnd(17)} ${claim.status}` +
          (claim.counts
              ? ` — 주장 ${claim.counts.claims} · 출처 확인 ${claim.counts.verified} · 경고 ${claim.counts.warn} · 참고 ${claim.counts.info}`
              : claim.reason ? ` — ${claim.reason}` : '') +
          (claim.scanned?.errors?.length
              ? ` · 읽지 못한 입력 ${claim.scanned.errors.length}건 (${claim.scanned.errors[0]})` : '') +
          ' (결정론 · 판정에 영향 없음)'
        : '') +
    (rmAll.length
        ? `\n🔁 ${'claim-remeasure'.padEnd(17)} 대상 ${rmAll.length} · 재측정 ${rmPicked.length}` +
          (rmOut
              ? ` · ` + ['mismatch', 'population-differs', 'match', 'unmeasurable', 'not-independent']
                  .map(k => `${k === 'match' ? '일치' : RM_RULE[k]} ${rmJudged.filter(x => x.state === k).length}`).join(' · ')
              : ' · 재측정 실패') +
          (rmOverCap ? ` · 재측정하지 않은 대상 ${rmOverCap}` : '') + ' (참고 · 판정에 영향 없음)'
        : '') +
    `\n\n판정: ${verdict}` +
    (blocking.length
        ? `\n\n조치 필요\n` +
          blocking.map((f, i) => `${i + 1}. [${f.lane}] ${f.file ?? ''}${f.line ? `:${f.line}` : ''} (${f.id})\n   ${f.summary}${f.fix ? `\n   → ${f.fix}` : ''}`).join('\n')
        : '') +
    (warnings.length
        ? `\n\n확인 필요 (사용자 승인 없이 넘기지 마라)\n` +
          warnings.map((f, i) => `${i + 1}. [${f.lane}] ${f.file ?? ''} — ${f.summary}`).join('\n')
        : '') +
    // 판정이 조치를 요구하는데 목록이 비면 무엇을 고치거나 승인할지 알 수 없다. FAIL·WARNING 대칭.
    (failed.length && !blocking.length
        ? `\n\n판정은 FAIL 인데 blocking findings 가 없다 — 해당 lane 의 사유를 보고 판단해라\n` +
          failed.map(([l, v], i) => `${i + 1}. [${l}] ${v.reason ?? '(사유 없음)'}`).join('\n')
        : '') +
    (warned.length && !warnings.length
        ? `\n\n판정은 NEEDS_CONFIRM 인데 warning findings 가 없다 — 해당 lane 의 사유를 보고 승인 여부를 정해라\n` +
          warned.map(([l, v], i) => `${i + 1}. [${l}] ${v.reason ?? '(사유 없음)'}`).join('\n')
        : '') +
    // 계획 권고 — 판정에 개입하지 않는다. change-planner 는 호출 경로가 없어 dormant 이고,
    // 되살릴 근거가 쌓이는지 보려고 세는 것이다.
    (cls.planAdvisory
        ? `\n\n계획 권고 (판정에 영향 없음)\n` +
          `고위험 신호가 붙은 변경이다 (${cls.planAdvisory.lanes.join(', ')}) — 계획 artifact 가 `
          + (cls.planAdvisory.plan === 'UNREADABLE' ? '읽을 수 없다(파일이 깨졌다).\n'
             : cls.planAdvisory.plan === 'DANGLING' ? '결속돼 있지만 본체가 저장소에 없다.\n' : '없다.\n') +
          `구현 전에 \`change-planner\` 로 요구사항·불변식을 명시해두면 \`requirements-tracer\` 가 닫힘을 추적한다.`
        : '') +
    // 참고는 판정을 바꾸지 않지만 버리지도 않는다
    (notes.length
        ? `\n\n참고 (판정에 영향 없음)\n` +
          notes.map((f, i) => `${i + 1}. [${f.lane}] ${f.file ?? ''}${f.line ? `:${f.line}` : ''} — ${f.summary}`).join('\n')
        : '') +
    (recur
        ? `\n\n직전 라운드 대비 (계산됨): 재발 ${recur.recurred.length} · 해소 ${recur.resolved.length} · ` +
          `새로 ${recur.new.length} · 판단 불가 ${recur.unchecked.length}` +
          recur.recurred.map(k => `\n  ↻ ${k}`).join('') +
          recur.resolved.map(k => `\n  ✓ ${k}`).join('') +
          (recur.unchecked.length ? `\n  판단 불가 — 이번에 안 돈 lane · 이번 대상 밖 파일 · id 를 lane 이 짓는 lane: ${recur.unchecked.join(', ')}` : '')
        : '');

// 측정 전용 실행은 영수증에 쓸 수 없는 꼴로 낸다(CONTRACT: lane-override-measurement-only).
// 판정·보고는 위에서 평소대로 계산했다 — 바꾸는 것은 밖으로 나가는 상태 필드뿐이다.
markMeasurementOnly(lanes);

// 영수증은 판정에 쓰는 필드만 담는다 — findings 원본까지 넣으면 영수증이 붓는다.
// waived 는 여기서 세팅하지 않는다: 승인은 사람이 하고, 호출자가 이 객체를 고쳐
// receipt.sh 에 넘긴다 (아래 next 문구). 여기에 통과 분기를 두면 자동 승인 경로가
// 있는 것처럼 읽힌다.
const receiptLanes = Object.fromEntries(
    Object.entries(lanes).map(([l, v]) => [l, {
        status: v.status,
        ...(v.reason ? { reason: v.reason } : {}),
    }]),
);

// ── 워크플로 안에서 기록 (CONTRACT: auto-record-pass-only). 스냅숏·재측정 정리는 위에서 이미 끝났다 —
//    기록 에이전트가 이 워크플로의 마지막 에이전트다. 기록 시점에 이 에이전트 자신은 결과가 없지만 lane 이
//    아니어서(구조화 출력에 lane 이 없다) 전사 검증의 귀속 대상이 아니다.
const recPlan = autoRecordPlan({
    verdict, measureOnly: MEASURE_ONLY, autoRecord: args?.autoRecord, engineDir: cls.engineDir,
    receiptLanes, mode, repo, nonce: args?.runId || cls.runNonce,
    clsSha: clsLoad.sha256 ?? _sha256Hex(_utf8Encode(JSON.stringify(cls))),
});
let recorded;
if (recPlan.skip) {
    recorded = { status: 'SKIPPED', reason: recPlan.skip, output: '' };
} else {
    phase('Record');
    const r = await gateAgent(
        `아래 명령 **하나만** 글자 그대로 실행하고, 종료코드·stdout·stderr 를 **고치지 말고** 돌려줘라.\n` +
            `다른 명령은 실행하지 마라. 실패해도 다시 시도하지 마라. 출력을 요약하거나 해석하지 마라.\n` +
            `전사 표식: ${recPlan.marker}\n` +
            `- \`${recPlan.cmd}\`\n` +
            `아래 줄은 receipt.sh 가 이 프롬프트에서 직접 읽는 입력이다. 명령에 옮겨 적지 마라.\n` +
            `${recPlan.payload}`,
        { label: 'record', phase: 'Record', schema: RECORD_RESULT, model: 'haiku', effort: 'low' },
    ).catch(() => null);
    recorded = autoRecordStatus(r);
}
log(`기록: ${recorded.status} — ${recorded.reason}`);
const recordedNext = mode === 'pr'
    ? '`gh pr create`(본문은 검사한 --body-file 그대로)를'
    : `\`git -C ${repo} commit\` 을`;

return {
    repo,
    mode,
    round,
    verdict: MEASURE_ONLY ? 'MEASUREMENT_ONLY' : verdict,   // PASS | NEEDS_CONFIRM | FAIL (측정 전용이면 MEASUREMENT_ONLY)
    // 측정 전용 override 가 있었으면 그 값, 없으면 null — 채점기가 manifest 와 대조한다
    measurement: MEASURE_ONLY ? { verdict, laneModel: LANE_MODEL, laneEffort: LANE_EFFORT } : null,
    lanes,                   // 전체 lane 상태 + findings 원본 (사람이 볼 것)
    receiptLanes,
    // 워크플로 안 기록의 결과 — RECORDED 면 메인은 record 를 다시 부르지 않는다. 아니면 next 가 폴백을 안내한다.
    recorded,
    blocking,
    warnings,
    notes,
    // 다음 라운드 args.priorFindings 에 그대로 넣어라 — 재발은 그 라운드의 recurrence 가 센다
    findingIds,
    recurrence: recur,       // priorFindings 가 없으면 null
    claimCheck: claim ? { status: claim.status, counts: claim.counts ?? null } : null,
    // 데이터 스크립트로 적재했으면 대조를 통과한 분류의 sha256, 인라인이면 null
    classificationSha256: clsLoad.sha256,
    // ③ 재측정 — 판정·영수증 밖. 채점기(eval/flip.sh remeasure-score)가 results 의 state 를 센다.
    claimRemeasure: rmAll.length ? {
        targets: rmAll.length, remeasured: rmPicked.length, overCap: rmOverCap, calls: rmCalls, failed: !rmOut,
        results: rmJudged, registry: rmRepos.map(x => ({ name: x.name, status: x.status, ...(x.reason ? { reason: x.reason } : {}),
                                                        ...(x.snapshotMayDiffer ? { snapshotMayDiffer: x.snapshotMayDiffer } : {}) })),
    } : null,
    baseline: baseline?.metrics ?? null,
    report: report + `\n\n기록: ${recorded.status} — ${recorded.reason}` +
        (recorded.status === 'REFUSED' || recorded.status === 'ERROR' ? (recorded.output ? `\n${recorded.output}` : '') : ''),
    next: MEASURE_ONLY
        ? '측정 전용 실행이다(laneModel·laneEffort override) — receipt.sh record 로 기록하지 마라. 기록해도 MEASUREMENT_ONLY 상태라 거부된다. 판정은 lanes[].measuredStatus 에 있다.'
        : verdict === 'PASS' && recorded.status === 'RECORDED'
            ? `기록됨 — 워크플로 안에서 receipt.sh record 가 통과했다(via workflow). record 를 다시 부르지 마라. ` +
              `커밋 전 보고·승인 규칙은 그대로이고, 승인되면 ${recordedNext} 별도 Bash 호출로 실행해라.`
        : verdict === 'PASS'
            ? (recorded.status === 'SKIPPED' ? '' : `워크플로 안 기록이 되지 않았다(${recorded.status}: ${recorded.reason}) — 메인이 기록한다. `) +
              'receipt.sh record 로 기록해라. 스테이징은 분류 전에 끝났어야 한다 (git add → classify 순서) — **분류 뒤 인덱스가 바뀌면 재분류**하라(record 가 index-changed 로 거부한다). **워크플로 결과의 Transcript dir 을 마지막 인자로 그대로 넘겨라** — 넘겨야 실행 사실·순서·승인 흔적이 검증된다.'
            : verdict === 'NEEDS_CONFIRM'
              ? '사용자에게 warning 을 보이고 승인받아라. 승인받으면 해당 lane 만 {"status":"PASS","waived":true,"originalStatus":"WARNING","reason":"<승인 내용>"} 로 바꿔 기록한다. **전사 디렉터리를 record 에 넘기면** waived 없는 승격을 receipt 가 거부한다 (안 넘기면 규약일 뿐 강제되지 않는다).'
              : 'blocking 을 고친 뒤 classify 부터 다시 실행해라. 부분 재실행하지 마라.',
};
