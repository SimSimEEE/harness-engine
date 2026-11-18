# eval-vault 카테고리 — flip eval 입력 전용. 실제 레포는 이 카테고리에 속하지 않는다:
# flip.sh 가 입력 디렉터리의 overlay/ 를 PF_OVERLAY_DIR 로 줄 때만 적재된다.
# vault-linter 가 정의상 보는 레포(루트에 VAULT_RULES.md 가 있는 문서 레포)를 엔진 밖 규칙 없이 재현한다.
# vault_link 를 두지 않는다 — 등록 조회가 비적용(NOT_APPLICABLE)이어야 입력이 실제 vault 에 닿지 않는다.


def match(ctx):
    return ['VAULT_RULES.md'] if ctx.snap_has('VAULT_RULES.md') else []


# vault-linter 가 볼 문서: notes/ 아래 .md
def vault_docs(ctx, files):
    return [f for f in files if f.endswith('.md') and f.startswith('notes/')]
