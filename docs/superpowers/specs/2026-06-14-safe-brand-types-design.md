# 設計仕様: Safe Brand 型 + 隣接文字列リテラル folding

**日付**: 2026-06-14  
**PR名候補**: `feat(dsl): add safe HTML brand types and adjacent string literal folding`

---

## 背景と目的

Hawk DSL の HTML 出力 sink (`ctx.res.html`) に対して、外部入力 (`Untrusted<Str>`) を直接渡すことが型システム上で防げていなかった。また、`Safe<T>` という汎用ラッパー型が表面型として存在し、型の意図が不明確だった。

本仕様では以下を実現する:

1. `HtmlEscapedStr` / `HtmlFragment` を **brand 型**として導入し、sink safety を型レベルで保証する
2. `escape_html` を **組み込み trusted sanitizer** として登録し、`Untrusted<Str>` → `HtmlEscapedStr` の変換を提供する
3. `ctx.res.text` の型制約を緩和し (`Str | Untrusted<Str>` を受け入れ)、実用上の問題を解消する
4. `transform` / `validator` の Untrusted 伝播を正しく実装する
5. HTML 断片を読みやすく書くための **隣接文字列リテラル folding** を構文糖衣として追加する

---

## 型の流れ

```
ctx.req.form("title")             : Result<Untrusted<Str>, ParseError>
  ↓ ?= 展開
raw                               : Untrusted<Str>
  ↓ transform (e.g. trim)
trimmed                           : Untrusted<Str>      # Untrusted を保持
  ↓ validator (e.g. non_empty)
validated                         : Untrusted<NonEmptyStr>  # Untrusted を保持
  ↓ sanitizer (escape_html)
safe                              : HtmlEscapedStr       # ここで初めて brand
  ↓ ctx.res.html(safe)
                                  : Response
```

---

## セクション 1: 型システム変更

### 1.1 `_DS_TYPE_KIND` テーブル

`sig.awk` の BEGIN ブロックに追加する。

```awk
_DS_TYPE_KIND["HtmlEscapedStr"]     = "brand"
_DS_TYPE_KIND["HtmlFragment"]       = "brand"
_DS_TYPE_KIND["HtmlAttrEscapedStr"] = "brand"   # 将来拡張用、登録のみ
```

補助関数は `type_dataflow.awk` に追加する。

```awk
function _ds_type_kind(t)     { return _DS_TYPE_KIND[t] }
function _ds_is_brand(t)      { return _DS_TYPE_KIND[t] == "brand" }
```

### 1.2 `Safe<T>` エイリアス

`Safe<HtmlStr>` は `HtmlEscapedStr` の移行用エイリアスとする。`sig.awk` の `_DS_TYPE_ALIAS` に追加。

```awk
_DS_TYPE_ALIAS["Safe<HtmlStr>"] = "HtmlEscapedStr"
_DS_TYPE_ALIAS["Safe<Str>"]     = "Str"
```

### 1.3 `type::normalize` の対応

現状 `normalize` は単純な union ソートのみ。`Safe<HtmlStr>` のようなパラメトリック形式のエイリアスを `expand_alias` で展開するため、union 分割前に各トークンに `expand_alias` を適用する処理を追加する。

### 1.4 brand 型偽造禁止

`desugar_let.awk` の `_ds_check_type` 内で、`declared` が brand kind の場合に特別なエラーを出す。

```
safe/brand type cannot be created by annotation
HtmlEscapedStr must be constructed by trusted sanitizer
help: use escape_html()
```

条件: `declared` が brand、かつ `inferred` が同一 brand ではない場合。

---

## セクション 2: シグネチャレジストリ変更 (sig.awk)

```awk
# ctx.res.html: HtmlEscapedStr | HtmlFragment のみ受け入れ
_DS_SIG_ARG["ctx.res.html", 1] = "HtmlEscapedStr|HtmlFragment"
_DS_SIG_RET["ctx.res.html"]    = "Response"

# ctx.res.text: Str | Untrusted<Str> に緩和
_DS_SIG_ARG["ctx.res.text", 1] = "Str|Untrusted<Str>"
_DS_SIG_RET["ctx.res.text"]    = "Response"

# escape_html: 組み込み trusted sanitizer
_DS_SIG_ARG["escape_html", 1]  = "Str|Untrusted<Str>"
_DS_SIG_RET["escape_html"]     = "HtmlEscapedStr"
_DS_SIG_ARITY["escape_html"]   = 1
_DS_FUNC_CLASS["escape_html"]  = "sanitizer"
_DS_SIG_TRUSTED["escape_html"] = 1
```

`ctx.res.json` は現状維持 (`Safe<JsonStr>`) とし、今回のスコープ外とする。

---

## セクション 3: Untrusted 伝播 + sanitizer 変更

### 3.1 `_ds_dataflow_ret` 拡張 (type_dataflow.awk)

```awk
function _ds_dataflow_ret(fname, input_type,    cls, ret) {
    cls = _DS_FUNC_CLASS[fname]
    ret = _DS_SIG_RET[fname]
    if ((cls == "transform" || cls == "validator") && _ds_is_untrusted(input_type))
        return "Untrusted<" ret ">"
    return ret
}
```

`validator` も `transform` と同様に Untrusted を伝播させる（仕様: validator は性質のみ積み、外部由来性は消さない）。

### 3.2 desugar_pipe.awk の接続

**変更前** (line ~99):
```awk
_DS_VAR_TYPES[_DS_func_name, tmpvar] = _DS_SIG_RET[fname]
```

**変更後**:
```awk
_DS_VAR_TYPES[_DS_func_name, tmpvar] = _ds_dataflow_ret(fname, left_type)
```

### 3.3 sanitizer の Untrusted 受け入れ許可

**変更前** (desugar_pipe.awk):
```awk
if (cls != "transform" && cls != "validator") { # エラー }
```

**変更後**:
```awk
if (cls != "transform" && cls != "validator" && cls != "sanitizer") { # エラー }
```

sanitizer は Untrusted を受け取り brand 型を返すことで安全性を保証する。

### 3.4 影響するテスト

| テスト | 変更内容 |
|--------|---------|
| `safe_sink_ok` | `Safe<HtmlStr>` → `HtmlEscapedStr`、`escape_html` の return type 変更 |
| `safe_sink_error` | same |
| `untrusted_non_transform_error` | sanitizer が Untrusted を受け入れるようになるため廃止し、`safe_html_sink_untrusted_error` / `untrusted_trim_then_html_error` で同等の保護を検証する |
| `untrusted_transform_ok` | validator の Untrusted 伝播も確認するよう拡張 |

---

## セクション 4: 隣接文字列リテラル folding

### 4.1 対象

隣接する文字列リテラルのみ。動的値との混在は対象外。

```hawk
# OK
let html =
  "<tr>"
    "<td>Hello</td>"
  "</tr>"

# 対象外 (変数との混在)
let s = "foo" varname "bar"
```

### 4.2 実装位置

`desugar.awk` の Pass 2 ループ内。行をまたぐため、以下の状態変数を保持する。

```awk
_ds_str_pending     = ""   # 積んでいる文字列の中身（クォートなし）
_ds_str_has_pending = 0
```

### 4.3 ロジック

1. 行を `_ds_split_code_segs` でセグメント化
2. コードセグメントが空白のみ + 文字列リテラルが1つ → `_ds_str_pending` に結合（前後クォートを除いて連結）
3. コードが実質ある行（`=`、関数呼び出し等）または空行が来たら → pending を flush して `"<結合内容>"` として返す
4. 結果は `Str` 型

### 4.4 エスケープ保持

リテラルの開閉 `"` だけを除去し、中身（`\"`, `\\`, `\n` 等）はそのまま保持する。

### 4.5 制限事項 (初期実装)

- `sprintf(...)` 等の式内部では未対応（後続）
- コメント行をまたぐ folding は未対応
- インデントは無視（leading whitespace のみ）

### 4.6 型

結果は `Str`。brand 型にはしない（静的リテラルを自動的に safe とする判断は後続の `html.fragment` に任せる）。

---

## テスト計画

### 新規追加テスト

**Safe / Brand 系**
- `safe_escape_html_ok` — escape_html → ctx.res.html の正常フロー
- `safe_html_sink_untrusted_error` — Untrusted<Str> を直接 ctx.res.html へ
- `safe_html_sink_trimmed_untrusted_error` — trim 後の値を ctx.res.html へ（まだ Untrusted）
- `safe_html_sink_plain_str_error` — plain Str を ctx.res.html へ
- `safe_brand_annotation_forge_error` — `let safe: HtmlEscapedStr = raw`
- `safe_escape_html_returns_html_escaped` — escape_html の戻り型確認

**Untrusted 伝播系**
- `untrusted_transform_propagates` — transform 後も Untrusted<Str>
- `untrusted_validator_propagates` — validator 後も Untrusted<NonEmptyStr>
- `untrusted_trim_then_html_error` — trim → ctx.res.html でエラー
- `untrusted_trim_then_escape_html_ok` — trim → escape_html → ctx.res.html で OK

**隣接文字列リテラル系**
- `string_adjacent_same_line` — `"foo" "bar"` → `"foobar"`
- `string_adjacent_multiline` — 複数行 folding
- `string_adjacent_nested_indent` — インデントをまたぐ folding
- `string_adjacent_keeps_escape_sequences` — エスケープ保持
- `string_adjacent_only_literals` — 変数と混在しない
- `string_adjacent_does_not_merge_identifier` — 変数は結合されない

---

## 実装順序

| Step | 対象ファイル | 内容 |
|------|------------|------|
| 1 | `dsl/type_dataflow.awk` | `_DS_TYPE_KIND` 登録、`_ds_is_brand`, `_ds_type_kind`, `_ds_dataflow_ret` 拡張 |
| 2 | `dsl/sig.awk` | `HtmlEscapedStr` エイリアス、`escape_html` 登録、`ctx.res.*` 型変更 |
| 3 | `dsl/type.awk` | `normalize` の `expand_alias` 対応（パラメトリック Safe<T>） |
| 4 | `dsl/desugar_pipe.awk` | `_ds_dataflow_ret` 接続、sanitizer Untrusted 許可 |
| 5 | `dsl/desugar_let.awk` | brand 型偽造禁止エラー |
| 6 | `dsl/desugar.awk` | 隣接文字列リテラル folding |
| 7 | `tests/unit/dsl/` | 既存テスト更新 + 新規テスト追加 |
| 8 | `app.awk` | `escape_html` 経由に書き換え（`make run` エラー解消） |

---

## 受け入れ条件

1. `HtmlEscapedStr` が brand type として登録されている
2. `escape_html` が `HtmlEscapedStr` を返す trusted sanitizer として扱われる
3. `ctx.res.html` が `HtmlEscapedStr | HtmlFragment` しか受け取らない
4. `Untrusted<Str>` を `ctx.res.html` に直接渡すと型エラーになる
5. `trim(Untrusted<Str>)` の結果が `Untrusted<Str>` のままになる
6. `validator(Untrusted<Str>)` の結果が `Untrusted<T>` のままになる
7. trim 後の値を `ctx.res.html` に渡しても型エラーになる
8. `escape_html` 後の値は `ctx.res.html` に渡せる
9. `let x: HtmlEscapedStr = raw` のような偽造が型エラーになる
10. 隣接文字列リテラルが1つの文字列に畳まれる
11. 文字列リテラル以外は勝手に結合されない
12. `make run` の `app.awk` エラーが解消される

---

## 将来拡張 (今回スコープ外)

- `HtmlFragment` / `html.fragment(...)` trusted builder
- `HtmlAttrEscapedStr` / `escape_attr`
- `JsonSafeStr` / `to_json_safe`
- `SafeUrl` / `SafePath` / `SqlParam`
- `sprintf(...)` 内の隣接リテラル folding
