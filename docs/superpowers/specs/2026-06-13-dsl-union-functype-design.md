# Hawk DSL: Union型 + 関数返り値型アノテーション 設計仕様書

**作成日**: 2026-06-13  
**スコープ**: Phase A–D (Union基盤 → ??推論 → 関数アノテーション → return/call check)  
**対象ブランチ**: master

---

## 目的

Hawk DSL の型システムに以下の2機能を追加する。

1. **Union 型**: `Int | Str`、`Response | Result<Response, Error>` のような複合型を `let` / 関数引数 / 関数返り値 / built-in signature で使用可能にする
2. **関数返り値型アノテーション**: `function name(...) -> Type { ... }` 構文で、引数・返り値に静的型チェックを追加する

基本方針:

```
型を書かない: awk的にゆるく動く
型を書く:    desugar時にチェックされる
型がUnion:   許容される型候補のいずれかとして扱う
実行:        変換後はplain gawk（型情報はgawk出力に含まれない）
```

---

## 型宇宙

```
Primitive:  Int, Float, Str, Bool
Semantic:   HandlerName, RoutePath, Port, NumericStr, Response
Container:  Array, Map
Flow:       Option<T>, Result<T, E>
Meta:       Void, Any
Composite:  A | B  (Union)
```

### Semantic 型

| 型名 | 意味 |
|------|------|
| `HandlerName` | ルートハンドラ名として使える文字列 |
| `RoutePath`   | `/todos` などのルートパス |
| `Port`        | listen可能なポート値 (alias: `Int\|NumericStr\|Str`) |
| `NumericStr`  | `"8080"` のような数値文字列 |
| `Response`    | HTTPレスポンス |

---

## Union 型の仕様

### 構文

```hawk
Int | Str
Str | NumericStr
Response | Result<Response, Error>
Option<Str> | Result<Str, Error>
```

### 内部表現

正規化後は **スペースなし** の文字列で管理する。

```
"Int | Str"  ->  "Int|Str"
"Str | Int"  ->  "Int|Str"  (ソート済)
```

### 正規化ルール

1. top-level の `|` で split（`<...>` 内は split しない）
2. 各型を trim
3. alias を展開
4. 重複を削除
5. 安定順（アルファベット順）で join

#### top-level split の例

```
"Result<Str | Int, Error> | Option<Str>"
  -> ["Result<Str | Int, Error>", "Option<Str>"]  (top-levelのみ)

"Result<Str | Int, Error>"
  -> ["Result<Str | Int, Error>"]  (1型)
```

### 型エイリアス (`sig.awk` の BEGIN に追加)

```awk
_DS_TYPE_ALIAS["Port"] = "Int|NumericStr|Str"
```

### 型受理ルール (`type_accepts(expected, actual)`)

```
expected == actual          -> OK
expected == "Any"           -> OK
actual   == "Any"           -> OK
expected が alias           -> 展開して再帰
actual   が alias           -> 展開して再帰
expected が union           -> memberのどれかがactualを受理 -> OK
actual   が union           -> actualの全memberがexpectedに受理される -> OK
その他                      -> Error
```

#### 例

```
expected: "Int|Str",  actual: "Int"     -> OK
expected: "Int|Str",  actual: "Bool"    -> Error
expected: "Port",     actual: "Str|Int" -> OK  (Port = Int|NumericStr|Str が Str,Int 両方受理)
expected: "Int",      actual: "Int|Str" -> Error  (Str が Int に入れられない)
```

---

## Literal 型推論の拡張

`_ds_infer_type` に `NumericStr` 推論を追加する。

```awk
# 変更後
if (expr ~ /^"[0-9]+"$/) return "NumericStr"  # "8080" -> NumericStr
if (expr ~ /^".*"$/)     return "Str"          # "hello" -> Str
```

---

## `??` の型推論を union 化

現在: `??` を含む式は推論不可 (`""`) を返す。  
変更後: 左辺・右辺を個別推論し、union 化する。

```awk
if (match(expr, /^(.+)\?\?(.+)$/, m)) {
    ltype = _ds_infer_type(_ds_trim(m[1]))
    rtype = _ds_infer_type(_ds_trim(m[2]))
    return type_union(ltype, rtype)
}
```

#### 結果例

```hawk
hawk.app.listen(env.get("PORT") ?? 8080)
```

```
env.get("PORT") -> Str
8080            -> Int
??              -> "Str|Int"
listen expects  -> Port (= "Int|NumericStr|Str")
type_accepts("Port", "Str|Int")
  -> Port展開: "Int|NumericStr|Str"
  -> actual union全member: Str ∈ Port ✓, Int ∈ Port ✓
  -> OK
```

---

## 関数アノテーション構文

### サポートする構文

```hawk
function f()
function f(a)
function f(a, b)
function f(a: Int)
function f(a: Int, b: Str)
function f(a, b: Str)
function f(a: Int | Str) -> Response
function f(a: Result<Map, Error>) -> Response
function f(a: Int, b) -> Str
```

引数型・返り値型はいずれも省略可能。省略時は `Any` として扱う。

### desugar 出力

```hawk
function hello(name: Str) -> Response {
  return ctx.res.text("hello")
}
```

↓

```awk
function hello(name) {
  return ctx::dispatch("res.text", "hello")
}
```

型情報はgawk出力に含まれない。desugar中のみ保持する。

---

## 2パス処理

現在の single-pass 処理を拡張し、ユーザー定義関数の前方参照に対応する。

### Pass 1: sig 収集

`desugar.awk` の `BEGIN` ブロックで入力ファイルを `getline` ループし、関数定義行を検出してsignatureを登録する。

```
function normalize(text: Str) -> Str {
  -> _DS_SIG_ARG["normalize", 1] = "Str"
  -> _DS_SIG_ARITY["normalize"]  = 1
  -> _DS_SIG_RET["normalize"]    = "Str"

function echo(x) {
  -> _DS_SIG_ARG["echo", 1]    = "Any"
  -> _DS_SIG_ARITY["echo"]     = 1
  -> _DS_SIG_RET["echo"]       = "Any"
```

ユーザー定義関数も built-in と同じ `_DS_SIG_*` テーブルに登録する。  
DSL path（`ctx.res.text`）との衝突は起きない（ユーザー関数名には `.` が入らない）。

### Pass 2: 通常 desugar + 型チェック

既存フローに加えて、Pass 1 のsig情報をもとに型チェックを行う。

---

## 関数定義のパース拡張

### `_ds_is_func_def` の正規表現拡張

```awk
# 現在: -> なし
/^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*\{/

# 変更後: -> ReturnType を許容
/^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(.*\)[[:space:]]*(->.*)?[[:space:]]*\{/
```

### 引数パース (`_ds_parse_func_params`)

`a: Int | Str, b: Result<Map, Error>` のような型付き引数リストを:
- gawk用の引数名リスト `a, b` に変換
- 各引数の型を `_DS_SIG_ARG` に登録

`|` の split は `<...>` の深さを考慮して行う（generic内は分割しない）。

---

## return type check

Pass 2 中、`_DS_func_ret_type` に現在処理中の関数の返り値型を保持する。`return` 行を検出したらチェックする。

```
return expr が検出されたとき:
  actual = _ds_infer_type(expr)
  if actual != "" && _DS_func_ret_type != "" && _DS_func_ret_type != "Any":
    if !type_accepts(_DS_func_ret_type, actual): error

Void チェック:
  _DS_func_ret_type == "Void" かつ return expr -> error
  _DS_func_ret_type == "Void" かつ return; -> OK

return が存在しない場合:
  ReturnType が Void 以外なら warning (MVPでは warning レベル)
```

**制約**: 制御フロー解析なし。関数内の全 `return` を独立にチェックする。

---

## ユーザー定義関数 call check

単純関数呼び出し `f(args)` に対しても、built-in と同様に `_ds_typecheck_call` を適用する。

Pass 1 でsig登録済のため、前方参照でも正しくチェックできる。

```hawk
function normalize(s: Str) -> Str { return trim(s) }

normalize(123)  # error: normalize argument 1 expects Str, got Int
normalize(ctx.req.form("title"))  # OK
```

---

## `let` の Union 型アノテーション対応

現在の型パターン `[A-Z][a-zA-Z0-9]*` を拡張し、`Int | Str` や `Result<Map, Error>` を許容する。

型部分のキャプチャ: `=` の直前までを型として取り出し、`type_normalize` を通す。

```hawk
let port: Int | Str = env.get("PORT") ?? 8080
```

---

## `?=` と Union 型

`?=` は `Option<T>` または `Result<T, E>` を unwrap するため、Union型との関係は以下のとおり。

```
?= RHS が単一の Option<T> or Result<T,E>:
  OK (既存動作)

?= RHS が union (全memberがOption or Result):
  OK. unwrap後の型をunion化する
  例: Option<Str> | Result<Int, Error> -> "Str|Int"

それ以外:
  error: ?= requires Option or Result, got <type>
```

---

## ファイル変更一覧

| ファイル | 変更内容 |
|----------|----------|
| `dsl/type.awk` | `type_is_union`, `type_split_union`, `type_normalize`, `type_union`, `type_expand_alias`, `type_accepts` を追加 |
| `dsl/sig.awk` | `_DS_TYPE_ALIAS` テーブル追加、`hawk.app.listen` の arg 型を `Port` に変更 |
| `dsl/typecheck.awk` | `type_accepts` を使うよう `_ds_typecheck_call` を更新、return check 追加 |
| `dsl/desugar_let.awk` | `_ds_infer_type` に NumericStr 推論追加、`??` union 推論追加、Union型アノテーション対応 |
| `dsl/desugar.awk` | `_ds_is_func_def` 正規表現拡張、2パス処理（BEGIN での sig 収集）追加、`_ds_parse_func_params` 追加 |

---

## テストケース

### Phase A: Union 基盤

- `union_let_basic_ok` — `let x: Int | Str = 42`
- `union_let_basic_error` — `let x: Int | Str = true`
- `union_numericstr_ok` — `let x: NumericStr = "8080"`
- `union_alias_port_ok` — `hawk.app.listen(8080)`
- `union_alias_port_bad_literal` — `hawk.app.listen("hello")` (error)
- `union_actual_all_members_reject` — expected `Int`, actual `Int|Str` -> error
- `union_generic_top_level_split` — `Result<Str | Int, Error>` は1型として扱う

### Phase B: ?? + literal inference

- `union_nullcoalesce_str_int` — `env.get("PORT") ?? 8080` -> `Str|Int`
- `union_listen_nullcoalesce_ok` — `hawk.app.listen(env.get("PORT") ?? 8080)` OK

### Phase C: 関数アノテーション

- `func_arg_type_ok` — 型付き引数に正しい型を渡す
- `func_arg_type_error` — 型付き引数に誤った型を渡す
- `func_arg_union_ok` — `f(a: Int | Str)` に Int を渡す
- `func_arg_optional_any` — 型なし引数は何でも受理
- `func_signature_desugar` — 型アノテーションがgawk出力に含まれないこと
- `func_user_call_arity_error` — arity不一致エラー
- `func_user_call_type_error` — 型不一致エラー

### Phase D: return / call check

- `func_return_type_ok` — 返り値型と一致するreturn
- `func_return_type_error` — 返り値型と不一致のreturn
- `func_return_union_ok` — `-> Int | Error` に Int を返す
- `func_return_void_error` — `-> Void` で return expr -> error

### ?= + Union

- `unwrap_union_option_result_ok` — `Option<Str> | Result<Str, Error>` を ?= で unwrap
- `unwrap_union_non_unwrap_error` — Str を ?= -> error
- `unwrap_union_result_type` — unwrap後の型がunion化されること

---

## スコープ外 (MVP)

- `match` による type narrowing（Union実装後の将来課題）
- exhaustiveness check
- 完全な制御フロー解析（全 `return` パスの網羅チェック）
- `None` 型（nullable は `Option<T>` に寄せる方向）
