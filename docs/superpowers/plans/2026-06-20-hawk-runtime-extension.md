# H-awk ランタイム拡張実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** H-awk に cache facade、Bash supervisor、内部メッセージ/proc layer、Zig cache backend を追加し、Zig が揃うと強くなるグレースフルデグラデーション構造を実現する。

**Architecture:** `core/cache.awk` がバックエンド非依存の公開 API を提供し、`HAWK_CACHE_BACKEND` で zig/file/memory/off を切り替える。`core/message.awk` / `core/objectspace.awk` / `core/mailbox.awk` / `core/proc.awk` が Smalltalk 的メッセージングを内部 ABI として実装するが、ユーザー向け DSL には露出しない。`libexec/hawk-supervise` が `wait -n` ループで複数 worker/actor を管理する。

**Tech Stack:** gawk 5.1+（`@namespace` 必須）、Bash 4.3+（`wait -n` 必須）、Zig 0.14+（optional）、FIFO（mkfifo）

## Global Constraints

- gawk 5.1+ 必須（`@namespace` 使用のため）
- Bash 4.3+ 必須（`wait -n` 使用のため）
- Zig 0.14+（`libs/cache` ビルドに必要。不在時は既存機能に影響しない）
- AWK 名前空間規則: `@namespace "X"` → 公開関数名 `x::fn()` 形式で呼び出し可能
- 新規コアモジュールはすべて `hawk.awk` に `@include` する（常時ロード）
- 各タスク完了後に `make test-unit` が通ること
- `selector` / `ObjectSpace` / `mailbox` はコア内部に隠蔽する
- `HAWK_CACHE_BACKEND`: auto / zig / file / memory / off
- `HAWK_RUN_DIR`: supervisor が `mktemp -d "${TMPDIR:-/tmp}/hawk-run-$(id -u)-XXXXXX"` で作成
- `HAWK_RESTART_MAX` デフォルト 5、`HAWK_RESTART_WINDOW` デフォルト 10 秒
- file backend の TSV 形式: `key_hash<TAB>expires_at<TAB>escaped_key<TAB>escaped_value`
- escape 規則: `\` → `\\`、`\t` → `\t`（2文字）、`\n` → `\n`（2文字）、`\r` → `\r`（2文字）
- message エンコード: フィールド区切り `\x1e`（Record Separator）、args 区切り `\x1f`（Unit Separator）

---

## ファイル構成

新規作成:

- `core/cache.awk` — cache facade + memory / file / Zig backend、統計、remember ヘルパー
- `core/message.awk` — メッセージエンベロープ生成・encode/decode・ref 生成
- `core/objectspace.awk` — logical name → proc ID 解決、registry、cast/call 委譲
- `core/mailbox.awk` — FIFO transport、send / call（タイムアウト付き）/ ensure
- `core/proc.awk` — proc facade（self / register / whereis / cast / call）
- `libexec/hawk-supervise` — wait -n supervisor、restart intensity、run dir セットアップ
- `libexec/hawk-worker` — supervisor 配下の worker 薄いラッパー
- `libs/cache/build.zig` — Zig ライブラリビルド定義
- `libs/cache/src/root.zig` — gawk extension エントリポイント
- `libs/cache/src/cache.zig` — 固定長スロットハッシュテーブル
- `libs/cache/tests/cache_test.zig` — Zig ユニットテスト
- `tests/unit/test_cache.awk` — cache unit tests
- `tests/unit/test_message.awk` — message unit tests
- `tests/unit/test_objectspace.awk` — objectspace unit tests
- `tests/unit/test_proc.awk` — proc unit tests
- `tests/e2e/supervisor_restart.sh` — supervisor crash-restart E2E
- `tests/e2e/cache_file_backend.sh` — file backend クロスプロセス E2E
- `tests/e2e/proc_mailbox.sh` — cast 送受信 E2E

変更:

- `core/libs.awk` — `LIBS_LOADED["cache"] = 1` 追加
- `hawk.awk` — 新規コアモジュール 5 本の `@include` 追加
- `libexec/hawk-serve` — `--workers N`（N > 1）時の hawk-supervise 委譲
- `tests/unit/run.awk` — 新規テスト関数の呼び出し追加

---

## Task 1: cache facade と memory backend

**Files:**
- Create: `core/cache.awk`
- Modify: `core/libs.awk`
- Modify: `hawk.awk`
- Create: `tests/unit/test_cache.awk`
- Modify: `tests/unit/run.awk`

**Interfaces:**
- Consumes: `systime()`（gawk 組み込み）、`ENVIRON` 配列、`LIBS_LOADED[]`
- Produces:
  - `cache::get(key)` → 文字列（miss は空文字列）
  - `cache::set(key, value, ttl_sec)` → なし
  - `cache::del(key)` → なし
  - `cache::has(key)` → 0/1
  - `cache::found()` → 0/1（直前の get のヒット状態）
  - `cache::last_error()` → エラー文字列
  - `cache::backend()` → バックエンド名文字列
  - `cache::remember(key, ttl_sec, fn)` → 文字列
  - `cache::stats()` → 統計文字列
  - `cache::_reset()` → テスト用状態リセット

- [ ] **Step 1: テストを書く**

`tests/unit/test_cache.awk` を作成する。

```awk
# SPDX-License-Identifier: MIT
# tests/unit/test_cache.awk

function test_cache_memory_set_get(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  cache::set("k1", "hello", 60)
  assert_eq(cache::get("k1"), "hello", "cache: memory set/get")
  assert_eq(cache::found(), 1, "cache: found=1 after hit")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_memory_miss(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  assert_eq(cache::get("no_such_key"), "", "cache: miss returns empty")
  assert_eq(cache::found(), 0, "cache: found=0 after miss")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_memory_ttl_expired(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  cache::set("ttl_key", "v", 60)
  cache::_mem_expires["ttl_key"] = systime() - 1
  assert_eq(cache::get("ttl_key"), "", "cache: expired TTL is miss")
  assert_eq(cache::found(), 0, "cache: found=0 on TTL miss")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_has(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  cache::set("has_key", "y", 60)
  assert_eq(cache::has("has_key"), 1, "cache: has existing")
  assert_eq(cache::has("no_has"),  0, "cache: has missing")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_del(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  cache::set("del_k", "v", 60)
  cache::del("del_k")
  assert_eq(cache::has("del_k"), 0, "cache: del then has=0")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_off_mode(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  cache::_reset()
  cache::set("off_k", "v", 60)
  assert_eq(cache::get("off_k"), "", "cache: off get=empty")
  assert_eq(cache::found(), 0,      "cache: off found=0")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_backend_memory(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
  cache::_reset()
  assert_eq(cache::backend(), "memory", "cache: backend()=memory")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}

function test_cache_backend_off(    saved) {
  saved = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  cache::_reset()
  assert_eq(cache::backend(), "off", "cache: backend()=off")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
HAWK_NO_SERVE=1 gawk -b -f hawk.awk -f tests/unit/run.awk 2>&1 | head -5
```

期待: `gawk: fatal: attempt to use scalar CACHE as an array` などのエラー（`cache::get` 未定義）

- [ ] **Step 3: `core/cache.awk` を実装する**

```awk
# SPDX-License-Identifier: MIT
# core/cache.awk -- cache facade

@namespace "cache"

BEGIN {
  _BACKEND    = ""
  _FOUND      = 0
  _LAST_ERROR = ""
  _STATS_HIT  = 0
  _STATS_MISS = 0
  _STATS_SET  = 0
}

function get(key,    b) {
  _FOUND = 0
  b = _detect_backend()
  if (b == "off")    return ""
  if (b == "memory") return _get_memory(key)
  _STATS_MISS++
  return ""
}

function set(key, value, ttl_sec,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "memory") { _set_memory(key, value, ttl_sec); return }
}

function del(key,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "memory") { _del_memory(key); return }
}

function has(key) {
  get(key)
  return _FOUND
}

function found()      { return _FOUND }
function last_error() { return _LAST_ERROR }
function backend()    { return _detect_backend() }

function remember(key, ttl_sec, fn,    v) {
  v = get(key)
  if (_FOUND) return v
  v = @fn()
  set(key, v, ttl_sec)
  return v
}

function stats() {
  return "backend=" _BACKEND " hit=" _STATS_HIT " miss=" _STATS_MISS " set=" _STATS_SET
}

function _reset(    k) {
  _BACKEND = ""; _FOUND = 0; _LAST_ERROR = ""
  _STATS_HIT = 0; _STATS_MISS = 0; _STATS_SET = 0
  for (k in _mem_value)   delete _mem_value[k]
  for (k in _mem_expires) delete _mem_expires[k]
}

function _detect_backend(    b) {
  if (_BACKEND != "") return _BACKEND
  b = ENVIRON["HAWK_CACHE_BACKEND"]
  if (b == "")       b = "memory"
  if (b == "auto")   b = "memory"  # Task 3 で完成
  _BACKEND = b
  return _BACKEND
}

function _get_memory(key,    now, exp) {
  if (!(key in _mem_value)) { _STATS_MISS++; return "" }
  now = systime()
  exp = _mem_expires[key]
  if (exp > 0 && now >= exp) {
    delete _mem_value[key]
    delete _mem_expires[key]
    _STATS_MISS++
    return ""
  }
  _FOUND = 1
  _STATS_HIT++
  return _mem_value[key]
}

function _set_memory(key, value, ttl_sec) {
  _mem_value[key]   = value
  _mem_expires[key] = (ttl_sec > 0) ? systime() + ttl_sec : 0
  _STATS_SET++
}

function _del_memory(key) {
  delete _mem_value[key]
  delete _mem_expires[key]
}

@namespace "awk"
```

- [ ] **Step 4: `core/libs.awk` に `HAWK_LIBS_cache` を追加する**

`core/libs.awk` の BEGIN ブロック末尾に以下を追加する。

```awk
  if (HAWK_LIBS_cache)     LIBS_LOADED["cache"]     = 1
```

- [ ] **Step 5: `hawk.awk` に `@include` を追加する**

`core/plugin.awk` の `@include` の直後、`core/http.awk` の直前に追加する。

```awk
@include "core/cache.awk"
```

最終的な hawk.awk の末尾部分:

```awk
@include "core/ctx.awk"
@include "core/plugin.awk"
@include "core/cache.awk"
@include "core/http.awk"
```

- [ ] **Step 6: `tests/unit/run.awk` に呼び出しを追加する**

`test_plugin_missing_config()` の直後に以下を追加する。

```awk
  test_cache_memory_set_get()
  test_cache_memory_miss()
  test_cache_memory_ttl_expired()
  test_cache_has()
  test_cache_del()
  test_cache_off_mode()
  test_cache_backend_memory()
  test_cache_backend_off()
```

末尾の `@include` 群に追加する。

```awk
@include "tests/unit/test_cache.awk"
```

- [ ] **Step 7: テストが通ることを確認する**

```bash
make test-unit
```

期待: `N passed, 0 failed, M skipped`（N は既存 + 8 の合計）

- [ ] **Step 8: コミットする**

```bash
git add core/cache.awk core/libs.awk hawk.awk tests/unit/test_cache.awk tests/unit/run.awk
git commit -m "feat(cache): add cache facade with memory backend"
```

---

## Task 2: file backend

**Files:**
- Modify: `core/cache.awk`（escape/unescape、key_hash、lock、_get_file、_set_file、_del_file、_detect_backend 更新）

**Interfaces:**
- Consumes: `HAWK_RUN_DIR` env var、`PROCINFO["pid"]`、`mkdir` / `mv` / `rm` / `kill` システムコール
- Produces: `cache::_get_file(key)`、`cache::_set_file(key, value, ttl_sec)`、`cache::_del_file(key)`
- File format: `$HAWK_RUN_DIR/cache/cache.tsv`、各行 `hash\texpires_at\tescaped_key\tescaped_value`
- Lock dir: `$HAWK_RUN_DIR/cache/cache.lock.d`

- [ ] **Step 1: テストを書く**

`tests/unit/test_cache.awk` に以下の関数を追加する。

```awk
function test_cache_file_set_get(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_test_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("fk1", "world", 60)
  assert_eq(cache::get("fk1"), "world", "cache/file: set/get")
  assert_eq(cache::found(), 1, "cache/file: found=1")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_tab_newline(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_file2_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("tab_key", "line1\nline2\ttab", 60)
  assert_eq(cache::get("tab_key"), "line1\nline2\ttab", "cache/file: tab/newline round-trip")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_ttl_expired(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_file3_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  cache::set("exp_k", "v", 1)
  # Force expire by rewriting tsv with past timestamp
  cache::_mem_expires["exp_k"] = 0  # not used in file backend, use system time trick instead
  # Write a TSV row with expires_at in the past manually
  cmd = "echo '0\t" (systime() - 10) "\texp_k\tv' > " dir "/cache/cache.tsv"
  system(cmd)
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  assert_eq(cache::get("exp_k"), "", "cache/file: expired TTL is miss")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_file_escape_unescape() {
  assert_eq(cache::_escape("a\tb"), "a\\tb",   "cache: escape tab")
  assert_eq(cache::_escape("a\nb"), "a\\nb",   "cache: escape newline")
  assert_eq(cache::_escape("a\\b"), "a\\\\b",  "cache: escape backslash")
  assert_eq(cache::_unescape("a\\tb"),  "a\tb",  "cache: unescape tab")
  assert_eq(cache::_unescape("a\\nb"),  "a\nb",  "cache: unescape newline")
  assert_eq(cache::_unescape("a\\\\b"), "a\\b",  "cache: unescape backslash")
}
```

`tests/unit/run.awk` の cache テスト群に追加する（`test_cache_backend_off()` 呼び出しの後）。

```awk
  test_cache_file_set_get()
  test_cache_file_tab_newline()
  test_cache_file_ttl_expired()
  test_cache_file_escape_unescape()
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
make test-unit 2>&1 | grep -E 'FAIL|failed'
```

期待: `test_cache_file_set_get` および escape 系テストが FAIL

- [ ] **Step 3: file backend 関数を `core/cache.awk` に追加する**

`@namespace "awk"` の直前（`_del_memory` の後）に以下を追加する。

```awk
# escape / unescape
function _escape(v,    s) {
  s = v
  gsub(/\\/, "\\\\", s)
  gsub(/\t/, "\\t",  s)
  gsub(/\n/, "\\n",  s)
  gsub(/\r/, "\\r",  s)
  return s
}

function _unescape(v,    out, i, n, c, nc) {
  out = ""; n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      nc = substr(v, i + 1, 1); i++
      if      (nc == "\\") out = out "\\"
      else if (nc == "t")  out = out "\t"
      else if (nc == "n")  out = out "\n"
      else if (nc == "r")  out = out "\r"
      else                 out = out nc
    } else {
      out = out c
    }
  }
  return out
}

# simple djb2-like hash（collision 後に full key 照合する）
function _key_hash(key,    h, i, s) {
  h = 5381; s = key
  for (i = 1; i <= length(s); i++)
    h = (h * 33 + index(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", substr(s, i, 1)) + 32) % 1000003
  return sprintf("%d", h)
}

# file backend lock（最大 1 秒リトライ）
function _lock_acquire(lockdir,    owner_file, pid, i, r) {
  owner_file = lockdir "/owner_pid"
  for (i = 0; i < 20; i++) {
    if (system("mkdir \"" lockdir "\" 2>/dev/null") == 0) {
      print PROCINFO["pid"] > owner_file
      close(owner_file)
      return 1
    }
    # stale check
    if ((getline pid < owner_file) > 0) {
      close(owner_file)
      if (system("kill -0 " pid " 2>/dev/null") != 0) {
        system("rm -rf \"" lockdir "\"")
        continue
      }
    } else { close(owner_file) }
    system("sleep 0.05")
  }
  return 0
}

function _lock_release(lockdir) {
  system("rm -rf \"" lockdir "\"")
}

function _file_path(    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  return rd "/cache/cache.tsv"
}

function _lock_path(    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  return rd "/cache/cache.lock.d"
}

function _get_file(key,    fpath, line, parts, n, kh, now, exp) {
  _FOUND = 0
  fpath = _file_path()
  kh    = _key_hash(key)
  now   = systime()
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] != kh) continue
    if (_unescape(parts[3]) != key) continue
    exp = parts[2] + 0
    if (exp > 0 && now >= exp) continue
    close(fpath)
    _FOUND = 1; _STATS_HIT++
    return _unescape(parts[4])
  }
  close(fpath)
  _STATS_MISS++
  return ""
}

function _set_file(key, value, ttl_sec,    fpath, lockdir, tmp, kh, ek, ev, exp, now, line, parts, n, out) {
  fpath   = _file_path()
  lockdir = _lock_path()
  tmp     = fpath "." PROCINFO["pid"] ".tmp"
  kh      = _key_hash(key)
  ek      = _escape(key)
  ev      = _escape(value)
  exp     = (ttl_sec > 0) ? systime() + ttl_sec : 0
  now     = systime()

  if (!_lock_acquire(lockdir)) { _LAST_ERROR = "CacheLockTimeout"; return }

  out = ""
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] == kh && _unescape(parts[3]) == key) continue
    if ((parts[2] + 0) > 0 && now >= (parts[2] + 0)) continue
    out = out line "\n"
  }
  close(fpath)
  out = out kh "\t" exp "\t" ek "\t" ev "\n"
  printf "%s", out > tmp; close(tmp)
  system("mv \"" tmp "\" \"" fpath "\"")
  _lock_release(lockdir)
  _STATS_SET++
}

function _del_file(key,    fpath, lockdir, tmp, kh, now, line, parts, n, out) {
  fpath   = _file_path()
  lockdir = _lock_path()
  tmp     = fpath "." PROCINFO["pid"] ".tmp"
  kh      = _key_hash(key)
  now     = systime()

  if (!_lock_acquire(lockdir)) { _LAST_ERROR = "CacheLockTimeout"; return }

  out = ""
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] == kh && _unescape(parts[3]) == key) continue
    if ((parts[2] + 0) > 0 && now >= (parts[2] + 0)) continue
    out = out line "\n"
  }
  close(fpath)
  printf "%s", out > tmp; close(tmp)
  system("mv \"" tmp "\" \"" fpath "\"")
  _lock_release(lockdir)
}
```

`get` / `set` / `del` 関数に file 分岐を追加する（`_get_memory` 呼び出しと並列に）。

```awk
function get(key,    b) {
  _FOUND = 0
  b = _detect_backend()
  if (b == "off")    return ""
  if (b == "file")   return _get_file(key)
  if (b == "memory") return _get_memory(key)
  _STATS_MISS++
  return ""
}

function set(key, value, ttl_sec,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "file")   { _set_file(key, value, ttl_sec); return }
  if (b == "memory") { _set_memory(key, value, ttl_sec); return }
}

function del(key,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "file")   { _del_file(key); return }
  if (b == "memory") { _del_memory(key); return }
}
```

`_detect_backend` に `file` 分岐を追加する。

```awk
function _detect_backend(    b, rd) {
  if (_BACKEND != "") return _BACKEND
  b = ENVIRON["HAWK_CACHE_BACKEND"]
  if (b == "") b = "memory"
  if (b == "auto") b = "memory"  # Task 3 で完成
  if (b == "file") {
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd == "") { _LAST_ERROR = "HAWK_RUN_DIR not set for file backend"; b = "memory" }
  }
  _BACKEND = b
  return _BACKEND
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
make test-unit
```

期待: 新規 file テストを含むすべてが PASS（CI=1 の場合は SKIP）

- [ ] **Step 5: コミットする**

```bash
git add core/cache.awk tests/unit/test_cache.awk tests/unit/run.awk
git commit -m "feat(cache): add file backend with escape/lock/atomic-write"
```

---

## Task 3: backend 自動検出と Zig 候補登録

**Files:**
- Modify: `core/cache.awk`（`_detect_backend` を完成させる、Zig stub を追加）
- Modify: `tests/unit/test_cache.awk`（auto / zig fallback テストを追加）

**Interfaces:**
- Consumes: `LIBS_LOADED["cache"]`（Zig 存在確認）、`HAWK_RUN_DIR` への書き込み可否
- Produces: `auto` 時の zig → file → memory フォールバック、`zig` 明示時に Zig 不在でエラー

- [ ] **Step 1: テストを書く**

`tests/unit/test_cache.awk` に追加する。

```awk
function test_cache_auto_no_zig_no_dir(    saved_be, saved_dir) {
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "auto"
  ENVIRON["HAWK_RUN_DIR"] = ""
  cache::_reset()
  # Zig なし + HAWK_RUN_DIR なし → memory にフォールバック
  assert_eq(cache::backend(), "memory", "cache: auto falls back to memory")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}

function test_cache_auto_with_dir(    saved_be, saved_dir, dir) {
  if (ENVIRON["CI"] == "1") { TESTS_SKIPPED++; return }
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_auto_" PROCINFO["pid"]
  system("mkdir -p " dir "/cache")
  ENVIRON["HAWK_CACHE_BACKEND"] = "auto"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()
  # Zig なし + dir あり → file（または zig が存在すれば zig）
  b = cache::backend()
  assert_true((b == "file" || b == "zig"), "cache: auto selects file or zig when dir available")
  system("rm -rf " dir)
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
}
```

`tests/unit/run.awk` の cache 呼び出し群に追加する。

```awk
  test_cache_auto_no_zig_no_dir()
  test_cache_auto_with_dir()
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
make test-unit 2>&1 | grep -E 'FAIL|cache.*auto'
```

- [ ] **Step 3: `_detect_backend` を完成させる**

`core/cache.awk` の `_detect_backend` 関数を以下で置き換える。

```awk
function _detect_backend(    b, rd, test_f, rc) {
  if (_BACKEND != "") return _BACKEND
  b = ENVIRON["HAWK_CACHE_BACKEND"]
  if (b == "") b = "auto"

  if (b == "off")    { _BACKEND = "off";    return _BACKEND }
  if (b == "memory") { _BACKEND = "memory"; return _BACKEND }

  if (b == "zig") {
    if (LIBS_LOADED["cache"]) { _BACKEND = "zig"; return _BACKEND }
    print "[hawk] cache: HAWK_CACHE_BACKEND=zig but libhawk_cache not loaded" > "/dev/stderr"
    exit 1
  }

  if (b == "file") {
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd == "") {
      _LAST_ERROR = "HAWK_RUN_DIR not set"
      print "[hawk] cache: HAWK_CACHE_BACKEND=file requires HAWK_RUN_DIR" > "/dev/stderr"
      exit 1
    }
    _BACKEND = "file"; return _BACKEND
  }

  # auto: zig → file → memory
  if (b == "auto") {
    if (LIBS_LOADED["cache"]) { _BACKEND = "zig"; return _BACKEND }
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd != "") {
      test_f = rd "/cache/.hawk_write_test_" PROCINFO["pid"]
      rc = system("mkdir -p \"" rd "/cache\" && touch \"" test_f "\" 2>/dev/null && rm -f \"" test_f "\"")
      if (rc == 0) { _BACKEND = "file"; return _BACKEND }
    }
    _BACKEND = "memory"; return _BACKEND
  }

  _BACKEND = "memory"; return _BACKEND
}
```

また、Zig backend stub（Task 7 で完成）を追加しておく。

```awk
function _get_zig(key) {
  # Task 7 で hawk_cache_get() に置き換える
  _STATS_MISS++
  return ""
}
function _set_zig(key, value, ttl_sec) { }
function _del_zig(key) { }
```

`get` / `set` / `del` に `zig` 分岐を追加する。

```awk
function get(key,    b) {
  _FOUND = 0
  b = _detect_backend()
  if (b == "off")    return ""
  if (b == "zig")    return _get_zig(key)
  if (b == "file")   return _get_file(key)
  if (b == "memory") return _get_memory(key)
  _STATS_MISS++; return ""
}

function set(key, value, ttl_sec,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "zig")    { _set_zig(key, value, ttl_sec); return }
  if (b == "file")   { _set_file(key, value, ttl_sec); return }
  if (b == "memory") { _set_memory(key, value, ttl_sec); return }
}

function del(key,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "zig")    { _del_zig(key); return }
  if (b == "file")   { _del_file(key); return }
  if (b == "memory") { _del_memory(key); return }
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
make test-unit
```

期待: 新規 auto テストを含むすべてが PASS

- [ ] **Step 5: コミットする**

```bash
git add core/cache.awk tests/unit/test_cache.awk tests/unit/run.awk
git commit -m "feat(cache): complete backend auto-detect with zig/file/memory/off"
```

---

## Task 4: Bash supervisor skeleton

**Files:**
- Create: `libexec/hawk-supervise`
- Create: `libexec/hawk-worker`
- Modify: `libexec/hawk-serve`（`--workers N` 時の委譲）
- Create: `tests/e2e/supervisor_restart.sh`

**Interfaces:**
- Consumes: `$APP_AWK`（desugar 済みパス）、`$EFFECTIVE_WORKERS`、`$HAWK_RUN_DIR`
- Produces:
  - `hawk-supervise` が `HAWK_SUPERVISED=1`、`HAWK_WORKER_ID=N`、`HAWK_PROC_ID=web:N`、`HAWK_RUN_DIR=<path>` をセットして worker を起動
  - `hawk-worker` が `mailbox/$pid.fifo` を作成して gawk プロセスを起動
  - restart intensity: `HAWK_RESTART_WINDOW` 秒以内に `HAWK_RESTART_MAX` 回死んだら全体停止

- [ ] **Step 1: E2E テストを書く**

`tests/e2e/supervisor_restart.sh` を作成する。

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/e2e/supervisor_restart.sh
# supervisor が worker クラッシュを検知して再起動することを確認する
set -e

PORT=18181
PASS=0; FAIL=0

check() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual"   >&2
  fi
}

HAWK_RUN_DIR=$(mktemp -d)
export HAWK_RUN_DIR HAWK_WORKERS=2 PORT

./bin/hawk tests/e2e/fixtures/app.awk > /tmp/hawk_sup_test.log 2>&1 &
SERVER=$!
trap 'kill -TERM "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; rm -rf "$HAWK_RUN_DIR"' EXIT INT TERM

for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  sleep 0.3
done

check "initial request" "hello" "$(curl -s http://127.0.0.1:$PORT/)"

# worker PID を取得して kill する
worker_pid=$(ls "$HAWK_RUN_DIR/pids/" 2>/dev/null | head -1 | sed 's/\.token//')
if [ -n "$worker_pid" ]; then
  kill -KILL "$worker_pid" 2>/dev/null || true
  sleep 1.5
  # supervisor が再起動した後もリクエストが返ること
  check "request after restart" "hello" "$(curl -s http://127.0.0.1:$PORT/)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: no worker pid found in HAWK_RUN_DIR" >&2
fi

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
bash tests/e2e/supervisor_restart.sh 2>&1 | head -5
```

期待: FAIL または `hawk-supervise: No such file or directory` エラー

- [ ] **Step 3: `libexec/hawk-supervise` を作成する**

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# libexec/hawk-supervise -- wait -n ベース supervisor

if [[ "${BASH_VERSINFO[0]}" -lt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ) ]]; then
  echo "[hawk-supervise] bash 4.3+ required (got ${BASH_VERSION})" >&2
  exit 1
fi

set -e

HAWK_LIBEXEC="${HAWK_LIBEXEC:-$(cd "$(dirname "$0")" && pwd)}"
HAWK_LIB="${HAWK_LIB:-$(cd "$(dirname "$0")/.." && pwd)}"
LIBS="${HAWK_LIBEXEC}/hawk-libs"

APP_AWK="${1:?app artifact path required}"
WORKERS="${HAWK_WORKERS:-4}"
RESTART_MAX="${HAWK_RESTART_MAX:-5}"
RESTART_WINDOW="${HAWK_RESTART_WINDOW:-10}"

# --- HAWK_RUN_DIR セットアップ ---
_setup_run_dir() {
  if [[ -z "${HAWK_RUN_DIR:-}" ]]; then
    HAWK_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hawk-run-$(id -u)-XXXXXX")"
  else
    if [[ -L "$HAWK_RUN_DIR" ]]; then
      echo "[hawk-supervise] HAWK_RUN_DIR is a symlink: $HAWK_RUN_DIR" >&2; exit 1
    fi
    [[ -d "$HAWK_RUN_DIR" ]] || mkdir -p "$HAWK_RUN_DIR"
    local owner
    owner="$(stat -c '%u' "$HAWK_RUN_DIR" 2>/dev/null || stat -f '%u' "$HAWK_RUN_DIR")"
    if [[ "$owner" != "$(id -u)" ]]; then
      echo "[hawk-supervise] HAWK_RUN_DIR not owned by current user: $HAWK_RUN_DIR" >&2; exit 1
    fi
  fi
  chmod 0700 "$HAWK_RUN_DIR"
  export HAWK_RUN_DIR
  mkdir -p "$HAWK_RUN_DIR"/{pids,mailbox,reply,log,cache}
  touch "$HAWK_RUN_DIR/registry.tsv"
}

_setup_run_dir

# --- Zig libs ---
eval "$("$LIBS" libs)"
mapfile -t _plugin_paths < <("$LIBS" plugins)
_plugin_args=()
for p in "${_plugin_paths[@]}"; do
  [[ -n "$p" ]] && _plugin_args+=(-f "$p")
done

# --- プロセス管理テーブル ---
# _pid_to_role[pid]=web:N  _pid_to_token[pid]=TOKEN  _restart_count[role]=N  _restart_times[role_N]="ts ts ts ..."
declare -A _pid_to_role _pid_to_token _restart_count
WORKER_PIDS=()

_reg_token() {
  echo "$RANDOM$RANDOM$RANDOM"
}

_worker_start() {
  local id="$1"
  local role="web:$id"
  local token
  token="$(_reg_token)"
  HAWK_SUPERVISED=1 \
  HAWK_RUN_DIR="$HAWK_RUN_DIR" \
  HAWK_WORKER_ID="$id" \
  HAWK_PROC_ID="$role" \
  HAWK_WORKER_TOKEN="$token" \
    "$HAWK_LIBEXEC/hawk-worker" "$APP_AWK" "${_plugin_args[@]}" &
  local pid=$!
  echo "$token" > "$HAWK_RUN_DIR/pids/$pid.token"
  _pid_to_role[$pid]="$role"
  _pid_to_token[$pid]="$token"
  WORKER_PIDS+=("$pid")
}

_check_intensity() {
  local role="$1"
  local now; now="$(date +%s)"
  local window_start=$(( now - RESTART_WINDOW ))
  local count="${_restart_count[$role]:-0}"
  if [[ "$count" -ge "$RESTART_MAX" ]]; then
    echo "[hawk-supervise] restart intensity exceeded for $role, shutting down" >&2
    return 1
  fi
  _restart_count[$role]=$(( count + 1 ))
  return 0
}

shutdown() {
  for pid in "${WORKER_PIDS[@]}"; do
    rm -f "$HAWK_RUN_DIR/pids/$pid.token"
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$HAWK_RUN_DIR"
  exit 0
}
trap shutdown INT TERM

# --- 初期 worker 起動 ---
for (( i=0; i<WORKERS; i++ )); do
  _worker_start "$i"
done

# --- メインループ ---
while [[ ${#WORKER_PIDS[@]} -gt 0 ]]; do
  wait -n 2>/dev/null || true
  new_pids=()
  for pid in "${WORKER_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      new_pids+=("$pid")
      continue
    fi
    status=0; wait "$pid" 2>/dev/null || status=$?
    role="${_pid_to_role[$pid]:-unknown}"
    rm -f "$HAWK_RUN_DIR/pids/$pid.token"
    unset "_pid_to_role[$pid]" "_pid_to_token[$pid]"
    if [[ "$status" -ne 0 ]]; then
      echo "[hawk-supervise] worker $pid ($role) exited $status" >&2
      if ! _check_intensity "$role"; then
        shutdown
      fi
      sleep 1
      # worker ID を role から復元して再起動
      local_id="${role#web:}"
      _worker_start "${local_id:-$pid}"
      new_pids+=("${WORKER_PIDS[-1]}")
    fi
  done
  WORKER_PIDS=("${new_pids[@]}")
done
```

- [ ] **Step 4: `libexec/hawk-worker` を作成する**

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# libexec/hawk-worker -- supervised worker ラッパー

HAWK_LIBEXEC="${HAWK_LIBEXEC:-$(cd "$(dirname "$0")" && pwd)}"
HAWK_LIB="${HAWK_LIB:-$(cd "$(dirname "$0")/.." && pwd)}"
LIBS="${HAWK_LIBEXEC}/hawk-libs"

APP_AWK="${1:?app artifact path required}"
shift
PLUGIN_ARGS=("$@")

# mailbox FIFO を作成する
if [[ -n "${HAWK_RUN_DIR:-}" && -n "${HAWK_PROC_ID:-}" ]]; then
  safe_pid="$BASHPID"
  fifo_path="$HAWK_RUN_DIR/mailbox/$safe_pid.fifo"
  [[ -p "$fifo_path" ]] || mkfifo "$fifo_path"
  export HAWK_WORKER_PID="$safe_pid"
fi

eval "$("$LIBS" libs)"

# shellcheck disable=SC2086
exec gawk -b $LIBS_ARGS $LIBS_VARS -f "$HAWK_LIB/hawk.awk" "${PLUGIN_ARGS[@]}" -f "$APP_AWK"
```

両ファイルに実行権限を付与する。

```bash
chmod +x libexec/hawk-supervise libexec/hawk-worker
```

- [ ] **Step 5: `libexec/hawk-serve` に委譲ロジックを追加する**

`hawk-serve` の `APP_AWK=` 代入の後（desugar 済みパスが確定した後）、worker 起動ループの直前に以下を追加する。

現在の起動ループ（`for (( i=0; i<EFFECTIVE_WORKERS; i++ ));` の前後）を以下で置き換える。

```bash
# --workers N かつ supervisor 利用可能な場合は hawk-supervise に委譲する
if [[ "$EFFECTIVE_WORKERS" -gt 1 && "$HAS_NET" -eq 1 ]]; then
  exec "$HAWK_LIBEXEC/hawk-supervise" "$APP_AWK"
fi

# fallback: 従来の単純な worker 起動（EFFECTIVE_WORKERS=1 または net なし）
for (( i=0; i<EFFECTIVE_WORKERS; i++ )); do
  # shellcheck disable=SC2086
  gawk -b $LIBS_ARGS $LIBS_VARS -f hawk.awk "${_plugin_args[@]}" -f "$APP_AWK" &
  WORKER_PIDS+=($!)
done
```

- [ ] **Step 6: E2E テストが通ることを確認する**

```bash
bash tests/e2e/supervisor_restart.sh
```

期待: `2 passed, 0 failed`

- [ ] **Step 7: 既存テストが壊れていないことを確認する**

```bash
make test
```

- [ ] **Step 8: コミットする**

```bash
git add libexec/hawk-supervise libexec/hawk-worker libexec/hawk-serve tests/e2e/supervisor_restart.sh
git commit -m "feat(supervisor): add wait-n supervisor with restart intensity"
```

---

## Task 5: message / objectspace / mailbox skeleton

**Files:**
- Create: `core/message.awk`
- Create: `core/objectspace.awk`
- Create: `core/mailbox.awk`
- Modify: `hawk.awk`（3 本の `@include` 追加）
- Create: `tests/unit/test_message.awk`
- Create: `tests/unit/test_objectspace.awk`
- Modify: `tests/unit/run.awk`

**Interfaces:**
- Consumes: `cache::_escape` / `cache::_unescape`（エスケープ共通化のため cache.awk が先にロードされている必要あり）
- Produces:
  - `message::make_call(to, frm, selector, args_str, reply_to, timeout_ms)` → エンコード済み文字列
  - `message::make_cast(to, frm, selector, args_str)` → エンコード済み文字列
  - `message::make_reply(to, frm, ref, payload)` → エンコード済み文字列
  - `message::make_error(to, frm, ref, err_type, err_msg)` → エンコード済み文字列
  - `message::decode(line, out)` → 1/0（out["to"], out["from"], out["ref"], out["kind"], out["selector"], out["args"], out["reply_to"], out["timeout_ms"] を設定）
  - `message::ref()` → ユニーク文字列
  - `objectspace::register(name, object_id)` → 1/0
  - `objectspace::resolve(name)` → object_id または空文字列
  - `objectspace::unregister(name)`

フィールド区切り: `\x1e`（RS = Record Separator）
args 区切り: `\x1f`（US = Unit Separator）

エンベロープフィールド順: `to\x1efrom\x1eref\x1ekind\x1eselector\x1eargs\x1ereply_to\x1etimeout_ms\x1etrace_id`

- [ ] **Step 1: message のテストを書く**

`tests/unit/test_message.awk` を作成する。

```awk
# SPDX-License-Identifier: MIT
# tests/unit/test_message.awk

function test_message_make_cast_decode(    enc, out) {
  enc = message::make_cast("proc://cache", "proc://web/0", "at:", "todos")
  delete out
  assert_eq(message::decode(enc, out), 1, "message: decode returns 1")
  assert_eq(out["to"],       "proc://cache",  "message: decode to")
  assert_eq(out["from"],     "proc://web/0",  "message: decode from")
  assert_eq(out["kind"],     "cast",          "message: decode kind")
  assert_eq(out["selector"], "at:",           "message: decode selector")
  assert_eq(out["args"],     "todos",         "message: decode args")
}

function test_message_make_call_has_reply_to(    enc, out) {
  enc = message::make_call("proc://cache", "proc://web/0", "at:", "todos", "/tmp/reply.fifo", 1000)
  delete out
  message::decode(enc, out)
  assert_eq(out["kind"],       "call",             "message: call kind")
  assert_eq(out["reply_to"],   "/tmp/reply.fifo",  "message: call reply_to")
  assert_eq(out["timeout_ms"], "1000",             "message: call timeout_ms")
}

function test_message_ref_unique(    r1, r2) {
  r1 = message::ref()
  r2 = message::ref()
  assert_true(r1 != r2, "message: ref() is unique")
  assert_true(length(r1) > 5, "message: ref() is non-trivial")
}

function test_message_decode_bad_line(    out) {
  assert_eq(message::decode("not_valid", out), 0, "message: decode bad line = 0")
}

function test_message_make_error_decode(    enc, out) {
  enc = message::make_error("proc://web/0", "proc://cache", "ref123", "Timeout", "timed out")
  delete out
  message::decode(enc, out)
  assert_eq(out["kind"],     "error",    "message: error kind")
  assert_eq(out["selector"], "Timeout",  "message: error selector=error_type")
}
```

- [ ] **Step 2: objectspace のテストを書く**

`tests/unit/test_objectspace.awk` を作成する。

```awk
# SPDX-License-Identifier: MIT
# tests/unit/test_objectspace.awk

function test_objectspace_register_resolve(    r) {
  objectspace::_reset()
  objectspace::register("cache", "proc://cache/global")
  r = objectspace::resolve("cache")
  assert_eq(r, "proc://cache/global", "objectspace: register/resolve")
}

function test_objectspace_resolve_unknown() {
  objectspace::_reset()
  assert_eq(objectspace::resolve("no_such"), "", "objectspace: resolve unknown = empty")
}

function test_objectspace_unregister(    r) {
  objectspace::_reset()
  objectspace::register("svc", "proc://svc/1")
  objectspace::unregister("svc")
  assert_eq(objectspace::resolve("svc"), "", "objectspace: unregister clears name")
}
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
make test-unit 2>&1 | grep -E 'FAIL|message|objectspace'
```

- [ ] **Step 4: `core/message.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT
# core/message.awk -- message envelope

@namespace "message"

# フィールド区切り
_RS = "\x1e"
# args 内リスト区切り
_US = "\x1f"
_seq = 0

function ref(    ts, s) {
  ts = systime()
  _seq++
  return ts "_" PROCINFO["pid"] "_" _seq
}

function make_call(to, frm, selector, args_str, reply_to, timeout_ms,    r) {
  r = ref()
  return to _RS frm _RS r _RS "call" _RS selector _RS args_str _RS reply_to _RS timeout_ms _RS ""
}

function make_cast(to, frm, selector, args_str,    r) {
  r = ref()
  return to _RS frm _RS r _RS "cast" _RS selector _RS args_str _RS "" _RS "" _RS ""
}

function make_reply(to, frm, ref_val, payload) {
  return to _RS frm _RS ref_val _RS "reply" _RS "" _RS payload _RS "" _RS "" _RS ""
}

function make_error(to, frm, ref_val, err_type, err_msg) {
  return to _RS frm _RS ref_val _RS "error" _RS err_type _RS err_msg _RS "" _RS "" _RS ""
}

# out["to"] / ["from"] / ["ref"] / ["kind"] / ["selector"] / ["args"] / ["reply_to"] / ["timeout_ms"] / ["trace_id"]
function decode(line, out,    parts, n) {
  n = split(line, parts, _RS)
  if (n < 4) return 0
  out["to"]         = parts[1]
  out["from"]       = parts[2]
  out["ref"]        = parts[3]
  out["kind"]       = parts[4]
  out["selector"]   = (n >= 5) ? parts[5] : ""
  out["args"]       = (n >= 6) ? parts[6] : ""
  out["reply_to"]   = (n >= 7) ? parts[7] : ""
  out["timeout_ms"] = (n >= 8) ? parts[8] : ""
  out["trace_id"]   = (n >= 9) ? parts[9] : ""
  return 1
}

@namespace "awk"
```

- [ ] **Step 5: `core/objectspace.awk` を作成する**

Supervisor なしの場合はプロセスローカル AWK 配列を使う（`$HAWK_RUN_DIR` がある場合は将来的に TSV 連携）。

```awk
# SPDX-License-Identifier: MIT
# core/objectspace.awk -- logical name → proc ID resolution

@namespace "objectspace"

function register(name, object_id) {
  _registry[name] = object_id
  return 1
}

function resolve(name) {
  if (name in _registry) return _registry[name]
  return ""
}

function unregister(name) {
  delete _registry[name]
}

function cast(name, selector, args_str,    oid, enc) {
  oid = resolve(name)
  if (oid == "") return
  enc = message::make_cast(oid, ENVIRON["HAWK_PROC_ID"], selector, args_str)
  mailbox::send(oid, enc)
}

function call(name, selector, args_str, timeout_ms,    oid, reply_to, ref_val, enc, out, line) {
  oid = resolve(name)
  if (oid == "") return ""
  ref_val  = message::ref()
  reply_to = mailbox::_reply_path(ref_val)
  enc      = message::make_call(oid, ENVIRON["HAWK_PROC_ID"], selector, args_str, reply_to, timeout_ms)
  mailbox::send(oid, enc)
  line = mailbox::call(oid, enc, timeout_ms)
  if (line == "") return ""
  delete out
  if (!message::decode(line, out)) return ""
  return out["args"]
}

function _reset(    k) {
  for (k in _registry) delete _registry[k]
}

@namespace "awk"
```

- [ ] **Step 6: `core/mailbox.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT
# core/mailbox.awk -- FIFO transport

@namespace "mailbox"

function path(pid) {
  return ENVIRON["HAWK_RUN_DIR"] "/mailbox/" pid ".fifo"
}

function _reply_path(ref_val) {
  return ENVIRON["HAWK_RUN_DIR"] "/reply/" ref_val ".fifo"
}

function ensure(pid,    p) {
  p = path(pid)
  if (system("test -p \"" p "\"") != 0)
    system("mkfifo \"" p "\"")
}

function send(pid, encoded,    p, cmd) {
  p = path(pid)
  if (system("test -p \"" p "\"") != 0) return 0
  # print で非同期書き込み（fifo がブロックしないよう背景で行う）
  cmd = "echo " (shell_quote(encoded)) " > \"" p "\" &"
  system(cmd)
  return 1
}

function call(pid, encoded, timeout_ms,    reply_fifo, ref_val, out, line, sec) {
  delete out
  if (!message::decode(encoded, out)) return ""
  ref_val    = out["ref"]
  reply_fifo = _reply_path(ref_val)
  system("mkfifo \"" reply_fifo "\"")
  # Bash helper でタイムアウト付き read を行う
  sec = int((timeout_ms + 999) / 1000)
  cmd = "bash -c 'read -t " sec " line < \"" reply_fifo "\" && echo \"$line\"'"
  if ((cmd | getline line) > 0) {
    close(cmd)
    system("rm -f \"" reply_fifo "\"")
    return line
  }
  close(cmd)
  system("rm -f \"" reply_fifo "\"")
  return ""
}

function reply(reply_to, encoded) {
  system("echo " (shell_quote(encoded)) " > \"" reply_to "\" &")
}

function shell_quote(s,    r) {
  r = s
  gsub(/'/, "'\\''", r)
  return "'" r "'"
}

@namespace "awk"
```

- [ ] **Step 7: `hawk.awk` に 3 本の `@include` を追加する**

`core/cache.awk` の直後に追加する。

```awk
@include "core/cache.awk"
@include "core/message.awk"
@include "core/objectspace.awk"
@include "core/mailbox.awk"
@include "core/http.awk"
```

- [ ] **Step 8: `tests/unit/run.awk` に呼び出しと `@include` を追加する**

cache テスト群の後に追加する。

```awk
  test_message_make_cast_decode()
  test_message_make_call_has_reply_to()
  test_message_ref_unique()
  test_message_decode_bad_line()
  test_message_make_error_decode()

  test_objectspace_register_resolve()
  test_objectspace_resolve_unknown()
  test_objectspace_unregister()
```

末尾の `@include` 群に追加する。

```awk
@include "tests/unit/test_message.awk"
@include "tests/unit/test_objectspace.awk"
```

- [ ] **Step 9: テストが通ることを確認する**

```bash
make test-unit
```

期待: 全テスト PASS

- [ ] **Step 10: コミットする**

```bash
git add core/message.awk core/objectspace.awk core/mailbox.awk hawk.awk \
        tests/unit/test_message.awk tests/unit/test_objectspace.awk tests/unit/run.awk
git commit -m "feat(runtime): add message envelope, objectspace registry, mailbox transport"
```

---

## Task 6: proc facade

**Files:**
- Create: `core/proc.awk`
- Modify: `hawk.awk`（`@include "core/proc.awk"` 追加）
- Create: `tests/unit/test_proc.awk`
- Modify: `tests/unit/run.awk`
- Create: `tests/e2e/proc_mailbox.sh`

**Interfaces:**
- Consumes: `objectspace::register/resolve/cast/call`、`message::*`、`mailbox::*`、`ENVIRON["HAWK_PROC_ID"]`
- Produces:
  - `proc::self()` → 現在の proc ID（`HAWK_PROC_ID` または `pid:N` 形式）
  - `proc::register(name, pid)` → 1/0
  - `proc::whereis(name)` → pid または空文字列
  - `proc::cast(name_or_pid, message_str)` → なし
  - `proc::call(name_or_pid, message_str, timeout_ms)` → 返信ペイロードまたは空文字列

- [ ] **Step 1: テストを書く**

`tests/unit/test_proc.awk` を作成する。

```awk
# SPDX-License-Identifier: MIT
# tests/unit/test_proc.awk

function test_proc_self_has_value(    s) {
  s = proc::self()
  assert_true(length(s) > 0, "proc: self() returns non-empty")
}

function test_proc_self_env(    saved) {
  saved = ENVIRON["HAWK_PROC_ID"]
  ENVIRON["HAWK_PROC_ID"] = "web:3"
  assert_eq(proc::self(), "web:3", "proc: self() returns HAWK_PROC_ID")
  ENVIRON["HAWK_PROC_ID"] = saved
}

function test_proc_register_whereis(    saved) {
  saved = ENVIRON["HAWK_PROC_ID"]
  ENVIRON["HAWK_PROC_ID"] = "web:0"
  objectspace::_reset()
  proc::register("myservice", "proc://svc/1")
  assert_eq(proc::whereis("myservice"), "proc://svc/1", "proc: register/whereis")
  ENVIRON["HAWK_PROC_ID"] = saved
}

function test_proc_whereis_unknown() {
  objectspace::_reset()
  assert_eq(proc::whereis("no_such"), "", "proc: whereis unknown = empty")
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
make test-unit 2>&1 | grep -E 'FAIL|proc::'
```

- [ ] **Step 3: `core/proc.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT
# core/proc.awk -- proc facade

@namespace "proc"

function self(    id) {
  id = ENVIRON["HAWK_PROC_ID"]
  if (id != "") return id
  return "pid:" PROCINFO["pid"]
}

function register(name, pid) {
  return objectspace::register(name, pid)
}

function whereis(name) {
  return objectspace::resolve(name)
}

function cast(name_or_pid, message_str,    oid) {
  oid = objectspace::resolve(name_or_pid)
  if (oid == "") oid = name_or_pid
  mailbox::send(oid, message_str)
}

function call(name_or_pid, message_str, timeout_ms,    oid) {
  oid = objectspace::resolve(name_or_pid)
  if (oid == "") oid = name_or_pid
  return mailbox::call(oid, message_str, timeout_ms)
}

@namespace "awk"
```

- [ ] **Step 4: `hawk.awk` に `@include` を追加する**

`core/mailbox.awk` の直後に追加する。

```awk
@include "core/mailbox.awk"
@include "core/proc.awk"
@include "core/http.awk"
```

- [ ] **Step 5: `tests/unit/run.awk` に呼び出しと `@include` を追加する**

objectspace テスト群の後に追加する。

```awk
  test_proc_self_has_value()
  test_proc_self_env()
  test_proc_register_whereis()
  test_proc_whereis_unknown()
```

末尾に追加する。

```awk
@include "tests/unit/test_proc.awk"
```

- [ ] **Step 6: テストが通ることを確認する**

```bash
make test-unit
```

期待: 全テスト PASS

- [ ] **Step 7: コミットする**

```bash
git add core/proc.awk hawk.awk tests/unit/test_proc.awk tests/unit/run.awk
git commit -m "feat(runtime): add proc facade over objectspace/mailbox"
```

---

## Task 7: Zig cache backend

**Files:**
- Create: `libs/cache/build.zig`
- Create: `libs/cache/src/root.zig`
- Create: `libs/cache/src/cache.zig`
- Create: `libs/cache/tests/cache_test.zig`
- Modify: `core/cache.awk`（`_get_zig`、`_set_zig`、`_del_zig` を完成させる）

**Interfaces:**
- Consumes: `libs/_common/gawk_ffi.zig`、`HAWK_LIBS_cache=1`（hawk-libs が設定）
- Produces:
  - `hawk_cache_get(key)` → 文字列（miss は空文字列）
  - `hawk_cache_set(key, value, ttl_ms)` → `"1"` または `"0"`
  - `hawk_cache_del(key)` → `"1"`
  - `hawk_cache_has(key)` → `"1"` または `"0"`
  - `hawk_cache_stats()` → 統計文字列
- Entry struct: `key[128]u8`、`val[2048]u8`、`expires_at: i64`（ns epoch）、SLOT_COUNT = 4096、open addressing

- [ ] **Step 1: Zig ユニットテストを書く**

`libs/cache/tests/cache_test.zig` を作成する。

```zig
// SPDX-License-Identifier: MIT
const std = @import("std");
const cache = @import("cache");

test "set and get basic" {
    cache.init();
    defer cache.deinit();
    try cache.set("hello", "world", 60_000);
    const v = cache.get("hello");
    try std.testing.expectEqualStrings("world", v orelse return error.Miss);
}

test "get missing returns null" {
    cache.init();
    defer cache.deinit();
    const v = cache.get("no_such_key");
    try std.testing.expect(v == null);
}

test "del removes entry" {
    cache.init();
    defer cache.deinit();
    try cache.set("del_k", "v", 60_000);
    cache.del("del_k");
    try std.testing.expect(cache.get("del_k") == null);
}

test "TTL expiry" {
    cache.init();
    defer cache.deinit();
    try cache.set("exp_k", "v", 1); // 1ms TTL
    std.time.sleep(2_000_000);      // 2ms
    try std.testing.expect(cache.get("exp_k") == null);
}

test "has returns correct result" {
    cache.init();
    defer cache.deinit();
    try cache.set("has_k", "v", 60_000);
    try std.testing.expect(cache.has("has_k"));
    try std.testing.expect(!cache.has("no_has"));
}

test "tombstone: del does not break displaced key" {
    cache.init();
    defer cache.deinit();
    // Find two keys that map to the same djb2 % SLOT_COUNT slot at runtime.
    // We search rather than pre-computing to avoid hash-constant drift.
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    var ka: []const u8 = "";
    var kb: []const u8 = "";
    outer: for (0..2000) |i| {
        ka = std.fmt.bufPrint(&buf_a, "ck_{d}", .{i}) catch continue;
        const slot_a = cache.djb2(ka) % cache.SLOT_COUNT;
        for (i + 1..4000) |j| {
            kb = std.fmt.bufPrint(&buf_b, "ck_{d}", .{j}) catch continue;
            if (cache.djb2(kb) % cache.SLOT_COUNT == slot_a) break :outer;
        }
    }
    try std.testing.expect(ka.len > 0);  // collision pair found

    try cache.set(ka, "val_a", 60_000);
    try cache.set(kb, "val_b", 60_000);

    // delete ka → tombstone at the shared slot
    cache.del(ka);

    // kb must still be reachable through the probe chain past the tombstone
    const vb = cache.get(kb);
    try std.testing.expectEqualStrings("val_b", vb orelse return error.TombstoneBrokeProbChain);

    // ka must be gone
    try std.testing.expect(cache.get(ka) == null);

    // tombstone slot must be reusable for a new insert
    try cache.set(ka, "val_a2", 60_000);
    const va2 = cache.get(ka);
    try std.testing.expectEqualStrings("val_a2", va2 orelse return error.TombstoneReuseFailure);
}
```

- [ ] **Step 2: Zig テストが失敗することを確認する**

```bash
cd libs/cache && zig build test 2>&1 | head -10
```

期待: `file not found: cache.zig` 相当のエラー

- [ ] **Step 3: `libs/cache/src/cache.zig` を作成する**

```zig
// SPDX-License-Identifier: MIT
// libs/cache/src/cache.zig -- fixed-slot hash table cache

const std = @import("std");

pub const SLOT_COUNT = 4096;
pub const KEY_MAX    = 128;
pub const VAL_MAX    = 2048;

const Entry = extern struct {
    hash:       u64,
    key_len:    u32,
    val_len:    u32,
    expires_at: i64,   // milliseconds since epoch; 0 = no expiry
    flags:      u32,
    key:        [KEY_MAX]u8,
    val:        [VAL_MAX]u8,
};

var slots: [SLOT_COUNT]Entry = undefined;
var inited: bool = false;

pub fn init() void {
    @memset(std.mem.asBytes(&slots), 0);
    inited = true;
}

pub fn deinit() void {
    inited = false;
}

// flags bits
const FLAG_LIVE: u32 = 1;
const FLAG_TOMBSTONE: u32 = 2;

pub fn djb2(key: []const u8) u64 {
    var h: u64 = 5381;
    for (key) |c| h = h *% 33 +% c;
    return h;
}

fn nowMs() i64 {
    return @divFloor(std.time.nanoTimestamp(), 1_000_000);
}

fn isExpired(e: *const Entry) bool {
    if (e.expires_at == 0) return false;
    return nowMs() >= e.expires_at;
}

// Truly empty: never written and not a tombstone.
fn isEmpty(e: *const Entry) bool {
    return (e.flags & FLAG_TOMBSTONE) == 0 and e.key_len == 0;
}

// Tombstone: deleted or expired-in-place; probe must continue past this slot.
fn isTombstone(e: *const Entry) bool {
    return (e.flags & FLAG_TOMBSTONE) != 0;
}

fn writeEntry(e: *Entry, h: u64, key: []const u8, val: []const u8, ttl_ms: i64) void {
    e.hash = h;
    e.key_len = @intCast(key.len);
    e.val_len = @intCast(val.len);
    e.expires_at = if (ttl_ms > 0) nowMs() + ttl_ms else 0;
    e.flags = FLAG_LIVE;
    @memcpy(e.key[0..key.len], key);
    @memcpy(e.val[0..val.len], val);
}

pub fn set(key: []const u8, val: []const u8, ttl_ms: i64) !void {
    if (key.len > KEY_MAX or val.len > VAL_MAX) return error.TooLarge;
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    var tombstone_i: ?usize = null;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) {
            if (tombstone_i == null) tombstone_i = i;
            continue;
        }
        if (isEmpty(e)) {
            writeEntry(&slots[tombstone_i orelse i], h, key, val, ttl_ms);
            return;
        }
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            writeEntry(e, h, key, val, ttl_ms);  // overwrite (update)
            return;
        }
    }
    if (tombstone_i) |ti| {
        writeEntry(&slots[ti], h, key, val, ttl_ms);
        return;
    }
    return error.Full;
}

pub fn get(key: []const u8) ?[]const u8 {
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) continue;     // deleted slot: probe must continue
        if (isEmpty(e)) return null;      // truly empty: key absent
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            if (isExpired(e)) {
                // ponytail: mark tombstone instead of zeroing key_len to preserve probe chain
                e.key_len = 0;
                e.flags = FLAG_TOMBSTONE;
                return null;
            }
            return e.val[0..e.val_len];
        }
    }
    return null;
}

pub fn del(key: []const u8) void {
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) continue;
        if (isEmpty(e)) return;
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            e.key_len = 0;
            e.flags = FLAG_TOMBSTONE;
            return;
        }
    }
}

pub fn has(key: []const u8) bool {
    return get(key) != null;
}
```

- [ ] **Step 4: `libs/cache/src/root.zig` を作成する**

```zig
// SPDX-License-Identifier: MIT
// libs/cache/src/root.zig -- gawk extension entry point

const std = @import("std");
const ffi = @import("gawk_ffi");
const cache = @import("cache");

var _inited = false;

fn ensureInit() void {
    if (!_inited) { cache.init(); _inited = true; }
}

fn cacheGet(args: ffi.Args) ffi.Result {
    ensureInit();
    const key = args.getString(0);
    const v = cache.get(key) orelse return .{ .str = "" };
    return .{ .str = v };
}

fn cacheSet(args: ffi.Args) ffi.Result {
    ensureInit();
    const key    = args.getString(0);
    const val    = args.getString(1);
    const ttl_ms = args.getInt(2);
    cache.set(key, val, ttl_ms) catch return .{ .str = "0" };
    return .{ .str = "1" };
}

fn cacheDel(args: ffi.Args) ffi.Result {
    ensureInit();
    cache.del(args.getString(0));
    return .{ .str = "1" };
}

fn cacheHas(args: ffi.Args) ffi.Result {
    ensureInit();
    return .{ .str = if (cache.has(args.getString(0))) "1" else "0" };
}

fn cacheStats(_: ffi.Args) ffi.Result {
    // ponytail: stub — expand when monitoring is needed
    return .{ .str = "slots=" ++ std.fmt.comptimePrint("{d}", .{cache.SLOT_COUNT}) };
}

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_cache",
    .functions = &.{
        .{ .name = "hawk_cache_get",   .impl = &cacheGet,   .args = 1 },
        .{ .name = "hawk_cache_set",   .impl = &cacheSet,   .args = 3 },
        .{ .name = "hawk_cache_del",   .impl = &cacheDel,   .args = 1 },
        .{ .name = "hawk_cache_has",   .impl = &cacheHas,   .args = 1 },
        .{ .name = "hawk_cache_stats", .impl = &cacheStats, .args = 0 },
    },
});
comptime { _ = _ffi_entry; }
```

- [ ] **Step 5: `libs/cache/build.zig` を作成する**

```zig
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const gawk_include = b.option([]const u8, "gawk-include",
        "Path to gawkapi.h directory") orelse findGawkInclude(b) orelse "";
    if (gawk_include.len == 0)
        @panic("gawkapi.h not found. Set -Dgawk-include=/path/to/gawk/include");

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
        .target = target, .optimize = optimize, .link_libc = true,
    });
    ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });

    const cache_mod = b.createModule(.{
        .root_source_file = b.path("src/cache.zig"),
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target, .optimize = optimize, .link_libc = true,
    });
    root_mod.addImport("gawk_ffi", ffi_mod);
    root_mod.addImport("cache", cache_mod);

    const lib = b.addLibrary(.{
        .name = "hawk_cache",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cache_test.zig"),
        .target = target, .optimize = optimize,
    });
    test_mod.addImport("cache", cache_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests  = b.addRunArtifact(unit_tests);
    const test_step  = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn findGawkInclude(_: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/include/gawk",
        "/usr/local/include/gawk",
        "/usr/local/include",
        "/usr/include/gawk",
    };
    for (candidates) |p| return p;
    return null;
}
```

- [ ] **Step 6: Zig テストが通ることを確認する**

```bash
cd libs/cache && zig build test
```

期待: `All 6 tests passed.`

- [ ] **Step 7: `core/cache.awk` の Zig stub を完成させる**

Task 3 で追加した stub を実装に置き換える。

```awk
function _get_zig(key,    v) {
  v = hawk_cache_get(key)
  if (v != "") { _FOUND = 1; _STATS_HIT++; return v }
  _STATS_MISS++
  return ""
}

function _set_zig(key, value, ttl_sec) {
  hawk_cache_set(key, value, ttl_sec * 1000)
  _STATS_SET++
}

function _del_zig(key) {
  hawk_cache_del(key)
}
```

- [ ] **Step 8: Zig cache をビルドしてテストする**

```bash
cd libs/cache && zig build
cd ../..
make test-unit
make test
```

期待: 全テスト PASS。Zig ビルド済みの場合、`cache::backend()` が `"zig"` を返す。

- [ ] **Step 9: コミットする**

```bash
git add libs/cache/ core/cache.awk
git commit -m "feat(cache): add optional Zig shared cache backend with 4096-slot hash table"
```

---

## 自己レビュー

### Spec カバレッジ確認

- cache facade + memory backend → Task 1
- file backend（escape/lock/atomic write）→ Task 2
- backend auto detect（zig → file → memory）、off → Task 3
- supervisor（wait -n、restart intensity、run dir セキュア作成）→ Task 4
- message envelope（encode/decode、ref）→ Task 5
- objectspace（register/resolve/unregister）→ Task 5
- mailbox（FIFO transport、send/call）→ Task 5
- proc facade（self/register/whereis/cast/call）→ Task 6
- Zig cache backend（固定長スロット、TTL、collision）→ Task 7
- `HAWK_RUN_DIR` セキュア作成（mktemp、シンボリックリンク拒否、オーナー検証）→ Task 4
- registry の `reg_token` によるプロセス同一性検証 → Task 4（hawk-supervise 内で実装済み）
- `HAWK_LIBS_cache` フラグ → Task 1（libs.awk 更新）
- 既存テスト維持 → 各タスクで `make test` / `make test-unit` を確認

### プレースホルダー確認

なし。すべてのステップに実際のコードを記載した。

### 型・関数名の一貫性確認

- `cache::_reset()` → Task 1 で定義、Task 2/3 のテストで参照 ✓
- `cache::_escape()` / `cache::_unescape()` → Task 2 で定義、テストで参照 ✓
- `message::decode(line, out)` → Task 5 で定義、objectspace / proc テストで参照 ✓
- `objectspace::_reset()` → Task 5 で定義、proc テストで参照 ✓
- `hawk_cache_get/set/del/has/stats` → Task 7 の Zig 関数名と AWK ラッパーが一致 ✓
