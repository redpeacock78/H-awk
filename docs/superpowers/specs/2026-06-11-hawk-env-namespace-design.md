# hawk env:: Namespace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `env::` namespace を新規追加し、`ENVIRON` 配列への薄いラッパーとして `get/set/del/has` を提供する。アプリコードが環境変数を一貫した API 経由で読み書きできるようにする。

**Architecture:** `core/env.awk`（`@namespace "env"`）を新規追加し、`hawk.awk` のロード順に挿入する。4関数はすべて gawk 組み込みの `ENVIRON` 配列を直接操作する薄いラッパー。独立ファイルで単独テスト可能。

**Tech Stack:** gawk 5.0+（`@namespace` 必須）、参考 API: Deno.env。

---

## ファイル構成

- 新規: `core/env.awk` — `@namespace "env"` の本体（get/set/del/has）
- 変更: `hawk.awk` — `@include "core/env.awk"` を追加
- 新規: `tests/unit/test_env.awk` — env:: のユニットテスト（7関数）
- 変更: `tests/unit/run.awk` — test_env.awk を追加

---

## API リファレンス

```awk
env::get("KEY")          # ENVIRON["KEY"] を返す。未定義時 "" を返す
env::set("KEY", "val")   # ENVIRON["KEY"] = "val"
env::del("KEY")          # delete ENVIRON["KEY"]
env::has("KEY")          # "KEY" in ENVIRON → 1 または 0
```

### 命名注意

- 関数名は `del`（`delete` ではない）。`delete` は gawk キーワード → 関数名不可。`del` は非キーワード → `env::del` として定義可能。
- `hawk::del` と同じ命名戦略。

### ENVIRON 書き換えの挙動

- `env::set` / `env::del` は gawk プロセス内の `ENVIRON` を即時変更 → 同プロセス内の後続 `env::get` に反映される。
- `system()` / `popen()` 経由の子プロセスには伝播しない（gawk 仕様）。

---

## 内部実装

```awk
# core/env.awk
@namespace "env"

function get(key)      { return ENVIRON[key] }
function set(key, val) { ENVIRON[key] = val }
function del(key)      { delete ENVIRON[key] }
function has(key)      { return (key in ENVIRON) }

@namespace "awk"
```

---

## ロード順（hawk.awk）

```awk
# 変更後（env.awk を任意の位置に追加）
@include "core/env.awk"
```

hawk:: や ctx:: と同列に並ぶ独立モジュール。

---

## テスト設計

`tests/unit/test_env.awk` でカバーする項目（関数名: `test_env_*`）:

- `test_env_get_existing`  — ENVIRON に存在するキー → 正しい値返却
- `test_env_get_missing`   — 存在しないキー → `""` 返却
- `test_env_set`           — `env::set` 後 `env::get` で即反映
- `test_env_del`           — `env::del` 後 `env::has` → `0`
- `test_env_has_existing`  — 存在するキー → `1`
- `test_env_has_missing`   — 存在しないキー → `0`
- `test_env_set_overwrite` — 既存キーを上書き → `env::get` で新値

### テスト隔離

各テストで使うキーは `__TEST_ENV_*` プレフィックス。他の環境変数と衝突しない。`env::del` で後始末。
