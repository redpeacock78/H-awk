# Hawk DSL: Typed Dataflow Semantics — Design Spec

**Goal:** Track external inputs as `Result<Untrusted<T>, E>`, enforce validator/sanitizer/sink safety tiers, and add pipe (`|>`) and match expressions — all at desugar time with zero runtime overhead.

**Architecture:** One combined spec, phased implementation. New desugar transforms (`desugar_pipe.awk`, `desugar_match.awk`, `type_dataflow.awk`) added to the existing pipeline. Type checking remains compile-only — gawk output contains no type annotations.

**Tech Stack:** gawk DSL, existing `dsl/` desugar pipeline, `dsl/typecheck.awk`, `dsl/sig.awk`

---

## Phase Order

| Phase | Feature | New files |
|-------|---------|-----------|
| 1 | pipe operator (`\|>`) | `dsl/desugar_pipe.awk` |
| 2 | match expression + default | `dsl/desugar_match.awk` |
| 3 | Untrusted\<T\> + external input sig changes | `dsl/type_dataflow.awk` |
| 4 | Safe\<T\> + sanitizer/sink safety | (extend `type_dataflow.awk`) |
| 5 | `--dump-types` diagnostic flag | (extend desugar entry point) |

Processing order within desugar pipeline: `pipe_transform` → `dot_transform` → `nullcoalesce` → `let_transform`.

---

## Section 1: 型宇宙と関数分類

### 型宇宙

既存型に加え以下を追加:

- `Untrusted<T>` — 外部入力。検証前の値
- `Refined` サブタイプ群 — validator 経由でのみ生成: `NonEmptyStr`, `BoundedStr<N>`, etc.
- `Safe<T>` — sanitizer 経由でのみ生成: `Safe<HtmlStr>`, `Safe<JsonStr>`, `Safe<Str>`
- `ParseError`, `ValidationError` — エラー型

`BoundedStr<N>` は型名文字列として保持（`"BoundedStr<100>"`）。N の算術追跡なし。ワイルドカード `BoundedStr<*>` はシグネチャ内で任意 N にマッチ。

`Refined` と `Safe<T>` は直接代入・coerce 不可。constructor 経由（validator/sanitizer の戻り値）でのみ生成。

### 関数分類

関数定義に `classify:` アノテーションを追加:

```hawk
function trim(s: Str) -> Str {
  classify: transform
  ...
}
```

`classify: transform` を付けると、型チェッカーは宣言型 `Str` を `Untrusted<Str>` に自動昇格して扱う。ユーザーは内部型（`Str`）を書くだけでよい。gawk 出力には `classify:` も `Untrusted` も現れない。

| 分類 | 宣言シグネチャ | 型チェッカー上の扱い |
|------|-----------|----------------|
| `transform` | `(T) -> U` | `Untrusted<T> -> Untrusted<U>` として透過 |
| `validator` | `(Untrusted<T>) -> Result<Refined, E>` | `Untrusted` を明示 — 封印解除 |
| `sanitizer` | `(Refined) -> Safe<T>` | `Safe` 生成 |
| `sink` | `(Safe<T>) -> Response` | 終端 |

`classify:` なし関数: `Untrusted<T>` を引数に取れない（型エラー）。

シグネチャ情報は `_DS_FUNC_CLASS[name]` に格納（`sig.awk` 拡張）。

---

## Section 2: pipe 演算子 (`|>`)

### 構文

```hawk
expr |> f()
expr |> f(extra_arg)
expr |> f() |> g()
```

`expr |> f(args)` は `f(expr, args)` にデシュガー。チェーン可能。

### desugar ルール

```hawk
# DSL
let result = raw |> trim() |> non_empty()

# Desugared
_ds_p_1 = trim(raw)
_ds_p_2 = non_empty(_ds_p_1)
result = _ds_p_2
```

let 右辺・関数呼び出し引数・return 値など任意の式コンテキストで使用可能。

### Untrusted 伝播

pipe チェーン上の型追跡:

```hawk
raw          # Untrusted<Str>
raw |> trim() # transform → Untrusted<Str>（伝播）
raw |> trim() |> non_empty() # validator → Result<NonEmptyStr, ValidationError>（封印解除）
```

`transform` 以外の関数に `Untrusted<T>` を渡すとデシュガー時エラー:

```
dsl error: app.awk:8: escape_html argument 1 expects Refined, got Untrusted<Str>
```

Sealed ルール: `Result<T,E>` / `Option<T>` を pipe に渡せない。`?=` または `match` で unwrap 必須:

```
dsl error: app.awk:9: pipe input is Result<NonEmptyStr, ValidationError> — use ?= or match first
```

### 新規ファイル: `dsl/desugar_pipe.awk`

- 行内の `|>` を左から右に再帰展開
- 中間値 `_ds_p_N` を生成（`_DS_pipe_counter` でカウント）
- 型追跡は `type_dataflow.awk` に委譲

---

## Section 3: match 式

### 構文

Result/Option の exhaustive パターンマッチ。

```hawk
# Result — 両腕明示
match expr of
  ok raw:
    ...
  ng err:
    ...
end

# Result — default catch-all（Rust の _ =>）
match expr of
  ok raw:
    ...
  default:
    return ctx.res.status(500)
end

# Option — 両腕明示
match expr of
  some val:
    ...
  none:
    ...
end

# Option — default catch-all
match expr of
  some val:
    ...
  default:
    return ctx.res.status(404)
end
```

### desugar ルール

```hawk
# Result + default
match ctx.req.json() of
  ok body:
    ...
  default:
    return ctx.res.status(400)
end

# Desugared
_ds_mc_1 = ctx::dispatch("req.json")
if (result_ok(_ds_mc_1)) {
  body = result_val(_ds_mc_1)
  ...
} else {
  return ctx::dispatch("res.status", 400)
}
```

`ng err:` → `else { err = result_err(_ds_mc_1); ... }`  
`none:` → `else { ... }`（束縛なし）  
`default:` → `else { ... }`（束縛なし、ng/none と同等）

### Exhaustiveness ルール

- Result: `ok` + (`ng` | `default`) 必須
- Option: `some` + (`none` | `default`) 必須
- `default` 単独は不可
- 不足するとデシュガー時エラー:

```
dsl error: app.awk:5: match on Result<...> missing ng or default branch
```

### 新規ファイル: `dsl/desugar_match.awk`

- `match...of...end` ブロックを検出・展開
- `expr` の型を `_ds_infer_type` で解決して Result/Option を判定
- 中間変数 `_ds_mc_N` を生成

---

## Section 4: Untrusted\<T\> と外部入力

### ctx.req.* sig 変更

全 `ctx.req.*` の戻り型を `Result<Untrusted<T>, ParseError>` に変更（breaking change）。

| DSL | 旧型 | 新型 |
|-----|------|------|
| `ctx.req.form(key)` | `Str` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.query(key)` | `Str` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `Str` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `Str` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `Result<Map, Error>` | `Result<Untrusted<Map>, ParseError>` |
| `ctx.req.body()` | `Str` | `Result<Untrusted<Str>, ParseError>` |

既存の `app.awk` は同時更新（hard migration）。

### Untrusted 伝播ルール

`transform` 分類関数: `Untrusted<T>` 入力 → `Untrusted<U>` 出力（透過）。

```hawk
let raw ?= ctx.req.form("title")   # Untrusted<Str>
let t   = raw |> trim()            # Untrusted<Str>（transform → 伝播）
let v  ?= t   |> non_empty()      # NonEmptyStr（validator → 封印解除）
```

`classify` なし関数に `Untrusted<T>` を渡すとエラー。

### 新規ファイル: `dsl/type_dataflow.awk`

- `_ds_is_untrusted(t)` — `Untrusted<...>` 判定
- `_ds_untrusted_inner(t)` — `Untrusted<Str>` → `Str`
- `_ds_propagate_untrusted(func, input_type)` — 分類に応じて出力型を決定
- `_DS_FUNC_CLASS[name]` 参照

---

## Section 5: Safe\<T\> と sink safety

### sanitizer → Safe\<T\>

```hawk
function escape_html(s: NonEmptyStr) -> Safe<HtmlStr> {
  classify: sanitizer
}

let title ?= raw |> non_empty()           # NonEmptyStr
let safe  = title |> escape_html()        # Safe<HtmlStr>
```

`Safe<T>` は sanitizer 戻り値のみ生成。直接代入・coerce 不可:

```
dsl error: app.awk:10: Safe<HtmlStr> cannot be constructed directly — use a sanitizer
```

### sink — Safe\<T\> のみ受け付ける

| DSL | 引数型 |
|-----|--------|
| `ctx.res.html(data)` | `Safe<HtmlStr>` |
| `ctx.res.json(data)` | `Safe<JsonStr>` |
| `ctx.res.text(data)` | `Safe<Str>` |

```hawk
ctx.res.html(safe)   # OK
ctx.res.html(title)  # ERROR: NonEmptyStr は Safe でない
ctx.res.html(raw)    # ERROR: Untrusted<Str>
```

エラー例:

```
dsl error: app.awk:12: ctx.res.html argument 1 expects Safe<HtmlStr>, got NonEmptyStr
dsl error: app.awk:13: ctx.res.html argument 1 expects Safe<HtmlStr>, got Untrusted<Str>
```

### 完全なデータフロー

```
ctx.req.form("title")         → Result<Untrusted<Str>, ParseError>
  ?=                          → Untrusted<Str>
  |> trim()      [transform]  → Untrusted<Str>
  |> non_empty() [validator]  → Result<NonEmptyStr, ValidationError>
  ?=                          → NonEmptyStr
  |> escape_html()[sanitizer] → Safe<HtmlStr>
  ctx.res.html(...)  [sink]   → Response
```

型チェックはすべてデシュガー時のみ。実行時オーバーヘッドなし。

---

## 移行ガイド (`app.awk` breaking change)

Phase 3 で `ctx.req.*` の型が変わるため、既存コードは以下のパターンで更新:

```hawk
# Before
let title: Str = ctx.req.form("title")

# After
let raw ?= ctx.req.form("title")   # Untrusted<Str>
# ... validate/sanitize chain
```

`ctx.req.param` は URL ルーティング済みパラメータのため信頼度が高いが、型上は `Untrusted<Str>` のまま（明示的 validate を要求）。
