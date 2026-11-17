# 테스트 전용 카테고리 — 지식 vault 문서 레포(워킹트리에 VAULT_RULES.md). meta-test 의 훅·프로필 절이 쓴다.


def match(ctx):
    return ['VAULT_RULES.md'] if (ctx.root / 'VAULT_RULES.md').is_file() else []
