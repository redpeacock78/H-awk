# make lint 失敗修正 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make lint` が `core/http.awk` の `env::has` 未定義 fatal で exit 2 になる問題を修正し、ローカルおよび CI の lint ジョブを通過させる。CI パスの確認は、本修正を PR ブランチに取り込んだあと CI が green になることで達成する。

**Architecture:** `Makefile` の `lint` ターゲットを per-file ループからフルプログラム lint（`-f hawk.awk` 単体）に変更する。`hawk.awk` は `@include` で全 core ファイルを依存順にロードするため、単体ファイル時の未定義関数 fatal は発生しない。

**Tech Stack:** GNU awk（gawk）、GNU Make

## Global Constraints

- 変更は `Makefile` の `lint` ターゲットのみ。ソースファイル（`.awk`）は変更しない。
- `make lint` は repo ルートから実行する（`@include "core/..."` が cwd 相対のため）。
- `HAWK_NO_SERVE=1` を付けて END ブロックがサーバー起動しないようにする（既存動作と同一）。
- `>/dev/null 2>&1` で stdout・stderr を抑制し、exit code のみで合否を判定する（既存動作と同一）。lint 失敗時の診断はローカルで `HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}'` を直接実行する。
- 既存の `make test`（`test-unit`・`test-dsl`・`test-e2e`）の動作に影響を与えない。
- コミットは Conventional Commits 形式、件名 50 文字以内。
- **lint のカバレッジ範囲の変更:** 修正後の lint は `hawk.awk` エントリポイントからの `@include` グラフ全体を対象とする。`core/*.awk` の個別 lint（ファイル単体での構文・依存チェック）は本修正でスコープ外になる。これは意図的なトレードオフであり、ファイルをまたぐ依存関係がある設計において standalone lint は成立しないための変更である。

---

## ファイルマップ

| ファイル | 操作 |
|----------|------|
| `Makefile` | 修正：`lint` ターゲットの per-file ループをフルプログラム lint 1 コマンドに置換 |

---

## Task 1: Makefile の lint ターゲットをフルプログラム lint に変更する

**ブランチ:** `task/2026-06-19-make-lint-fix`

**Files:**
- Modify: `Makefile`（`lint` ターゲット、line 53–59）

**Interfaces:**
- Produces: `make lint` が exit 0 で `lint OK` を出力する

---

- [ ] **Step 1: ブランチを作成する**

```bash
git checkout -b task/2026-06-19-make-lint-fix
```

---

- [ ] **Step 2: `hawk.awk` が全 `core/*.awk` を `@include` していることを確認する**

```bash
grep '@include "core/' hawk.awk
```

期待出力（順序は以下のとおり）:

```
@include "core/util.awk"
@include "core/dispatch.awk"
@include "core/libs.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/hawk.awk"
@include "core/env.awk"
@include "core/safe.awk"
@include "core/router.awk"
@include "core/ctx.awk"
@include "core/plugin.awk"
@include "core/http.awk"
```

`core/` ディレクトリの `.awk` ファイル一覧との差異を確認する:

```bash
ls core/*.awk
```

上記のリストと一致しない core ファイルがある場合、そのファイルは `hawk.awk` の include グラフ外である（意図的に除外されているか、新規追加された可能性がある）。一致しない場合は作業を止めてオーナーに確認する。

---

- [ ] **Step 3: 現在の lint ターゲットが失敗することを確認する**

```bash
make lint
```

期待される **可視出力**（`echo` が出力する行）:
```
lint FAIL: core/http.awk
make: *** [lint] Error 1
```

（`致命的: function 'env::has' not defined` は `2>/dev/null` で抑制されているため端末には表示されないが、exit 2 が発生して上記の echo が出力される）

---

- [ ] **Step 4: Makefile の lint ターゲットを変更する**

変更前（`Makefile` line 53–59）:

```makefile
lint: ## awk 構文チェック
	@set -e; for f in core/*.awk hawk.awk; do \
	  [ -f "$$f" ] || continue; \
	  HAWK_NO_SERVE=1 gawk --lint -f "$$f" -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	    || (echo "lint FAIL: $$f"; exit 1); \
	done
	@echo "lint OK"
```

変更後:

```makefile
lint: ## awk 構文チェック
	@HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	  || (echo "lint FAIL"; exit 1)
	@echo "lint OK"
```

変更のポイント:
- per-file ループを廃止し、`hawk.awk` を1回 lint するだけにする。
- `hawk.awk` は `@include` で `core/env.awk`（Step 2 で確認済み）→ … → `core/http.awk` の順にロードするため、`env::has` は `core/http.awk` がロードされる前に定義済みになる。
- `HAWK_NO_SERVE=1` で END ブロックの `_hawk_serve()` 呼び出しを抑制する。

---

- [ ] **Step 5: `make lint` が通過することを確認する**

```bash
make lint
```

期待出力:
```
lint OK
```

終了コードが 0 であることを確認:

```bash
echo $?
```

期待: `0`

---

- [ ] **Step 6: `make test` が引き続き通過することを確認する**

```bash
make test
```

期待: テストがすべて通過し、exit 0 で終了する。

---

- [ ] **Step 7: デバッグ手順が機能することを確認する**

`>/dev/null 2>&1` なしで実行し、gawk --lint の警告が見えることを確認する:

```bash
HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}'
```

期待: `\x` エスケープや `strftime` に関する警告が stderr に出るが、exit 0 で終了する。
（これらは lint 警告であり fatal エラーではない）

---

- [ ] **Step 8: コミットして master にマージする**

```bash
git add Makefile
git commit -m "fix(lint): switch to full-program gawk lint via hawk.awk"
git checkout master
git merge --no-ff task/2026-06-19-make-lint-fix
git branch -d task/2026-06-19-make-lint-fix
```

---

## 実装後の確認

本修正を master にマージしたあと、PR #1 の CI lint ジョブが通過することを確認する。

```bash
# PR #1 ブランチに本修正を取り込む
git checkout feat/github-actions-cicd
git rebase master
git push --force-with-lease
```

GitHub Actions の CI が再実行され、lint ジョブが green になれば完了。
