# DSL拡張: env/hawk dispatch・型アノテーション・`??`演算子 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** H-awk DSLに `env.get()`・`hawk.app.on/all`・`??` 演算子・`let name: Type = expr` 型アノテーションを追加する。

**Architecture:** DSLデシュガーパイプラインに `desugar_nullcoalesce.awk`（`??` 変換）を追加し、`desugar_let.awk` を型アノテーション対応に拡張する。ランタイム側は `core/type.awk`（型変換モジュール）を追加し、`core/env.awk` と `core/hawk.awk` に `dispatch` 関数を拡張する。

**Tech Stack:** gawk 5.0+, @namespace, DSL desugar pipeline (awk)

---

## ファイルマップ

| ファイル | 変更種別 | 担当 |
|---------|---------|------|
| `core/env.awk` | Modify | `env::dispatch` 追加 |
| `core/hawk.awk` | Modify | `dispatch` に `a3`、`on`/`all`、`listen` 検証 |
| `core/type.awk` | Create | `type::coerce(val, typename)` |
| `hawk.awk` | Modify | `@include "core/type.awk"` 追加 |
| `dsl/desugar_state.awk` | Modify | `_DS_tc_count = 0` 追加 |
| `dsl/desugar_nullcoalesce.awk` | Create | `??` 汎用変換 |
| `dsl/desugar_let.awk` | Modify | 型アノテーション対応 |
| `dsl/desugar.awk` | Modify | パイプライン更新 |
| `app.awk` | Modify | 新記法に更新 |
| `tests/unit/dsl/env_dispatch/` | Create | DSL fixture |
| `tests/unit/dsl/hawk_on_all/` | Create | DSL fixture |
| `tests/unit/dsl/nullcoalesce_basic/` | Create | DSL fixture |
| `tests/unit/dsl/nullcoalesce_in_call/` | Create | DSL fixture |
| `tests/unit/dsl/type_int/` | Create | DSL fixture |
| `tests/unit/dsl/type_all/` | Create | DSL fixture |
| `tests/unit/dsl/type_with_nc/` | Create | DSL fixture |

---

## Task 1: `env::dispatch` を `core/env.awk` に追加

**Files:**
- Modify: `core/env.awk`
- Create: `tests/unit/dsl/env_dispatch/input.awk`
- Create: `tests/unit/dsl/env_dispatch/expected.awk`

- [ ] **Step 1: DSL fixture 作成**

`tests/unit/dsl/env_dispatch/input.awk`:
```awk
function setup() {
  let port = env.get("PORT")
  let host = env.get("HOST")
}
```

`tests/unit/dsl/env_dispatch/expected.awk`:
```awk
function setup(    port, host) {
  port = env::dispatch("get", "PORT")
  host = env::dispatch("get", "HOST")
}
```

- [ ] **Step 2: テスト実行 → PASS 確認（desugar は既存実装で動く）**

```bash
./tests/unit/dsl/run.sh 2>&1 | grep env_dispatch
```
Expected: `  PASS: env_dispatch`

（`env.get(x)` → `env::dispatch("get", x)` は既存の `desugar_dot.awk` で変換済み。Fixture はデシュガー動作を記録する）

- [ ] **Step 3: `env::dispatch` をランタイムに追加**

`core/env.awk` に追加（`function has(key)` の後、`@namespace "awk"` の前）:
```awk
function dispatch(path, a1, a2) {
    if (path == "get") return get(a1)
    if (path == "set") { set(a1, a2); return }
    if (path == "del") { del(a1);     return }
    if (path == "has") return has(a1)
    print "env::dispatch: unknown path: " path > "/dev/stderr"
}
```

- [ ] **Step 4: ランタイム動作確認**

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  ENVIRON["TEST_PORT"] = "9999"
  v = env::dispatch("get", "TEST_PORT")
  if (v != "9999") { print "FAIL: got " v > "/dev/stderr"; exit 1 }
  print "OK"
  exit 0
}'
```
Expected: `OK`

- [ ] **Step 5: commit**

```bash
git add core/env.awk tests/unit/dsl/env_dispatch/
git commit -m "feat(env): add env::dispatch + DSL fixture"
```

---

## Task 2: `hawk::dispatch` に `on`/`all` 追加・`listen` 検証

**Files:**
- Modify: `core/hawk.awk`
- Create: `tests/unit/dsl/hawk_on_all/input.awk`
- Create: `tests/unit/dsl/hawk_on_all/expected.awk`

- [ ] **Step 1: DSL fixture 作成**

`tests/unit/dsl/hawk_on_all/input.awk`:
```awk
BEGIN {
  hawk.app.on("GET,POST", "/api", "handler")
  hawk.app.all("/", "catchall")
}
```

`tests/unit/dsl/hawk_on_all/expected.awk`:
```awk
BEGIN {
  hawk::dispatch("app.on", "GET,POST", "/api", "handler")
  hawk::dispatch("app.all", "/", "catchall")
}
```

- [ ] **Step 2: テスト実行 → PASS 確認（desugar は既存実装で動く）**

```bash
./tests/unit/dsl/run.sh 2>&1 | grep hawk_on_all
```
Expected: `  PASS: hawk_on_all`

- [ ] **Step 3: `core/hawk.awk` を更新**

`function dispatch(path, a1, a2)` → `function dispatch(path, a1, a2, a3)` に変更。
`app.listen` の行と `unknown path` の前に追加:
```awk
function dispatch(path, a1, a2, a3) {
    if (path == "app.get")    { get(a1, a2);      return }
    if (path == "app.post")   { post(a1, a2);     return }
    if (path == "app.put")    { put(a1, a2);      return }
    if (path == "app.del")    { del(a1, a2);      return }
    if (path == "app.patch")  { patch(a1, a2);    return }
    if (path == "app.head")   { head(a1, a2);     return }
    if (path == "app.on")     { on(a1, a2, a3);   return }
    if (path == "app.all")    { all(a1, a2);      return }
    if (path == "app.listen") { listen(a1);       return }
    print "hawk::dispatch: unknown path: " path > "/dev/stderr"
}
```

- [ ] **Step 4: `listen` 関数を数値検証つきに変更**

`core/hawk.awk` の `function listen(port)` を:
```awk
function listen(port) {
    if (port !~ /^[0-9]+$/ || port + 0 == 0) {
        print "hawk::listen: invalid port: \"" port "\"" > "/dev/stderr"
        exit 1
    }
    awk::listen(port + 0)
}
```

- [ ] **Step 5: 動作確認**

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  hawk::dispatch("app.get", "/test", "h")
  hawk::dispatch("app.on", "GET,POST", "/api", "h2")
  hawk::dispatch("app.all", "/", "h3")
  print "OK"
  exit 0
}' 2>&1
```
Expected: `OK`

listen の無効ポートテスト:
```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e 'BEGIN { hawk::listen("abc") }' 2>&1
```
Expected: `hawk::listen: invalid port: "abc"`（exit code 1）

- [ ] **Step 6: commit**

```bash
git add core/hawk.awk tests/unit/dsl/hawk_on_all/
git commit -m "feat(hawk): add on/all to dispatch, add listen port validation"
```

---

## Task 3: `core/type.awk` 作成

**Files:**
- Create: `core/type.awk`
- Modify: `hawk.awk`

- [ ] **Step 1: `core/type.awk` を作成**

```awk
# SPDX-License-Identifier: MIT
# core/type.awk -- DSL型アノテーション用ランタイム変換
@namespace "type"

function coerce(val, typename) {
    if (typename == "Int") {
        if (val !~ /^-?[0-9]+$/) {
            print "type error: cannot coerce \"" val "\" to Int" > "/dev/stderr"
            exit 1
        }
        return int(val)
    }
    if (typename == "Float") {
        if (val !~ /^-?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$/) {
            print "type error: cannot coerce \"" val "\" to Float" > "/dev/stderr"
            exit 1
        }
        return val + 0
    }
    if (typename == "Str") {
        return val ""
    }
    if (typename == "Bool") {
        if (val == "true"  || val == "1") return 1
        if (val == "false" || val == "0" || val == "") return 0
        print "type error: cannot coerce \"" val "\" to Bool" > "/dev/stderr"
        exit 1
    }
    print "type::coerce: unknown type: " typename > "/dev/stderr"
    exit 1
}

@namespace "awk"
```

- [ ] **Step 2: `hawk.awk` に `@include` 追加**

`hawk.awk` の `@include "core/env.awk"` の後（または `@include "core/ctx.awk"` の前）に追加:
```awk
@include "core/type.awk"
```

- [ ] **Step 3: 動作確認**

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  if (type::coerce("42",   "Int")   != 42)   { print "FAIL Int"   > "/dev/stderr"; exit 1 }
  if (type::coerce("3.14", "Float") != 3.14)  { print "FAIL Float" > "/dev/stderr"; exit 1 }
  if (type::coerce(99,     "Str")   != "99")  { print "FAIL Str"   > "/dev/stderr"; exit 1 }
  if (type::coerce("true", "Bool")  != 1)     { print "FAIL Bool"  > "/dev/stderr"; exit 1 }
  if (type::coerce("",     "Bool")  != 0)     { print "FAIL Bool0" > "/dev/stderr"; exit 1 }
  print "OK"
  exit 0
}' 2>&1
```
Expected: `OK`

エラーケース:
```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e 'BEGIN { type::coerce("abc", "Int") }' 2>&1
```
Expected: `type error: cannot coerce "abc" to Int`（exit code 1）

- [ ] **Step 4: lint 確認**

```bash
make lint
```
Expected: `lint OK`

- [ ] **Step 5: commit**

```bash
git add core/type.awk hawk.awk
git commit -m "feat(type): add type::coerce runtime module + @include in hawk.awk"
```

---

## Task 4: `desugar_state.awk` に `_DS_tc_count` 追加

**Files:**
- Modify: `dsl/desugar_state.awk`

- [ ] **Step 1: `_DS_tc_count = 0` を `_ds_init` に追加**

`dsl/desugar_state.awk` の `_DS_body_count   = 0` の後に追加:
```awk
function _ds_init() {
  _DS_brace_depth = 0
  _DS_in_function = 0
  _DS_func_name   = ""
  _DS_func_sig    = ""
  _DS_let_count   = 0
  _DS_body_count  = 0
  _DS_tc_count    = 0
  _DS_had_error   = 0
  _DS_src_file    = ""
  delete _DS_let_locals
  delete _DS_body_buf
}
```

- [ ] **Step 2: 既存 DSL テストが引き続きパスすること確認**

```bash
make test-dsl
```
Expected: 全テスト PASS、失敗 0

- [ ] **Step 3: commit**

```bash
git add dsl/desugar_state.awk
git commit -m "feat(dsl): add _DS_tc_count to desugar state"
```

---

## Task 5: `dsl/desugar_nullcoalesce.awk` 作成 + パイプライン組み込み

**Files:**
- Create: `dsl/desugar_nullcoalesce.awk`
- Modify: `dsl/desugar.awk`
- Create: `tests/unit/dsl/nullcoalesce_basic/input.awk`
- Create: `tests/unit/dsl/nullcoalesce_basic/expected.awk`
- Create: `tests/unit/dsl/nullcoalesce_in_call/input.awk`
- Create: `tests/unit/dsl/nullcoalesce_in_call/expected.awk`

- [ ] **Step 1: DSL fixtures 作成**

`tests/unit/dsl/nullcoalesce_basic/input.awk`:
```awk
function setup() {
  let port = env::dispatch("get", "PORT") ?? 8080
}
```

`tests/unit/dsl/nullcoalesce_basic/expected.awk`:
```awk
function setup(    _ds_tc_1, port) {
  _ds_tc_1 = env::dispatch("get", "PORT")
  port = (_ds_tc_1 != "" ? _ds_tc_1 : 8080)
}
```

`tests/unit/dsl/nullcoalesce_in_call/input.awk`:
```awk
BEGIN {
  hawk::dispatch("app.listen", env::dispatch("get", "PORT") ?? 8080)
}
```

`tests/unit/dsl/nullcoalesce_in_call/expected.awk`:
```awk
BEGIN {
  _ds_tc_1 = env::dispatch("get", "PORT")
  hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
}
```

（`lpart` は `,` で終わるため、`_ds_nc_transform` の return 文で ` ` を補う: `lpart sep "(" ...` ただし lb=0 なら sep=""）

- [ ] **Step 2: テスト実行 → FAIL 確認**

```bash
./tests/unit/dsl/run.sh 2>&1 | grep -E "nullcoalesce"
```
Expected: 両方 `FAIL`（実装前なので）

- [ ] **Step 3: `dsl/desugar_nullcoalesce.awk` を作成**

```awk
# SPDX-License-Identifier: MIT
# dsl/desugar_nullcoalesce.awk -- ?? null-coalescing operator transform
#
# expr ?? default  →  temp = expr (emitted as pre-line)
#                      (temp != "" ? temp : default)  (replaces expr ?? default)
#
# Works anywhere in a line (function args, let RHS, standalone expressions).
# String/comment regions are masked so ?? inside literals is not transformed.
# Temp vars (_ds_tc_N) are registered as function locals when inside a function.

# _ds_nc_mask: replace safe=0 segment chars with 'x' (same length, for position math)
function _ds_nc_mask(segs, n,    result, i, pad) {
    result = ""
    for (i = 1; i <= n; i++) {
        if (segs[i, "safe"]) {
            result = result segs[i, "text"]
        } else {
            pad = segs[i, "text"]
            gsub(/./, "x", pad)
            result = result pad
        }
    }
    return result
}

# _ds_nc_left_bound: scan left from pos, return position of delimiter (, = () or 0
function _ds_nc_left_bound(masked, pos,    i, c, depth) {
    depth = 0
    for (i = pos; i >= 1; i--) {
        c = substr(masked, i, 1)
        if      (c == ")")                         { depth++ }
        else if (c == "(")  { if (depth == 0) return i; depth-- }
        else if ((c == "," || c == "=") && depth == 0) { return i }
    }
    return 0
}

# _ds_nc_right_bound: scan right from pos, return position of delimiter () ,) or len+1
function _ds_nc_right_bound(masked, pos, mlen,    i, c, depth) {
    depth = 0
    for (i = pos; i <= mlen; i++) {
        c = substr(masked, i, 1)
        if      (c == "(")               { depth++ }
        else if (c == ")") { if (depth == 0) return i; depth-- }
        else if (c == "," && depth == 0) { return i }
    }
    return mlen + 1
}

function _ds_trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# _ds_nc_transform: transform first ?? in line.
# Fills pre_buf[1] with temp var assignment if ?? is found.
# Returns modified line (with ?? replaced by ternary).
# Returns original line unchanged if no ?? found.
function _ds_nc_transform(line, pre_buf,    segs, n, masked, qpos,
    lb, rb, mlen, expr, dflt, tmpvar, lpart, rpart, indent) {
    delete pre_buf
    n = _ds_split_code_segs(line, segs)
    masked = _ds_nc_mask(segs, n)
    mlen = length(masked)

    if (!match(masked, /\?\?/)) return line

    qpos = RSTART  # 1-indexed position of first ?

    # Find indentation (for pre-line)
    indent = ""
    if (match(line, /^[[:space:]]*/)) indent = substr(line, 1, RLENGTH)

    # Left boundary: scan from qpos-1 leftward
    lb = _ds_nc_left_bound(masked, qpos - 1)

    # Right boundary: scan from qpos+2 rightward (after ??)
    rb = _ds_nc_right_bound(masked, qpos + 2, mlen)

    # Extract EXPR: from lb+1 to qpos-1 (trimmed)
    expr = _ds_trim(substr(line, lb + 1, qpos - lb - 1))

    # Extract DEFAULT: from qpos+2 to rb-1 (trimmed)
    dflt = _ds_trim(substr(line, qpos + 2, rb - qpos - 2))

    # Generate temp var name
    _DS_tc_count++
    tmpvar = "_ds_tc_" _DS_tc_count

    # Register as function local (for hoisting) when inside a function body
    if (_DS_in_function) _DS_let_locals[++_DS_let_count] = tmpvar

    # Build pre-line: temp var assignment
    pre_buf[1] = indent tmpvar " = " expr

    # Build modified line: replace "lb_delimiter EXPR ?? DEFAULT" with ternary
    lpart = substr(line, 1, lb)       # up to and including left delimiter
    rpart = substr(line, rb)          # from right delimiter to end

    # sep: add space after delimiter (,/=/() when lb>0; no space when EXPR at line start
    sep = (lb > 0 ? " " : "")
    return lpart sep "(" tmpvar " != \"\" ? " tmpvar " : " dflt ")" rpart
}
```

- [ ] **Step 4: `dsl/desugar.awk` を更新してパイプラインに組み込む**

`@include "dsl/desugar_let.awk"` の後に追加:
```awk
@include "dsl/desugar_nullcoalesce.awk"
```

`_ds_process_line` 関数を更新。現在の実装:
```awk
function _ds_process_line(line, lineno,    transformed) {
  if (!_DS_in_function) {
    ...
    print _ds_dot_transform(line)
    return
  }
  ...
  transformed = _ds_let_transform(_ds_dot_transform(line), lineno)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}
```

更新後:
```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p) {
  if (!_DS_in_function) {
    if (line ~ /^[[:space:]]*let[[:space:]]/) {
      print "dsl error: " _DS_src_file ":" lineno \
        ": 'let' outside function body" > "/dev/stderr"
      _DS_had_error = 1
      exit 1
    }
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_sig     = line
      _DS_brace_depth  = _ds_net_braces(line)
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
      return
    }
    nc_result = _ds_nc_transform(_ds_dot_transform(line), nc_pre)
    for (p = 1; p in nc_pre; p++) print nc_pre[p]
    print nc_result
    return
  }

  # Inside function body
  _DS_brace_depth += _ds_net_braces(line)

  if (_DS_brace_depth <= 0) {
    _DS_in_function = 0
    print _ds_rewrite_sig(_DS_func_sig)
    for (i = 1; i <= _DS_body_count; i++) print _DS_body_buf[i]
    print _ds_dot_transform(line)
    return
  }

  nc_result = _ds_nc_transform(_ds_dot_transform(line), nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  transformed = _ds_let_transform(nc_result, lineno)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}
```

（注: `_DS_in_function` check は `_ds_nc_transform` 内で行うため、`_ds_nc_transform` を呼ぶ前に `_DS_in_function` を正しく設定する必要がある。関数定義行の検出より後で `??` 変換が走るため、body 内の `??` は正しく登録される）

- [ ] **Step 5: テスト実行 → PASS 確認**

```bash
make test-dsl
```
Expected: 全テスト PASS

- [ ] **Step 6: commit**

```bash
git add dsl/desugar_nullcoalesce.awk dsl/desugar.awk \
  tests/unit/dsl/nullcoalesce_basic/ tests/unit/dsl/nullcoalesce_in_call/
git commit -m "feat(dsl): implement ?? null-coalescing operator"
```

---

## Task 6: `dsl/desugar_let.awk` 型アノテーション対応

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/type_int/input.awk`
- Create: `tests/unit/dsl/type_int/expected.awk`
- Create: `tests/unit/dsl/type_all/input.awk`
- Create: `tests/unit/dsl/type_all/expected.awk`
- Create: `tests/unit/dsl/type_with_nc/input.awk`
- Create: `tests/unit/dsl/type_with_nc/expected.awk`

- [ ] **Step 1: DSL fixtures 作成**

`tests/unit/dsl/type_int/input.awk`:
```awk
function setup() {
  let port: Int = env::dispatch("get", "PORT")
}
```

`tests/unit/dsl/type_int/expected.awk`:
```awk
function setup(    port) {
  port = type::coerce(env::dispatch("get", "PORT"), "Int")
}
```

`tests/unit/dsl/type_all/input.awk`:
```awk
function types() {
  let n: Int = "42"
  let s: Str = 123
  let f: Float = "3.14"
  let b: Bool = "true"
}
```

`tests/unit/dsl/type_all/expected.awk`:
```awk
function types(    n, s, f, b) {
  n = type::coerce("42", "Int")
  s = type::coerce(123, "Str")
  f = type::coerce("3.14", "Float")
  b = type::coerce("true", "Bool")
}
```

`tests/unit/dsl/type_with_nc/input.awk`:
```awk
function setup() {
  let port: Int = env::dispatch("get", "PORT") ?? 8080
}
```

`tests/unit/dsl/type_with_nc/expected.awk`:
```awk
function setup(    _ds_tc_1, port) {
  _ds_tc_1 = env::dispatch("get", "PORT")
  port = type::coerce((_ds_tc_1 != "" ? _ds_tc_1 : 8080), "Int")
}
```

- [ ] **Step 2: テスト実行 → FAIL 確認**

```bash
./tests/unit/dsl/run.sh 2>&1 | grep -E "type_"
```
Expected: `type_int`、`type_all`、`type_with_nc` すべて FAIL

- [ ] **Step 3: `dsl/desugar_let.awk` を更新**

`_ds_let_transform` 関数の先頭（既存の Array init チェックの前）に型アノテーション処理を追加:

```awk
function _ds_let_transform(line, lineno,    arr) {
  # Type-annotated assignment: let name: Type = expr
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
  # Array init: let name = []  (existing)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] "delete " arr[2]
  }
  # Assignment: let name = expr  (existing)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] arr[2] " = " arr[3]
  }
  # Bare declaration: let name  (existing)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return ""
  }
  return line
}
```

- [ ] **Step 4: テスト実行 → PASS 確認**

```bash
make test-dsl
```
Expected: 全テスト PASS

- [ ] **Step 5: commit**

```bash
git add dsl/desugar_let.awk \
  tests/unit/dsl/type_int/ tests/unit/dsl/type_all/ tests/unit/dsl/type_with_nc/
git commit -m "feat(dsl): add type annotation support (let name: Type = expr)"
```

---

## Task 7: `app.awk` を新記法に更新

**Files:**
- Modify: `app.awk`

- [ ] **Step 1: `app.awk` の BEGIN ブロックを更新**

現在の `hawk.app.listen(env::get("PORT") ? env::get("PORT") + 0 : 8080)` を:
```awk
BEGIN {
  hawk.app.get("/",           "todo_index")
  hawk.app.get("/todos",      "todo_list_html")
  hawk.app.post("/todos",     "todo_add")
  hawk.app.del("/todos/:id",  "todo_delete")
  hawk.app.get("/todos.json", "todo_list_json")
  let port: Int = env.get("PORT") ?? 8080
  hawk.app.listen(port)
}
```

（注: `let port: Int` は `desugar.awk` が `let` を BEGIN 内で検出するとエラーになる。BEGIN 内での `??` は直接使う）

現在の `_ds_process_line` では `let` を関数外で使うとエラー。したがって:

```awk
BEGIN {
  hawk.app.get("/",           "todo_index")
  hawk.app.get("/todos",      "todo_list_html")
  hawk.app.post("/todos",     "todo_add")
  hawk.app.del("/todos/:id",  "todo_delete")
  hawk.app.get("/todos.json", "todo_list_json")
  hawk.app.listen(env.get("PORT") ?? 8080)
}
```

これは `??` が BEGIN 内でも動作する（Task 5 で対応済み）。

- [ ] **Step 2: デシュガー確認**

```bash
gawk -f dsl/desugar.awk app.awk | grep -v '^# line '
```

`hawk::dispatch("app.listen",` を含む行が `(_ds_tc_1 != "" ? _ds_tc_1 : 8080)` 形式になっていること確認。

- [ ] **Step 3: 全テスト**

```bash
make test-dsl && make lint
```
Expected: 全テスト PASS、lint OK

- [ ] **Step 4: commit**

```bash
git add app.awk
git commit -m "refactor(app): use env.get() ?? and hawk.app.listen DSL syntax"
```

---

## 完了確認

```bash
make test
```
Expected: `lint OK`、全 DSL テスト PASS

---

## Phase 2 スコープ外（このプランに含まない）

- `??` のネスト（`a ?? b ?? c`）
- 同一行に複数の `??`
- `let name: Type` (初期値なしの型宣言)
- ポート `0`（OS割当）のサポート
