#!/usr/bin/env python3
"""classify.json 을 Workflow 데이터 스크립트로 옮긴다 (SKILL.md pf_gate_args 가 부른다).

usage: cls-data-script.py <repo> <classify.json> <classify-sha256> <dir>
  stdout: {"classificationScript": <dir>/claude-preflight.classify.wf.js 의 절대경로, "classificationSha256": <hex>}

왜: Workflow 스크립트에는 파일시스템이 없다. 예전에는 agent() 가 파일을 base64 로 읽어 중계했는데, 모델이 출력을
다시 타이핑하며 문자를 바꿨다(DECISIONS.md). 데이터 스크립트는 `workflow({scriptPath})` 로 불려 문자열을 그대로
돌려주므로 바이트가 모델을 거치지 않는다.

거부(rc≠0, 아무것도 쓰지 않고 출력도 없다):
  - classify.json 바이트의 sha256 이 classify.sh 가 낸 값과 다르다 — 그 사이 다른 분류가 덮어썼다
  - UTF-8 이 아니다
  - <dir> 가 대상 레포 작업 트리 안이다 (그 레포 .git 디렉터리 아래는 허용) — 심링크·상대경로는 실제 경로로 풀어 판정한다
데이터 스크립트에는 meta 선언과 `return <JSON 문자열 리터럴>;` 만 들어간다. 리터럴은 json.dumps(ensure_ascii=True)
라 따옴표·역슬래시·제어문자·U+2028/2029·`${`·백틱이 모두 이스케이프되거나 의미가 없다(큰따옴표 문자열).
"""
import hashlib, json, os, subprocess, sys, tempfile

NAME = 'claude-preflight.classify.wf.js'


def die(msg, rc=1):
    print(f'cls-data-script: {msg} — args 를 만들지 않는다', file=sys.stderr)
    sys.exit(rc)


def git(repo, *a):
    r = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True)
    if r.returncode != 0:
        die(f'git {" ".join(a)} 실패: {r.stderr.strip()[:200]}')
    return r.stdout.strip()


def under(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def main():
    if len(sys.argv) != 5:
        die('usage: cls-data-script.py <repo> <classify.json> <classify-sha256> <dir>', 2)
    repo, src, want, out_dir = sys.argv[1:]
    top = os.path.realpath(git(repo, 'rev-parse', '--show-toplevel'))
    common = os.path.realpath(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    gd = os.path.realpath(git(repo, 'rev-parse', '--absolute-git-dir'))
    if not os.path.isdir(out_dir):
        die(f'데이터 스크립트 폴더가 없다: {out_dir}')
    real_dir = os.path.realpath(out_dir)
    if under(real_dir, top) and not (under(real_dir, gd) or under(real_dir, common)):
        die(f'데이터 스크립트 폴더 {out_dir} 가 대상 레포 작업 트리({top}) 안이다 — 작업 트리 밖(gitdir·scratchpad)을 줘라')
    try:
        data = open(src, 'rb').read()
    except OSError as e:
        die(f'분류 파일을 읽지 못했다: {e}')
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        die(f'분류 파일 sha256({got[:12]})이 classify-sha256({want[:12]})과 다르다 — 다른 분류가 덮어썼다')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as e:
        die(f'분류 파일이 UTF-8 이 아니다: {e}')
    body = ('export const meta = { name: "preflight-classification-data", '
            'description: "classify.sh output carried as one string literal (no agents)" };\n'
            f'return {json.dumps(text, ensure_ascii=True)};\n')
    dest = os.path.join(real_dir, NAME)
    fd, tmp = tempfile.mkstemp(dir=real_dir, prefix='.cls-wf.')
    try:
        with os.fdopen(fd, 'w', encoding='ascii') as f:
            f.write(body)
        os.replace(tmp, dest)
    except OSError as e:
        try: os.unlink(tmp)
        except OSError: pass
        die(f'데이터 스크립트를 쓰지 못했다: {e}')
    print(json.dumps({'classificationScript': dest, 'classificationSha256': want}))


if __name__ == '__main__':
    main()
