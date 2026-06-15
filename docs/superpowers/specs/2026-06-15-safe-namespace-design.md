# Hawk DSL: safe.* 名前空間統一 + Ruby風 #{...} 文字列 interpolation 設計

**日付:** 2026-06-15
**PR名:** `feat(dsl): add safe namespace and string interpolation`
**ステータス:** 承認済み

---

## 1. 目的

1. Safe / Brand 型を生成する関数を `safe.*` 名前空間に集約する
2. `escape_html` / `html_raw` トップレベル関数を廃止する
3. sanitizer / trusted raw / builder の違いを名前空間で明確にする
4. `"hello #{name}"` のような interpolation を導入する
5. interpolation による Untrusted ロンダリングを禁止する
6. HTML safe fragment 生成の足場を作る

---

## 2. 廃止

以下のトップレベル関数を廃止する（移行期間なし）:

- `escape_html(...)` → `safe.html.escape(...)` へ移行
- `html_raw(...)` → `safe.html.raw(...)` へ移行

`sig.awk` からエントリを削除することで、呼び出し時に `dsl error: unknown function escape_html` が自動的に出る。

---

## 3. safe.* 名前空間

### 型意味論

| 関数 | classify | 入力 | 出力 |
|---|---|---|---|
| `safe.html.escape` | sanitizer | `Str \| Untrusted<Str>` | `HtmlEscapedStr` |
| `safe.html.raw` | trusted | `Str` | `HtmlFragment` |
| `safe.html.fragment` | builder | `HtmlPart...` (最大3) | `HtmlFragment` |
| `safe.attr.escape` | sanitizer | `Str \| Untrusted<Str>` | `HtmlAttrEscapedStr` |

### DSL記法

```hawk
safe.html.escape(title)
safe.html.raw(out)
safe.html.fragment("<p>", title |> safe.html.escape(), "</p>")
safe.attr.escape(id)
```

### Desugar後

dot-notation desugar により:

```awk
safe::dispatch("html.escape", title)
safe::dispatch("html.raw", out)
safe::dispatch("html.fragment", "<p>", safe::dispatch("html.escape", title), "</p>")
safe::dispatch("attr.escape", id)
```

### safe.html.fragment の引数規則

- 許可: `LiteralStr`（静的文字列リテラル）、`HtmlEscapedStr`、`HtmlFragment`、`HtmlAttrEscapedStr`
- 禁止: dynamic `Str`、`Untrusted<*>`、`Result<*>`、`Option<*>`

`safe.html.fragment` の引数に渡される文字列リテラルは trusted static HTML chunk として許可する。実装上は `_ds_infer_type` が文字列リテラルに対して `"LiteralStr"` を返すのではなく、`safe.html.fragment` の引数型検査時のみ文字列リテラルを特例許可する判定を `desugar_dot.awk` に追加する（型システム全体に `LiteralStr` を導入するより実装コストが低い）。

---

## 4. 型追加・変更

### sig.awk への追加

```awk
_DS_TYPE_ALIAS["HtmlPart"] = "HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr"

_DS_SIG_ARG["safe.html.escape", 1]   = "Str|Untrusted<Str>"
_DS_SIG_RET["safe.html.escape"]      = "HtmlEscapedStr"
_DS_FUNC_CLASS["safe.html.escape"]   = "sanitizer"
_DS_SIG_TRUSTED["safe.html.escape"]  = 1

_DS_SIG_ARG["safe.attr.escape", 1]   = "Str|Untrusted<Str>"
_DS_SIG_RET["safe.attr.escape"]      = "HtmlAttrEscapedStr"
_DS_FUNC_CLASS["safe.attr.escape"]   = "sanitizer"
_DS_SIG_TRUSTED["safe.attr.escape"]  = 1

_DS_SIG_ARG["safe.html.raw", 1]      = "Str"
_DS_SIG_RET["safe.html.raw"]         = "HtmlFragment"
_DS_FUNC_CLASS["safe.html.raw"]      = "trusted"
_DS_SIG_TRUSTED["safe.html.raw"]     = 1

_DS_SIG_ARG["safe.html.fragment", 1] = "HtmlPart"
_DS_SIG_ARG["safe.html.fragment", 2] = "HtmlPart"
_DS_SIG_ARG["safe.html.fragment", 3] = "HtmlPart"
_DS_SIG_RET["safe.html.fragment"]    = "HtmlFragment"
_DS_FUNC_CLASS["safe.html.fragment"] = "builder"
_DS_SIG_TRUSTED["safe.html.fragment"]= 1
```

### ctx.res シグネチャ（確認）

すでに正しいが明示:

```awk
_DS_SIG_ARG["ctx.res.html", 1]  = "HtmlEscapedStr|HtmlFragment"
_DS_SIG_ARG["ctx.res.text", 1]  = "Str|Untrusted<Str>"
```

### 廃止

`sig.awk` から削除:

```awk
# 削除
_DS_SIG_RET["escape_html"]    = "HtmlEscapedStr"
_DS_SIG_ARG["escape_html", 1] = "Str|Untrusted<Str>"
_DS_FUNC_CLASS["escape_html"] = "sanitizer"
_DS_SIG_TRUSTED["escape_html"]= 1

_DS_SIG_RET["html_raw"]       = "HtmlEscapedStr"
_DS_SIG_ARG["html_raw", 1]    = "Str"
_DS_SIG_TRUSTED["html_raw"]   = 1
```

---

## 5. Ruby風 #{...} 文字列 interpolation

### 構文

double-quoted 文字列内のみ対象（single-quoted は対象外）。

```hawk
let msg = "hello #{name}"
let msg = "todo #{id}: #{title}"
```

`#{...}` 内では単純な式と pipe 式を許可:

- `"#{name}"` ✓
- `"#{title |> safe.html.escape()}"` ✓
- `"#{foo(bar())}"` ✓（複雑な呼び出しも許可）
- `"#{match x of ... end}"` ✗（match 式は禁止）

### Desugar 出力

`sprintf` で明示連結（ユーザー承認済み）:

```awk
# input
let msg = "hello #{name}!"
# output
msg = sprintf("%s%s%s", "hello ", name, "!")
```

### 型規則

1. **通常 interpolation** — 結果型は `Str`。ただし式に `Untrusted<T>` が含まれる場合は `Untrusted<Str>`。
2. **Result/Option は interpolation 不可** — `?=` または `match` で unwrap してから使う。
3. **interpolation は Untrusted を剥がさない** — `#{raw}` により raw の Untrusted が消えることはない。

```hawk
let raw ?= ctx.req.form("title")
let msg = "title: #{raw}"
# msg : Untrusted<Str>

let title = ctx.req.form("title")    # Result<Untrusted<Str>, ParseError>
let msg = "title: #{title}"          # ERROR: cannot interpolate sealed Result<...>
```

### safe.html.fragment 内 interpolation

`safe.html.fragment("...")` の文字列引数に interpolation が含まれる場合、
`context = "html.fragment"` として型検査する:

- 式の型が `HtmlEscapedStr | HtmlFragment | HtmlAttrEscapedStr` であること
- リテラル文字列部分は `LiteralStr` として許可

```hawk
# OK
safe.html.fragment("<p>#{title |> safe.html.escape()}</p>")

# ERROR: safe.html.fragment interpolation expects HtmlPart, got Untrusted<Str>
safe.html.fragment("<p>#{title}</p>")
```

desugar後:

```awk
safe::dispatch("html.fragment", "<p>", safe::dispatch("html.escape", title), "</p>")
```

**自動 escape は行わない。** 明示的な `safe.html.escape()` / `safe.attr.escape()` が必要。

### 隣接文字列リテラルとの関係

既存の adjacent string folding と interpolation は別パス。処理順:

1. adjacent string literal 折り畳み
2. interpolation 展開（sprintf 変換）
3. pipe / dot / let desugar
4. typecheck

---

## 6. 実装アーキテクチャ

### 変更ファイル

| ファイル | 変更 |
|---|---|
| `core/safe.awk` | **新規** — runtime `safe::` namespace |
| `hawk.awk` | `@include "core/safe.awk"` 追加 |
| `dsl/sig.awk` | `escape_html`/`html_raw` 削除、`safe.*` sig 追加、`HtmlPart` alias |
| `dsl/desugar_strings.awk` | `_ds_expand_interp(line, context, lineno)` 追加 |
| `dsl/desugar.awk` | interpolation 展開を pipeline に組み込む |
| `dsl/desugar_dot.awk` | `safe.html.fragment` 引数の HtmlPart 型検査 |
| `app.awk` | `escape_html` → `safe.html.escape`、`html_raw` → `safe.html.raw` |
| `tests/unit/dsl/safe_escape_html_ok/` | input を `safe.html.escape` に更新 |
| `tests/unit/dsl/safe_*/` | 新規テスト追加 |
| `README.md` | Safe HTML / classify 説明更新 |

### 処理パイプライン

```
input.awk
  → Pass 1: function sig 収集
  → _ds_process_line per line:
      1. adjacent string fold       (既存: desugar_strings.awk)
      2. interpolation expand       (新規: _ds_expand_interp)
      3. pipe desugar               (既存: desugar_pipe.awk)
      4. dot desugar + 型検査       (既存+拡張: desugar_dot.awk)
      5. nullcoalesce desugar       (既存)
      6. return type check          (既存)
      7. let transform              (既存)
```

### core/safe.awk の構造

```awk
@namespace "safe"
BEGIN {
    _SAFE_ROUTES["html.escape"]   = "safe::html_escape"
    _SAFE_ROUTES["html.raw"]      = "safe::html_raw"
    _SAFE_ROUTES["html.fragment"] = "safe::html_fragment"
    _SAFE_ROUTES["attr.escape"]   = "safe::attr_escape"
    _SAFE_ARITY["html.escape"]    = 1
    _SAFE_ARITY["html.raw"]       = 1
    _SAFE_ARITY["html.fragment"]  = 3
    _SAFE_ARITY["attr.escape"]    = 1
}
function html_escape(s)        { /* 5 gsub */ ; return s }
function attr_escape(s)        { /* 5 gsub */ ; return s }
function html_raw(s)           { return s }
function html_fragment(a,b,c)  { return a b c }
function dispatch(path,a1,a2,a3) { return hawk_dispatch::call(...) }
@namespace "awk"
```

### _ds_expand_interp の動作

```
1. _ds_split_code_segs で文字列セグメントを列挙
2. 文字列リテラル内を走査して "#{" を検出
3. brace depth で対応する "}" を特定
4. 式部分を抽出し _ds_pipe_transform を適用
5. context="normal":
   - Result/Option 型 → error
   - Untrusted<T> 型 → 結果型を Untrusted<Str> に昇格
6. context="html.fragment":
   - 型が HtmlPart でなければ error
   - リテラル部分は LiteralStr として引数化
7. sprintf("%s%s%s", ...) に組み立て
```

---

## 7. エラーメッセージ

| シナリオ | エラー |
|---|---|
| `escape_html(x)` | `dsl error: ...: unknown function escape_html` |
| `html_raw(x)` | `dsl error: ...: unknown function html_raw` |
| `ctx.res.html(Untrusted<Str>)` | 既存の型チェックで対応 |
| `"#{result_val}"` (Result) | `cannot interpolate sealed Result<...>; use ?= or match first` |
| `safe.html.fragment("#{raw}")` (Untrusted) | `safe.html.fragment interpolation expects HtmlPart, got Untrusted<Str>` + `help: use safe.html.escape()` |
| `safe.html.fragment(dynStr)` | `safe.html.fragment arg 1 expects HtmlPart, got Str` |

---

## 8. テスト計画

### 新規テスト

**safe namespace:**
- `safe_namespace_escape_ok`
- `safe_namespace_raw_ok`
- `safe_namespace_attr_escape_ok`
- `safe_namespace_old_escape_unknown_error`
- `safe_namespace_old_raw_unknown_error`
- `safe_namespace_html_sink_untrusted_error`
- `safe_namespace_html_sink_escape_ok`

**interpolation:**
- `string_interpolation_basic`
- `string_interpolation_multiple`
- `string_interpolation_with_pipe`
- `string_interpolation_untrusted_propagates`
- `string_interpolation_result_error`
- `string_interpolation_option_error`

**safe fragment interpolation:**
- `safe_fragment_interpolation_escape_ok`
- `safe_fragment_interpolation_raw_untrusted_error`
- `safe_fragment_interpolation_attr_escape_ok`

### 既存テスト更新

- `safe_escape_html_ok/input.awk` — `escape_html` → `safe.html.escape` に書き換え

---

## 9. app.awk 移行

### Before

```awk
return ctx.res.html(html_raw(out))
return ctx.res.html(html_raw(_todo_tr(...)))
sprintf("...%s...", escape_html(title), escape_html(id))
```

### After

```awk
return out |> safe.html.raw() |> ctx.res.html()
return _todo_tr(...) |> safe.html.raw() |> ctx.res.html()
# _todo_tr は safe.html.raw(sprintf(..., safe.html.escape(title), safe.attr.escape(id))) を返す
```

---

## 10. 受け入れ条件

1. `escape_html` が使えない（型エラー）
2. `html_raw` が使えない（型エラー）
3. `safe.html.escape` が `HtmlEscapedStr` を返す
4. `safe.html.raw` が `HtmlFragment` を返す
5. `safe.attr.escape` が `HtmlAttrEscapedStr` を返す
6. `ctx.res.html` は `HtmlEscapedStr | HtmlFragment` だけ受け取る
7. `ctx.res.text` は `Str | Untrusted<Str>` を受け取る
8. `"hello #{name}"` が `sprintf(...)` に desugar される
9. interpolation 内の `Untrusted<T>` が結果型 `Untrusted<Str>` に伝播する
10. interpolation 内の `Result` / `Option` が型エラーになる
11. `safe.html.fragment` 内の raw `Untrusted<Str>` interpolation が型エラーになる
12. `app.awk` が `safe.*` 名前空間へ移行される

---

## 11. 設計メモ

`safe.*` は「安全な値を作る便利関数」ではなく、Hawk 型世界における **Safe / Brand 型の発行局** である。

- `safe.html.escape`  = sanitizer（Untrusted を受けて HtmlEscapedStr を発行）
- `safe.html.raw`     = trust assertion（信頼済み宣言、escape しない）
- `safe.html.fragment` = safe builder（安全な部品だけから HtmlFragment を組み立て）
- `safe.attr.escape`  = sanitizer（Untrusted を受けて HtmlAttrEscapedStr を発行）

`#{...}` interpolation は文字列を読みやすくするための syntax sugar だが、型安全性を壊してはいけない。interpolation は Untrusted を剥がさない。safe.* を通った値だけが HTML sink に到達できる。
