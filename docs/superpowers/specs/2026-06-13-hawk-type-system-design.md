# Hawk DSL 型情報拡張 設計仕様書

**作成日**: 2026-06-13  
**スコープ**: Phase 1–5 (Function Signature Registry → Option/Result)  
**対象ブランチ**: master

---

## 目的

Hawk DSL の型システムを、いきなり本格的な静的型付き言語として実装するのではなく、**desugar 時に危険なコードを検出するための型情報** を段階的に追加する。

```
Hawk DSL source
  ↓ desugar / static check  ← ここに型チェックを追加
plain gawk
  ↓
gawk VM
```

型情報はランタイムではなく、主に以下の目的で使用する。

- `let` 宣言の型チェック
- `ctx.req.*` / `ctx.res.*` / `hawk.app.*` の引数チェック (arity + arg type)
- `?=` の安全性向上 (Option/Result チェック)
- 将来の record / object method sugar の土台

---

## 実装スコープ (Phase 1–5)

| Phase | 内容 | 新規ファイル |
|-------|------|-------------|
| 1 | Function Signature Registry | `dsl/sig.awk` |
| 2 | Variable Symbol Table | `desugar_state.awk` 拡張、`desugar_let.awk` 拡張 |
| 3 | Array / Scalar / Map kind 区別 | 上記に追加 |
| 4 | Option / Result 型文字列 | `dsl/typecheck.awk` 追加 |
| 5 | `?=` 静的チェック + desugar | `desugar_let.awk` 拡張 |

---

## アーキテクチャ

### ファイル構成

```
dsl/desugar.awk            ← エントリ (変更あり: @include 追加)
dsl/desugar_state.awk      ← 共有状態 (変更あり: 新フィールド追加)
dsl/desugar_strings.awk    ← 文字列セグメント分割 (変更なし)
dsl/desugar_dot.awk        ← dot → dispatch 変換 (変更あり: typecheck 呼び出し)
dsl/desugar_let.awk        ← let 変換 (変更あり: symbol table + ?=)
dsl/desugar_nullcoalesce.awk ← ?? 変換 (変更なし)
dsl/sig.awk                ← NEW: _DS_SIG_* レジストリ
dsl/typecheck.awk          ← NEW: arity/arg/kind/option チェック
dsl/type.awk               ← ランタイム coerce (変更あり: _DS_TYPE_RETURNS 削除)
```

> **命名規則**: `desugar.awk` のみ `desugar_` プレフィックスを持つエントリファイル。新規追加ファイルはプレフィックスなし。既存ファイルのリネームは本スコープ外。

### 変換パイプライン (1 行ごと)

```
raw line
  → _ds_nc_transform        (nullcoalesce: ?? → ternary)
  → _ds_dot_transform       (dot → dispatch) + _ds_typecheck_call (NEW)
  → _ds_let_transform       (let → local, symbol table記録, ?= desugar)
  → print
```

---

## Phase 1: Function Signature Registry

### 新規ファイル: `dsl/sig.awk`

`dsl/type.awk` の `_DS_TYPE_RETURNS` を廃止し、3 つの配列に置き換える。

```awk
# _DS_SIG_RET[path]         : 関数の戻り型
# _DS_SIG_ARITY[path]       : 引数の個数
# _DS_SIG_ARG[path, index]  : 各引数の型 (1-origin)

BEGIN {
    # env.*
    _DS_SIG_RET["env.get"]       = "Str"
    _DS_SIG_ARITY["env.get"]     = 1
    _DS_SIG_ARG["env.get", 1]    = "Str"

    _DS_SIG_RET["env.set"]       = "Void"
    _DS_SIG_ARITY["env.set"]     = 2
    _DS_SIG_ARG["env.set", 1]    = "Str"
    _DS_SIG_ARG["env.set", 2]    = "Str"

    _DS_SIG_RET["env.del"]       = "Void"
    _DS_SIG_ARITY["env.del"]     = 1
    _DS_SIG_ARG["env.del", 1]    = "Str"

    _DS_SIG_RET["env.has"]       = "Bool"
    _DS_SIG_ARITY["env.has"]     = 1
    _DS_SIG_ARG["env.has", 1]    = "Str"

    # ctx.req.*
    _DS_SIG_RET["ctx.req.form"]      = "Str"
    _DS_SIG_ARITY["ctx.req.form"]    = 1
    _DS_SIG_ARG["ctx.req.form", 1]   = "Str"

    _DS_SIG_RET["ctx.req.query"]     = "Str"
    _DS_SIG_ARITY["ctx.req.query"]   = 1
    _DS_SIG_ARG["ctx.req.query", 1]  = "Str"

    _DS_SIG_RET["ctx.req.param"]     = "Str"
    _DS_SIG_ARITY["ctx.req.param"]   = 1
    _DS_SIG_ARG["ctx.req.param", 1]  = "Str"

    _DS_SIG_RET["ctx.req.header"]    = "Str"
    _DS_SIG_ARITY["ctx.req.header"]  = 1
    _DS_SIG_ARG["ctx.req.header", 1] = "Str"

    _DS_SIG_RET["ctx.req.body"]      = "Str"
    _DS_SIG_ARITY["ctx.req.body"]    = 0

    _DS_SIG_RET["ctx.req.json"]      = "Result<Map, Error>"
    _DS_SIG_ARITY["ctx.req.json"]    = 0

    # ctx.res.*
    _DS_SIG_RET["ctx.res.json"]      = "Response"
    _DS_SIG_ARITY["ctx.res.json"]    = 1
    _DS_SIG_ARG["ctx.res.json", 1]   = "Str"

    _DS_SIG_RET["ctx.res.text"]      = "Response"
    _DS_SIG_ARITY["ctx.res.text"]    = 1
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str"

    _DS_SIG_RET["ctx.res.html"]      = "Response"
    _DS_SIG_ARITY["ctx.res.html"]    = 1
    _DS_SIG_ARG["ctx.res.html", 1]   = "Str"

    _DS_SIG_RET["ctx.res.render"]    = "Response"
    _DS_SIG_ARITY["ctx.res.render"]  = 1
    _DS_SIG_ARG["ctx.res.render", 1] = "Str"

    _DS_SIG_RET["ctx.res.status"]    = "Response"
    _DS_SIG_ARITY["ctx.res.status"]  = 1
    _DS_SIG_ARG["ctx.res.status", 1] = "Int"

    _DS_SIG_RET["ctx.res.header"]    = "Response"
    _DS_SIG_ARITY["ctx.res.header"]  = 2
    _DS_SIG_ARG["ctx.res.header", 1] = "Str"
    _DS_SIG_ARG["ctx.res.header", 2] = "Str"

    _DS_SIG_RET["ctx.res.redirect"]  = "Response"
    _DS_SIG_ARITY["ctx.res.redirect"] = 1
    _DS_SIG_ARG["ctx.res.redirect", 1] = "Str"

    # hawk.app.*
    _DS_SIG_RET["hawk.app.get"]      = "Void"
    _DS_SIG_ARITY["hawk.app.get"]    = 2
    _DS_SIG_ARG["hawk.app.get", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.get", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.post"]     = "Void"
    _DS_SIG_ARITY["hawk.app.post"]   = 2
    _DS_SIG_ARG["hawk.app.post", 1]  = "Str"
    _DS_SIG_ARG["hawk.app.post", 2]  = "HandlerName"

    _DS_SIG_RET["hawk.app.put"]      = "Void"
    _DS_SIG_ARITY["hawk.app.put"]    = 2
    _DS_SIG_ARG["hawk.app.put", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.put", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.del"]      = "Void"
    _DS_SIG_ARITY["hawk.app.del"]    = 2
    _DS_SIG_ARG["hawk.app.del", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.del", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.patch"]    = "Void"
    _DS_SIG_ARITY["hawk.app.patch"]  = 2
    _DS_SIG_ARG["hawk.app.patch", 1] = "Str"
    _DS_SIG_ARG["hawk.app.patch", 2] = "HandlerName"

    _DS_SIG_RET["hawk.app.head"]     = "Void"
    _DS_SIG_ARITY["hawk.app.head"]   = 2
    _DS_SIG_ARG["hawk.app.head", 1]  = "Str"
    _DS_SIG_ARG["hawk.app.head", 2]  = "HandlerName"

    _DS_SIG_RET["hawk.app.on"]       = "Void"
    _DS_SIG_ARITY["hawk.app.on"]     = 2
    _DS_SIG_ARG["hawk.app.on", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.on", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.all"]      = "Void"
    _DS_SIG_ARITY["hawk.app.all"]    = 2
    _DS_SIG_ARG["hawk.app.all", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.all", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.listen"]   = "Void"
    _DS_SIG_ARITY["hawk.app.listen"] = 1
    _DS_SIG_ARG["hawk.app.listen", 1] = "Int"
}
```

### `type.awk` の変更

- `_DS_TYPE_RETURNS` の BEGIN ブロックを削除する。
- `_ds_infer_type` 内の `_DS_TYPE_RETURNS` 参照を `_DS_SIG_RET` に変更する。

---

## Phase 2: Variable Symbol Table

### `desugar_state.awk` の変更

`_DS_VAR_TYPES`、`_DS_VAR_KIND`、`_DS_current_lineno` を状態に追加する。

```awk
# _DS_VAR_TYPES[func_name, var_name] = "Int" | "Str" | "Array" | "Result<Map,Error>" | ...
# _DS_VAR_KIND[func_name, var_name]  = "scalar" | "array" | "option" | "result" | "response"
# _DS_current_lineno                 : 現在処理中の行番号 (typecheck で参照)

function _ds_init() {
    # ... 既存フィールド ...
    _DS_func_name      = ""    # 現在処理中の関数名を記録 (新規)
    _DS_current_lineno = 0     # typecheck が参照 (新規)
    delete _DS_VAR_TYPES
    delete _DS_VAR_KIND
}
```

`desugar.awk` の変更:

1. `_ds_process_line` の先頭で `_DS_current_lineno = lineno` を設定する。
2. `_ds_is_func_def` が真のブランチで、`_DS_func_name` を関数シグネチャから抽出する。

```awk
# desugar.awk の _ds_process_line 内、_ds_is_func_def が真のブランチ
if (_ds_is_func_def(line)) {
    _DS_in_function = 1
    _DS_func_sig    = line
    _DS_func_name   = _ds_extract_func_name(line)   # 追加
    # ...
}
```

`_ds_extract_func_name` は `desugar_let.awk` または `typecheck.awk` に追加する。

```awk
function _ds_extract_func_name(sig,    m) {
    if (match(sig, /^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, m))
        return m[1]
    return ""
}
```

### `desugar_let.awk` の変更

`let` パターンマッチ後に symbol table を記録する。

```awk
# let rows = [] → Array / array
_DS_VAR_TYPES[_DS_func_name, arr[2]] = "Array"
_DS_VAR_KIND[_DS_func_name, arr[2]]  = "array"

# let n: Int = ... → Int / scalar
_DS_VAR_TYPES[_DS_func_name, arr[2]] = arr[3]   # declared type
_DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(arr[3])

# let out: Str = "" → Str / scalar
_DS_VAR_TYPES[_DS_func_name, arr[2]] = arr[3]
_DS_VAR_KIND[_DS_func_name, arr[2]]  = "scalar"
```

`_ds_kind_of(typename)` は以下のルールで kind を返す。

```awk
function _ds_kind_of(t) {
    if (t == "Array" || t == "Map") return "array"
    if (t ~ /^Option</)             return "option"
    if (t ~ /^Result</)             return "result"
    if (t == "Response")            return "response"
    return "scalar"
}
```

---

## Phase 3: Array / Scalar / Map kind

Phase 2 の symbol table に kind が記録されているため、以下のチェックが可能になる。

- `let title: Str = "hello"` → kind=scalar
- その後 `title["id"] = "123"` → kind check で将来エラー化

Phase 3 では kind 記録のみ実装し、kind チェック (scalar への subscript アクセス検出) は Phase 3.1 として別途追加する。

### 初期型セット

```
Any           : 型未解決のワイルドカード
Void          : 戻り値なし
Int           : 整数 (kind: scalar)
Float         : 浮動小数 (kind: scalar)
Str           : 文字列 (kind: scalar)
Bool          : 真偽値 (kind: scalar)
Array         : awk 配列 (kind: array)
Map           : awk 連想配列 (kind: array)
Response      : ctx.res.* の戻り値 (kind: response)
HandlerName   : hawk.app.* route handler 名 (実体は Str だが意味的に区別)
Option<T>     : 失敗可能値 (kind: option)
Result<T, E>  : 成功/失敗値 (kind: result)
```

`Array` と `Map` は Phase 3 では区別せず、どちらも awk array として扱う。

---

## Phase 4: Option / Result 型文字列

パーサーは不要。文字列マッチで判定する。

```awk
function _ds_is_option(t) { return t ~ /^Option</ }
function _ds_is_result(t) { return t ~ /^Result</ }
function _ds_is_nullable(t) { return _ds_is_option(t) || _ds_is_result(t) }
```

`sig.awk` に以下を追加する。

```awk
_DS_SIG_RET["ctx.req.json"] = "Result<Map, Error>"
```

将来的に `ctx.req.form` を `Option<Str>` にする場合は sig.awk の登録を変更するだけでよい。

---

## Phase 5: `?=` 静的チェック + desugar

### 構文

```hawk
let body ?= ctx.req.json()
```

### 静的チェック

1. RHS の式の型を `_ds_infer_type` で取得する。
2. 型が `Option<...>` または `Result<...>` でなければエラーを出力する。

```
dsl error: app.awk:5: ?= requires Option or Result, got Str
```

### desugar 後のコード生成

```awk
# 生成前: let body ?= ctx.req.json()
_ds_tc_N = ctx::dispatch("req.json")
if (!result_ok(_ds_tc_N)) {
    return ctx::dispatch("res.status", 500)
}
body = result_val(_ds_tc_N)
```

`result_ok` と `result_val` はランタイム関数として `core/` に追加する (別タスク)。

`?=` で宣言された変数の kind は以下のように決定する。

- RHS が `Option<T>` → 変数の型は `T`、kind は `_ds_kind_of(T)`
- RHS が `Result<T, E>` → 変数の型は `T`、kind は `_ds_kind_of(T)`

### `desugar_let.awk` に追加するパターン

```awk
# let name ?= expr
if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\?=[[:space:]]*(.+)$/, arr)) {
    # 静的チェック
    rhs_type = _ds_infer_type(arr[3])
    if (!_ds_is_nullable(rhs_type) && rhs_type != "") {
        print "dsl error: " _DS_src_file ":" lineno \
            ": ?= requires Option or Result, got " rhs_type > "/dev/stderr"
        _DS_had_error = 1
    }
    # desugar
    return _ds_unwrap_transform(arr[1], arr[2], arr[3], rhs_type)
}
```

---

## 新規ファイル: `dsl/typecheck.awk`

arity チェックと arg type チェックを提供する。`desugar_dot.awk` の `_ds_dispatch_from` から呼ばれる。

`_ds_dispatch_from` は現在 `lineno` パラメータを持たない。代わりに `_DS_current_lineno` グローバルを参照する。`_ds_process_line` の先頭で毎回更新されるため、変換中は常に正しい行番号を指す。

> **制限**: `_ds_count_args` はトップレベルのカンマのみ数える。ネストした関数呼び出し (例: `hawk.app.get("/", func(a, b))`) でも正しくカウントされる (括弧の深さを追跡するため)。ただし、文字列内カンマや複雑なネストは将来対応とする。

```awk
# _ds_typecheck_call(path, args_str)
# path: "ctx.res.status" 等の dispatch パス
# args_str: 括弧内の引数文字列
# lineno: _DS_current_lineno から取得
function _ds_typecheck_call(path, args_str,    n, i, arg, expected, lineno) {
    lineno = _DS_current_lineno
    if (!(path in _DS_SIG_ARITY)) return   # 未知の関数はスキップ

    n = _ds_count_args(args_str)
    if (n != _DS_SIG_ARITY[path]) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " expects " _DS_SIG_ARITY[path] " argument(s), got " n > "/dev/stderr"
        _DS_had_error = 1
        return
    }

    # 各引数の型チェック
    split(args_str, _tc_args, ",")   # 簡易分割 (ネストは将来対応)
    for (i = 1; i <= n; i++) {
        if (!((path, i) in _DS_SIG_ARG)) continue
        expected = _DS_SIG_ARG[path, i]
        arg      = _ds_trim(_tc_args[i])
        _ds_typecheck_arg(path, i, expected, arg, lineno)
    }
}

function _ds_typecheck_arg(path, pos, expected, arg, lineno,    actual) {
    actual = _ds_infer_type(arg)
    if (actual == "" || actual == expected || actual == "Any") return
    # coercible literal は許容しない (設計決定: 文字列リテラルは常に Str)
    print "dsl error: " _DS_src_file ":" lineno \
        ": " path " argument " pos " expects " expected ", got " actual > "/dev/stderr"
    _DS_had_error = 1
}

function _ds_count_args(args_str,    n, depth, i, c, in_str) {
    if (_ds_trim(args_str) == "") return 0
    n = 1; depth = 0; in_str = 0
    for (i = 1; i <= length(args_str); i++) {
        c = substr(args_str, i, 1)
        if (in_str) {
            if (c == "\\" && i < length(args_str)) { i++; continue }
            if (c == "\"") in_str = 0
        } else {
            if (c == "\"")      in_str = 1
            else if (c == "(")  depth++
            else if (c == ")")  depth--
            else if (c == "," && depth == 0) n++
        }
    }
    return n
}
```

---

## エラーメッセージ形式

すべての dsl エラーは以下の形式で出力する。

```
dsl error: <filename>:<lineno>: <message>
```

### 具体例

```
dsl error: app.awk:10: ctx.res.status expects 1 argument(s), got 0
dsl error: app.awk:10: ctx.res.status argument 1 expects Int, got Str
dsl error: app.awk:5: ?= requires Option or Result, got Str
```

---

## テスト計画

新規追加すべきテストケース (`tests/unit/dsl/` 以下)。

| テストディレクトリ | 内容 |
|---|---|
| `sig_arity_ctx_status` | `ctx.res.status()` → arity error |
| `sig_arity_ctx_status_ok` | `ctx.res.status(200)` → 正常 desugar |
| `sig_type_ctx_status` | `ctx.res.status("ok")` → type error |
| `sig_type_hawk_route_path` | `hawk.app.get(200, "h")` → type error |
| `sig_type_hawk_route_handler` | `hawk.app.get("/", 123)` → type error |
| `var_symbol_basic` | `let n: Int = 1` → symbol table に記録 |
| `var_symbol_array` | `let rows = []` → kind=array |
| `option_unwrap_ok` | `let body ?= ctx.req.json()` → 正常 desugar |
| `option_unwrap_error` | `let title ?= ctx.req.form("x")` → ?= error (Str) |

---

## 変更ファイルまとめ

| ファイル | 変更種別 | 変更内容 |
|---|---|---|
| `dsl/sig.awk` | **新規** | `_DS_SIG_*` 全 DSL 関数登録 |
| `dsl/typecheck.awk` | **新規** | arity/arg チェック、`_ds_count_args` |
| `dsl/desugar.awk` | 変更 | `@include dsl/sig.awk`, `@include dsl/typecheck.awk` 追加 |
| `dsl/desugar_state.awk` | 変更 | `_DS_func_name`, `_DS_VAR_TYPES`, `_DS_VAR_KIND` 追加 |
| `dsl/desugar_dot.awk` | 変更 | `_ds_dispatch_from` に `_ds_typecheck_call` 呼び出し追加 |
| `dsl/desugar_let.awk` | 変更 | symbol table 記録、`?=` パターン追加、`_ds_kind_of` 追加 |
| `dsl/type.awk` | 変更 | `_DS_TYPE_RETURNS` 削除、`_ds_infer_type` を `_DS_SIG_RET` 参照に変更 |

---

## 実装順序

```
Step 1: sig.awk 作成 + type.awk の _DS_TYPE_RETURNS 移行
Step 2: typecheck.awk 作成 + desugar_dot.awk へのフック
Step 3: desugar_state.awk に _DS_func_name + _DS_VAR_* 追加
Step 4: desugar_let.awk で symbol table 記録 + _ds_kind_of
Step 5: desugar_let.awk に ?= パターン追加
Step 6: テスト追加
```

各 Step は独立してコミット可能。Step 1 完了後に既存テストがすべて通ることを確認してから次へ進む。
