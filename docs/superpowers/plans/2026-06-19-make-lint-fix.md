# make lint 失敗修正 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make lint` が `core/http.awk` の `env::has` 未定義 fatal で exit 2 になる問題を修正し、CI の lint ジョブを通過させる。

**Architecture:** `Makefile` の `lint` ターゲットを per-file ループからフルプログラム lint（`-f hawk.awk` 単体）に変更する。`hawk.awk` は `@include` で全 core ファイルを依存順にロードするため、単体ファイル時の未定義関数 fatal は発生しない。

**Tech Stack:** GNU awk（gawk）、GNU Make

## Global Constraints

- 変更は `Makefile` の `lint` ターゲットのみ。ソースファイル（`.awk`）は変更しない。
- `make lint` は repo ルートから実行する（`@include "core/..."` が cwd 相対のため）。
- `HAWK_NO_SERVE=1` を付けて END ブロックがサーバー起動しないようにする（既存動作と同一）。
- `>/dev/null 2>&1` で stdout・stderr を抑制し、exit code のみで合否を判定する（既存動作と同一）。
- 既存の `make test`（`test-unit`・`test-dsl`・`test-e2e`）の動作に影響を与えない。
- コミットは Conventional Commits 形式、件名 50 文字以内。

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

- [ ] **Step 2: 現在の lint ターゲットが失敗することを確認する**

```bash
make lint
```

期待出力:
```
lint FAIL: core/http.awk
make: *** [lint] Error 1
```

（`core/http.awk` で `致命的: function 'env::has' not defined` が発生して exit 2 になる）

---

- [ ] **Step 3: Makefile の lint ターゲットを変更する**

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
- `hawk.awk` は `@include` で `core/env.awk`（line 29）→ … → `core/http.awk`（line 35）の順にロードするため、`env::has` は `core/http.awk` がロードされる前に定義済みになる。
- `HAWK_NO_SERVE=1` で END ブロックの `_hawk_serve()` 呼び出しを抑制する。

---

- [ ] **Step 4: `make lint` が通過することを確認する**

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

- [ ] **Step 5: `make test` が引き続き通過することを確認する**

```bash
make test
```

期待: テストがすべて通過し、exit 0 で終了する。

---

- [ ] **Step 6: デバッグ手順が機能することを確認する**

`>/dev/null 2>&1` なしで実行し、gawk --lint の警告が見えることを確認する:

```bash
HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}'
```

期待: `\x` エスケープや `strftime` に関する警告が stderr に出るが、exit 0 で終了する。
（これらは lint 警告であり fatal エラーではない）

---

- [ ] **Step 7: コミットして master にマージする**

```bash
git add Makefile
git commit -m "fix(lint): switch to full-program gawk lint via hawk.awk"
git checkout master
git merge --no-ff task/2026-06-19-make-lint-fix
git branch -d task/2026-06-19-make-lint-fix
```

---

## 実装後の確認（スコープ外、オーナーが実施）

PR #1 の CI が lint ジョブで失敗している場合、本修正を master に取り込んだあと PR を rebase するか、PR ブランチに本修正をチェリーピックすることで CI が通過するようになる。
