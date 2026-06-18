# GitHub Actions CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PR ごとに lint・クロスプラットフォームテスト・カバレッジを自動実行する GitHub Actions CI を導入する。

**Architecture:** 3 ジョブ構成（lint → test matrix → coverage）。lint が通過した PR のみ test が走り、coverage は情報提供目的で merge をブロックしない。AWK カバレッジは `gawk --profile` 出力を LCOV に変換して Codecov にアップロードする。

**Tech Stack:** GitHub Actions, ShellCheck, gawk, kcov, Codecov

## Global Constraints

- gawk は既存プロジェクトの必須依存。追加インストールは `apt-get`/`brew` で行う
- `GAWK_OPTS ?=` はデフォルト空。既存のすべての make ターゲットに影響を与えてはならない
- coverage ジョブは `continue-on-error: true`。失敗しても PR マージをブロックしない
- Codecov アップロードは fork PR と `CODECOV_TOKEN` 未設定時にスキップする
- e2e テスト失敗時は `tests/e2e/server.log` を artifact として保存する（`if: failure()`）
- `release-libs.yml` は変更しない
- 各 Task は独立ブランチ `task/YYYY-MM-DD-<slug>` で実装し、master にマージしてから次の Task に進む
- コミットは Conventional Commits 形式、件名 ≤50 文字

---

## File Map

| ファイル | 操作 | 責務 |
|----------|------|------|
| `Makefile` | 修正（2 箇所） | `GAWK_OPTS ?=` 変数追加、test-unit の gawk 呼び出しに `$(GAWK_OPTS)` 注入 |
| `scripts/awk-profile-to-lcov.sh` | 新規作成 | `gawk --profile` 出力を LCOV 形式に変換 |
| `scripts/tests/sample.prof` | 新規作成 | 変換スクリプトのテストフィクスチャ（入力） |
| `scripts/tests/expected.info` | 新規作成 | 変換スクリプトのテストフィクスチャ（期待出力） |
| `.github/workflows/ci.yml` | 新規作成 | PR + master push CI（lint/test/coverage） |

---

## Task 1: Makefile に GAWK_OPTS を追加する

**ブランチ:** `task/2026-06-18-makefile-gawk-opts`

**Files:**
- Modify: `Makefile:6`（変数定義ブロックに追加）
- Modify: `Makefile:40`（gawk 呼び出し行に `$(GAWK_OPTS)` 追加）

**Interfaces:**
- Produces: `make test-unit GAWK_OPTS="--profile=<path>"` でプロファイルを出力できる

---

- [ ] **Step 1: ブランチ作成**

```bash
git checkout -b task/2026-06-18-makefile-gawk-opts
```

- [ ] **Step 2: 現状確認 — gawk 呼び出し行を特定する**

```bash
grep -n "gawk -b" Makefile
```

期待出力: `40:	HAWK_NO_SERVE=1 gawk -b $$libs_args $$libs_vars -f hawk.awk ...`

- [ ] **Step 3: `GAWK_OPTS ?=` を変数ブロックに追加する**

`Makefile` の6行目付近（`STRICT  ?=` の直後）に追加する。

変更前:
```makefile
STRICT  ?=
```

変更後:
```makefile
STRICT  ?=
GAWK_OPTS ?=
```

- [ ] **Step 4: `test-unit` の gawk 呼び出しに `$(GAWK_OPTS)` を追加する**

変更前（Makefile 40行目）:
```makefile
	HAWK_NO_SERVE=1 gawk -b $$libs_args $$libs_vars -f hawk.awk $(PLUGIN_FILES) -f tests/unit/run.awk 2>"$$_u_log"; \
```

変更後:
```makefile
	HAWK_NO_SERVE=1 gawk -b $(GAWK_OPTS) $$libs_args $$libs_vars -f hawk.awk $(PLUGIN_FILES) -f tests/unit/run.awk 2>"$$_u_log"; \
```

- [ ] **Step 5: GAWK_OPTS 未指定で make test-unit が通ることを確認する**

```bash
make test-unit
```

期待: テストがすべて通過（既存の動作と同じ）

- [ ] **Step 6: GAWK_OPTS 指定でプロファイルが出力されることを確認する**

```bash
make test-unit GAWK_OPTS="--profile=/tmp/hawk-test.prof"
ls -la /tmp/hawk-test.prof
head -20 /tmp/hawk-test.prof
```

期待: `/tmp/hawk-test.prof` が生成され、`# gawk profile` で始まる

- [ ] **Step 7: コミットしてマージする**

```bash
git add Makefile
git commit -m "build: add GAWK_OPTS to test-unit for coverage"
git checkout master
git merge --no-ff task/2026-06-18-makefile-gawk-opts
git branch -d task/2026-06-18-makefile-gawk-opts
```

---

## Task 2: AWK プロファイル → LCOV 変換スクリプト

**ブランチ:** `task/2026-06-18-awk-profile-to-lcov`

**Files:**
- Create: `scripts/awk-profile-to-lcov.sh`
- Create: `scripts/tests/sample.prof`（フィクスチャ入力）
- Create: `scripts/tests/expected.info`（フィクスチャ期待出力）

**Interfaces:**
- Consumes: Task 1 の `make test-unit GAWK_OPTS="--profile=<path>"` が出力するプロファイル
- Produces: `scripts/awk-profile-to-lcov.sh <prof> [sf]` → stdout に LCOV 形式

---

- [ ] **Step 1: ブランチ作成**

```bash
git checkout -b task/2026-06-18-awk-profile-to-lcov
```

- [ ] **Step 2: フィクスチャ入力 `scripts/tests/sample.prof` を作成する**

`scripts/tests/` ディレクトリを作成し、以下の内容でファイルを作成する。
（タブ文字が重要。各行頭は実際のタブ）

```
	# gawk profile, created Thu Jun 18 21:00:00 2026

	# BEGIN rules

	BEGIN {
	     2  	x = 1
	     2  	print x
	}

	# END rules

	END {
	     1  	print "done"
	}
```

- [ ] **Step 3: フィクスチャ期待出力 `scripts/tests/expected.info` を作成する**

スクリプトを `sample.prof` に適用したときの期待 LCOV 出力。
カウント付き行は6行目・7行目・12行目（プロファイルの連番）。

```
SF:hawk.awk
DA:6,2
DA:7,2
DA:12,1
LF:3
LH:3
end_of_record
```

- [ ] **Step 4: 失敗することを確認する（スクリプト未作成）**

```bash
bash -c 'scripts/awk-profile-to-lcov.sh scripts/tests/sample.prof 2>&1 | diff - scripts/tests/expected.info'
```

期待: `No such file or directory` などのエラーで失敗

- [ ] **Step 5: `scripts/awk-profile-to-lcov.sh` を作成する**

```bash
#!/usr/bin/env bash
# Convert gawk --profile output to LCOV format.
# Usage: scripts/awk-profile-to-lcov.sh <profile.out> [source.awk]
# ponytail: single-file SF: only — gawk profile has no per-file metadata
set -e
PROF="${1:?Usage: $0 <profile.out> [source.awk]}"
SF="${2:-hawk.awk}"

gawk -v sf="$SF" '
BEGIN { print "SF:" sf; lf = 0; lh = 0 }
{
  if (match($0, /^\t[ ]*([0-9]+)\t/, arr)) {
    count = arr[1] + 0
    print "DA:" NR "," count
    lf++
    if (count > 0) lh++
  }
}
END {
  print "LF:" lf
  print "LH:" lh
  print "end_of_record"
}
' "$PROF"
```

```bash
chmod +x scripts/awk-profile-to-lcov.sh
```

- [ ] **Step 6: フィクスチャで diff テストを実行する**

```bash
scripts/awk-profile-to-lcov.sh scripts/tests/sample.prof | diff - scripts/tests/expected.info
```

期待: 差分なし（終了コード 0）

- [ ] **Step 7: 実際のプロファイルで動作確認する**

```bash
make test-unit GAWK_OPTS="--profile=/tmp/hawk.prof"
scripts/awk-profile-to-lcov.sh /tmp/hawk.prof | head -20
```

期待: `SF:hawk.awk` で始まり、`DA:` 行が複数出力される

- [ ] **Step 8: コミットしてマージする**

```bash
git add scripts/awk-profile-to-lcov.sh scripts/tests/sample.prof scripts/tests/expected.info
git commit -m "feat(ci): add awk-profile-to-lcov converter"
git checkout master
git merge --no-ff task/2026-06-18-awk-profile-to-lcov
git branch -d task/2026-06-18-awk-profile-to-lcov
```

---

## Task 3: GitHub Actions ワークフロー `ci.yml`

**ブランチ:** `task/2026-06-18-ci-workflow`

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1 の `make test-unit GAWK_OPTS=...`、Task 2 の `scripts/awk-profile-to-lcov.sh`

---

- [ ] **Step 1: ブランチ作成**

```bash
git checkout -b task/2026-06-18-ci-workflow
```

- [ ] **Step 2: `.github/workflows/ci.yml` を作成する**

```yaml
# SPDX-License-Identifier: MIT
name: CI

on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [master]

jobs:
  lint:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: sudo apt-get update && sudo apt-get install -y shellcheck gawk
      - name: ShellCheck
        run: |
          find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck
          for f in bin/hawk libexec/hawk libexec/hawk-check libexec/hawk-emit \
                   libexec/hawk-help libexec/hawk-libs libexec/hawk-serve; do
            [ -f "$f" ] && shellcheck "$f"
          done
      - name: gawk lint
        run: make lint

  test:
    needs: lint
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: Install gawk (ubuntu)
        if: matrix.os == 'ubuntu-latest'
        run: sudo apt-get update && sudo apt-get install -y gawk curl
      - name: Install gawk (macos)
        if: matrix.os == 'macos-latest'
        run: brew install gawk
      - name: Run tests
        run: make test
      - name: Upload e2e server log
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: e2e-server-log-${{ matrix.os }}
          path: tests/e2e/server.log

  coverage:
    needs: test
    runs-on: ubuntu-latest
    continue-on-error: true
    permissions:
      contents: read
      pull-requests: write
    env:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: sudo apt-get update && sudo apt-get install -y gawk kcov
      - name: AWK coverage
        run: |
          mkdir -p coverage/awk
          make test-unit GAWK_OPTS="--profile=coverage/awk/awk.prof"
          scripts/awk-profile-to-lcov.sh coverage/awk/awk.prof > coverage/awk/awk.info
      - name: Shell coverage
        run: |
          mkdir -p coverage/shell
          kcov --include-path=bin,libexec,scripts coverage/shell make test
      - name: Upload to Codecov
        uses: codecov/codecov-action@v4
        if: |
          env.CODECOV_TOKEN != '' &&
          (github.event_name != 'pull_request' ||
           github.event.pull_request.head.repo.full_name == github.repository)
        with:
          token: ${{ env.CODECOV_TOKEN }}
          files: coverage/awk/awk.info
          directory: coverage/shell
```

- [ ] **Step 3: YAML 構文を検証する**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"
```

期待: `YAML OK`

- [ ] **Step 4: 既存の `release-libs.yml` と整合性を確認する**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-libs.yml')); print('release-libs OK')"
diff <(grep -E "^(on:|  push:|    tags:|    branches:)" .github/workflows/ci.yml) \
     <(grep -E "^(on:|  push:|    tags:|    branches:)" .github/workflows/release-libs.yml) || true
```

期待: ci.yml は `branches: [master]`、release-libs.yml は `tags: ['v*']` でトリガーが独立していることを確認

- [ ] **Step 5: ワークフローファイル一覧を確認する**

```bash
ls .github/workflows/
```

期待: `ci.yml  release-libs.yml`

- [ ] **Step 6: コミットしてマージする**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add PR CI workflow (lint/test/coverage)"
git checkout master
git merge --no-ff task/2026-06-18-ci-workflow
git branch -d task/2026-06-18-ci-workflow
```

---

## 実装後の手動設定（スコープ外、オーナーが実施）

1. **Codecov**: `https://codecov.io` でリポジトリを有効化し、`CODECOV_TOKEN` を GitHub Secrets に登録
2. **Branch protection**: Settings → Branches → master → Required status checks に `lint`・`test (ubuntu-latest)`・`test (macos-latest)` を追加（`coverage` は含めない）
