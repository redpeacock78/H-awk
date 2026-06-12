# DSL Type System Refactor + Dispatch Commonalization Design

**Date:** 2026-06-12  
**Scope:** 3 improvements — (1) `core/type.awk` → `dsl/type.awk` with static type checking, (2) dispatch commonalization via route tables + generic router, (3) `let i: Type` bare declaration with typed assignment tracking

---

## 1. File Structure Changes

```
削除:  core/type.awk
新設:  dsl/type.awk            ← type::coerce + 型レジストリ (DSL専用)
新設:  core/dispatch.awk       ← hawk_dispatch::call 共通ルーター
修正:  hawk.awk                ← @include "core/type.awk" 削除
修正:  dsl/desugar.awk         ← @include "dsl/type.awk" 追加
修正:  core/env.awk            ← routes テーブル + hawk_dispatch::call へ委譲
修正:  core/hawk.awk           ← routes テーブル + hawk_dispatch::call へ委譲
修正:  dsl/desugar_state.awk   ← _DS_let_type_map 追加
修正:  dsl/desugar_let.awk     ← 静的チェック + 裸宣言 + 型付き代入変換
```

**分離原則:** `dsl/` には DSL プリプロセス専用のものだけを置く。`core/` は H-awk ランタイム（env, http, hawk フレームワーク）のみ。`type::coerce` はデシュガー出力から呼ばれるが DSL の概念なので `dsl/` に属する。

---

## 2. Dispatch 共通インフラ

### 2-1. `core/dispatch.awk` — 共通ルーター

```awk
# SPDX-License-Identifier: MIT
# core/dispatch.awk -- namespace dispatch 共通ルーター
@namespace "hawk_dispatch"

function call(ns, routes, path, a1, a2, a3) {
    if (!(path in routes)) {
        print ns "::dispatch: unknown path: " path > "/dev/stderr"
        return ""
    }
    return @routes[path](a1, a2, a3)
}

@namespace "awk"
```

gawk の `@funcname(args)` 間接呼び出しを使用。`routes[path]` には完全修飾関数名（例: `"env::get"`）を格納する。

### 2-2. `core/env.awk` — routes テーブル方式

```awk
@namespace "env"

BEGIN {
    _ENV_ROUTES["get"] = "env::get"
    _ENV_ROUTES["set"] = "env::set"
    _ENV_ROUTES["del"] = "env::del"
    _ENV_ROUTES["has"] = "env::has"
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("env", _ENV_ROUTES, path, a1, a2, a3)
}
```

既存の `get/set/del/has` 関数は変更不要。

### 2-3. `core/hawk.awk` — routes テーブル方式

```awk
@namespace "hawk"

BEGIN {
    _HAWK_ROUTES["app.get"]    = "hawk::get"
    _HAWK_ROUTES["app.post"]   = "hawk::post"
    _HAWK_ROUTES["app.put"]    = "hawk::put"
    _HAWK_ROUTES["app.del"]    = "hawk::del"
    _HAWK_ROUTES["app.patch"]  = "hawk::patch"
    _HAWK_ROUTES["app.head"]   = "hawk::head"
    _HAWK_ROUTES["app.on"]     = "hawk::on"
    _HAWK_ROUTES["app.all"]    = "hawk::all"
    _HAWK_ROUTES["app.listen"] = "hawk::listen"
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("hawk", _HAWK_ROUTES, path, a1, a2, a3)
}
```

### 2-4. 将来の namespace 追加パターン

新しい namespace `ctx` を追加する場合:

```awk
@namespace "ctx"

BEGIN {
    _CTX_ROUTES["req.form"]  = "ctx::req_form"
    _CTX_ROUTES["req.query"] = "ctx::req_query"
    # ...
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("ctx", _CTX_ROUTES, path, a1, a2, a3)
}
```

ボイラープレートは routes テーブルの定義のみ。`if-chain` の書き換えは不要。

### 2-5. `hawk.awk` の @include 順序

```awk
@include "core/dispatch.awk"   ← 新規追加 (最初に)
@include "core/env.awk"
@include "core/hawk.awk"
# @include "core/type.awk"     ← 削除
```

---

## 3. DSL 型システム

### 3-1. `dsl/type.awk` — 型モジュール

`core/type.awk` の内容をそのまま移動 + 型レジストリを追加:

```awk
# SPDX-License-Identifier: MIT
# dsl/type.awk -- DSL 型アノテーション用ランタイム変換 + 型レジストリ
@namespace "type"

# 既知の DSL 関数の戻り型 (デシュガー時参照用)
# キー: "namespace.method" 形式 (dot 記法のまま)
BEGIN {
    _TYPE_RETURNS["env.get"]       = "Str"
    _TYPE_RETURNS["ctx.req.form"]  = "Str"
    _TYPE_RETURNS["ctx.req.query"] = "Str"
    _TYPE_RETURNS["ctx.req.param"] = "Str"
    _TYPE_RETURNS["ctx.req.body"]  = "Str"
}

function coerce(val, typename) {
    # ... (既存実装と同じ)
}

@namespace "awk"
```

`_TYPE_RETURNS` はデシュガー時にのみ参照される。ランタイムでは使われない。

### 3-2. `@include` の整理

`dsl/type.awk` は2つの役割を持つ:
- **デシュガー時**: `_TYPE_RETURNS` レジストリを参照（静的チェック用）
- **ランタイム**: `type::coerce` を呼び出す（デシュガー出力から）

1ファイルを両方から `@include` することで両方の役割を果たす:

```awk
# dsl/desugar.awk に追加
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/desugar_let.awk"
@include "dsl/type.awk"    ← 追加 (_TYPE_RETURNS 参照用)
```

```awk
# hawk.awk の変更
# @include "core/type.awk"   ← 削除
@include "dsl/type.awk"      ← 追加 (type::coerce ランタイム用)
```

gawk は同じファイルを複数回 `@include` しても二重定義にならない（include guard 相当）。`desugar.awk` と `hawk.awk` の両方から `@include "dsl/type.awk"` しても問題なし。

### 3-3. デシュガー状態への追加 (`dsl/desugar_state.awk`)

```awk
function _ds_init() {
    # ...既存...
    delete _DS_let_type_map   ← 追加: 型付き変数の型を記録
}
```

`_DS_let_type_map` は `_DS_let_locals` と同様に関数スコープで管理。関数終了時にリセット。

### 3-4. `dsl/desugar_let.awk` の拡張

#### 3-4-1. 静的型チェック関数

```awk
# _ds_infer_type: 式の静的型を返す。不明なら "" を返す
function _ds_infer_type(expr,    m) {
    # 文字列リテラル
    if (expr ~ /^".*"$/) return "Str"
    # 整数リテラル
    if (expr ~ /^-?[0-9]+$/) return "Int"
    # 浮動小数リテラル
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    # Bool リテラル
    if (expr == "true" || expr == "false") return "Bool"
    # 既知の DSL 関数呼び出し: "ns.method(...)" パターン
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)\(/, m)) {
        key = m[1] "." m[2]
        if (key in _TYPE_RETURNS) return _TYPE_RETURNS[key]
    }
    return ""
}

# _ds_check_type: 型不一致ならエラーを出力して _DS_had_error をセット
function _ds_check_type(declared, inferred, lineno,    msg) {
    if (inferred == "" || inferred == declared) return
    msg = "type mismatch: cannot assign " inferred " to " declared
    print "dsl error: " _DS_src_file ":" lineno ": " msg > "/dev/stderr"
    _DS_had_error = 1
}
```

#### 3-4-2. `let` パターン拡張

`_ds_let_transform` に以下のパターンを追加・変更:

```
優先順位（高→低）:
1. let name = []         ← 既存 (配列初期化)
2. let name: Type = expr ← 既存 + 静的チェック追加
3. let name: Type        ← 新規 (裸宣言)
4. let name = expr       ← 既存
5. let name              ← 既存
```

**パターン 2 (型付き代入) の変更:**

```awk
if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]    ← 追加
    inferred = _ds_infer_type(arr[4])
    _ds_check_type(arr[3], inferred, lineno)  ← 追加
    # エラーがあっても続行 (複数エラーを一度に出力するため)
    # _DS_had_error == 1 なら END ブロックで exit 1 する
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
}
```

**パターン 3 (裸宣言) を新規追加:**

```awk
if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]    ← ホイストのみ、型を記録
    return ""
}
```

#### 3-4-3. 型付き代入の自動 coerce

`_ds_let_transform` の末尾（`return line` の前）に追加:

```awk
# 型付き変数への代入を coerce でラップ
# パターン: name = expr (name が _DS_let_type_map に登録済み)
if (match(line, /^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=([^=<>!~].*)$/, arr)) {
    varname = arr[2]
    if (varname in _DS_let_type_map) {
        rhs     = _ds_trim(arr[3])
        declared = _DS_let_type_map[varname]
        inferred = _ds_infer_type(rhs)
        _ds_check_type(declared, inferred, lineno)
        if (!_DS_had_error)
            return arr[1] varname " = type::coerce(" rhs ", \"" declared "\")"
    }
}
return line
```

代入の検出: `=[^=<>!~]` で `==`, `!=`, `<=`, `>=`, `=~`, `!~` と区別する。

### 3-5. 静的チェックのエラー例

```
dsl error: app.awk:12: type mismatch: cannot assign Str to Int
dsl error: app.awk:15: type mismatch: cannot assign Str to Int
```

エラーがあっても `_DS_had_error = 1` をセットして処理を続け（早期終了しない）、最後に `exit 1` することで複数エラーを一度に出力できる。

### 3-6. 型レジストリの管理

`_TYPE_RETURNS` は `dsl/type.awk` の `BEGIN` ブロックで定義。新しい DSL 関数の戻り型を追加する場合は `dsl/type.awk` の `BEGIN` ブロックに1行追加するだけ。ユーザー定義関数の戻り型追跡は今回のスコープ外。

---

## 4. テスト方針

既存の DSL テスト (`tests/unit/dsl/`) はすべてパスし続けること。

追加すべき fixture:

| テスト名 | 内容 |
|---|---|
| `type_bare_decl` | `let i: Int` 裸宣言 → ホイストのみ |
| `type_bare_assign` | 裸宣言後の `i = expr` → coerce 挿入 |
| `type_static_error_literal` | `let i: Int = "hello"` → デシュガーエラー |
| `type_static_error_known_func` | `let i: Int = ctx.req.form("x")` → デシュガーエラー |
| `dispatch_env_routes` | `env::dispatch` が routes テーブル経由で動作 |
| `dispatch_hawk_routes` | `hawk::dispatch` が routes テーブル経由で動作 |

エラー系テストは `expected.awk` の代わりに `expected_exit` (exit code) と `expected_stderr` ファイルで検証する（既存の `run.sh` を拡張するか、別の error fixture ランナーを用意する）。

---

## 5. 変更の非互換性

- `core/type.awk` を直接 `@include` しているコードは `dsl/type.awk` に変更が必要
- `hawk.awk` 経由でのみ使う場合は `hawk.awk` の修正だけで対応完了
- `env::dispatch` / `hawk::dispatch` の外部インターフェースは変わらない
- デシュガー出力の `type::coerce(...)` 呼び出しは変わらない（namespace は同じ）

---

## 6. 実装スコープ外

- ユーザー定義関数の戻り型推論
- 型キャスト演算子 (`as` キーワードなど)
- Null 型 / Optional 型
- 配列の型アノテーション (`let arr: Int[]`)
