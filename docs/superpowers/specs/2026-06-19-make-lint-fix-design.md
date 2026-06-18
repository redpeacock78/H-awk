# make lint 修正 設計書

**作成日**: 2026-06-19
**対象リポジトリ**: hawk
**ステータス**: draft

---

## 概要

`make lint` が `core/http.awk` で常に失敗する問題を修正する。
Makefile の lint ターゲットをフルプログラム lint に変更し、CI の lint ジョブを通過させる。

---

## 根本原因

現在の lint ターゲットは `core/*.awk` を個別にリントする。

```makefile
for f in core/*.awk hawk.awk; do
  HAWK_NO_SERVE=1 gawk --lint -f "$$f" -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
    || (echo "lint FAIL: $$f"; exit 1);
done
```

`core/http.awk` の END ブロック（line 13）で `env::has()` を呼ぶ。
`env::has` は `core/env.awk` に定義されており、単体ファイル lint では未定義 → 致命的エラー（exit 2）。

```awk
END {
  if (!_HAWK_LISTEN_CALLED && !env::has("HAWK_NO_SERVE")) {
    _hawk_serve()
  }
}
```

`-e 'BEGIN{exit 0}'` を指定しても gawk は `exit` 実行時に END ブロックを走らせるため、
`env::has` 呼び出しが発生して fatal となる。

---

## 修正方針

`hawk.awk` は `@include` ディレクティブで全 core ファイルを依存順にロードする。

```awk
# hawk.awk（抜粋）
@include "core/env.awk"    -- line 29: env::has() 定義
...
@include "core/http.awk"   -- line 35: env::has() 使用
```

フルプログラム (`hawk.awk`) を 1 コマンドで lint すれば、依存関係が解決されて fatal エラーは発生しない。

---

## スコープ

### 対象

- `Makefile` の `lint` ターゲット変更（1 箇所のみ）

### 対象外

- `core/http.awk` ソース変更（`\x1e`/`strftime` 拡張警告は `--lint` の警告であり exit code 非 0 にならない。修正不要）
- `core/env.awk` その他 core ファイルの変更
- プラグインファイル（`PLUGIN_FILES`）の lint（既存の lint ターゲットも対象外であり、本修正でも変更なし）

### 前提条件

- `make lint` は repo ルートから実行する（既存動作と同一。gawk の `@include "core/..."` はカレントディレクトリ相対）
- `gawk --lint` の拡張警告（`\x` エスケープ、`strftime`）はすべての gawk バージョンで非 fatal（exit 0）

### デバッグ方法

`>/dev/null 2>&1` により stdout・stderr は通常実行時に抑制される。
CI で `lint FAIL` が出た場合はローカルで以下を実行して診断する:

```bash
HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}'
```

---

## 変更内容

### Makefile: lint ターゲット

**変更前:**

```makefile
lint: ## awk 構文チェック
	@set -e; for f in core/*.awk hawk.awk; do \
	  [ -f "$$f" ] || continue; \
	  HAWK_NO_SERVE=1 gawk --lint -f "$$f" -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	    || (echo "lint FAIL: $$f"; exit 1); \
	done
	@echo "lint OK"
```

**変更後:**

```makefile
lint: ## awk 構文チェック
	@HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	  || (echo "lint FAIL"; exit 1)
	@echo "lint OK"
```

---

## 動作確認

| 確認事項 | 方法 | 期待結果 |
|----------|------|----------|
| `make lint` が通過する | `make lint` | `lint OK`（exit 0） |
| CI lint ジョブが通過する | GitHub Actions PR | lint ジョブ green |

---

## 成功条件

- `make lint` が exit 0 で完了し `lint OK` を出力する
- CI の lint ジョブが失敗しなくなる
- 既存の `make test` に影響しない
