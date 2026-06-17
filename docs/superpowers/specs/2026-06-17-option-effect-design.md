# Option<T> / Effect<T> 設計仕様

**日付**: 2026-06-17  
**対象ブランチ**: master  
**ステータス**: 承認済み、実装待ち

---

## 概要

- `Option<T>` のエンコーディングを明示的センチネルに変更し、空文字列を正当な値として扱えるようにする
- `option.some(val)` / `option.none()` をDSLから呼び出せる構築関数として追加する
- `option.some(val)` の戻り型を引数型から推論する（ジェネリック推論）
- `Effect<T>` を型レベルで設計する（ランタイム実装は将来）
- `?=` / `when...of` が `Effect<T>` を自動的に剥がし、関数の色問題を回避する

---

## 1. エンコーディング変更 (`dsl/adt.awk`)

### 問題

現在の実装は `v != ""` を some、`""` を none として扱う。  
`Option<Str>` の値が空文字列のとき none と区別できない。

### 変更後エンコーディング

```awk
# 構築関数
function option_some_make(val) { return "some\x1F" val }
function option_none_make()    { return "none\x1F" }

# 判定・値取り出し
function option_some(v)  { return substr(v, 1, 5) == "some\x1F" }
function option_none(v)  { return v == "none\x1F" }
function option_val(v)   { return substr(v, 6) }
```

センチネル文字 `\x1F` (ASCII Unit Separator) はAWKの通常の文字列には出現しないため衝突しない。

### 破壊的変更の影響範囲

`option_some` / `option_val` を参照するのは `dsl/` 内部のみ。  
`tests/` や `examples/` には現時点でOption使用コードがないため、影響は局所的。

---

## 2. DSL構築関数 (`dsl/desugar_dot.awk`, `dsl/sig.awk`, `dsl/typecheck.awk`)

### DSL構文

```
return option.some(rows[id])
return option.none()
```

### desugar_dot.awk

既存の `ctx.res.text(x)` → `ctx_res_text(x)` と同じパターンでマッピングを追加する:

```
option.some(x)  →  option_some_make(x)
option.none()   →  option_none_make()
```

### sig.awk

```awk
_DS_SIG_RET["option.some"]   = "Option<Any>"  # typecheck側で上書き
_DS_SIG_ARITY["option.some"] = 1
_DS_SIG_RET["option.none"]   = "Option<Any>"
_DS_SIG_ARITY["option.none"] = 0
```

### typecheck.awk — ジェネリック推論

`option_some_make(arg)` の呼び出しを検出したとき:

1. `arg` の型を `_DS_VAR_TYPES` から取得して T とする
2. 戻り型を `Option<T>` として記録する

`option_none_make()` は `Option<Any>` を返す。  
関数の return type annotation が `Option<Str>` 等であれば、`type::accepts` による照合時に `Option<Any>` を許容する方向とする。

### 使用例

```
function find_title(id: Str) -> Option<Str> {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}

when find_title(id) of
  some title:
    return ctx.res.text(title)
  none:
    return ctx.res.status(404).text("not found")
end
```

---

## 3. `Effect<T>` 型設計 (`dsl/typecheck.awk`, `dsl/desugar_let.awk`, `dsl/desugar_match.awk`)

### 目的

非同期処理（`cache.get`, `db.find` 等）が返す `Effect<T>` を、  
`?=` / `when...of` 構文が自動的に剥がすことで関数の色問題を回避する。  
呼び出し側は同期/非同期を意識しなくてよい。

### ランタイム

現時点では AWK は同期実行のみ。Effect はランタイムレベルでは pass-through。  
将来の非同期実装時は `_ds_strip_effect` が `effect_await(v)` の emit に変わる。

### 型剥がしヘルパー

```awk
function _ds_strip_effect(t,    m) {
    if (match(t, /^Effect<(.+)>$/, m)) return m[1]
    return t
}
```

### `?=` での Effect 剥がし (`dsl/desugar_let.awk`)

右辺の型を `_ds_strip_effect` に通してから Option / Result の判定を行う:

```
?= の右辺型 T
→ _ds_strip_effect(T) → Option<Str> または Result<Str, E>
→ 既存の Option / Result 処理へ
```

`Effect<Result<Option<T>, E>>` の場合:

1. strip Effect → `Result<Option<T>, E>`
2. Result の ng 側に `Option<T>` が残る
3. `when...of` でさらにマッチ

### `when...of` での Effect 剥がし (`dsl/desugar_match.awk`)

対象式の型を `_ds_strip_effect` してからマッチ判定を行う。

### sig.awk への将来登録例

```awk
# 現時点では同期として登録
_DS_SIG_RET["cache.get"] = "Option<Str>"

# 非同期実装後
# _DS_SIG_RET["cache.get"]        = "Effect<Option<Str>>"
# _DS_SIG_RET["db.find"]          = "Effect<Result<Option<Any>, DbError>>"
```

---

## 4. 変更ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `dsl/adt.awk` | エンコーディング変更、`option_some_make` / `option_none_make` 追加 |
| `dsl/desugar_dot.awk` | `option.some` / `option.none` → ランタイム関数へのマッピング追加 |
| `dsl/sig.awk` | `option.some` / `option.none` シグネチャ登録 |
| `dsl/typecheck.awk` | `option_some_make` のジェネリック推論、`_ds_strip_effect` 追加 |
| `dsl/desugar_let.awk` | `?=` での `_ds_strip_effect` 適用 |
| `dsl/desugar_match.awk` | `when...of` での `_ds_strip_effect` 適用 |

`desugar_match.awk` の `some VAR:` / `none:` arm は `option_some(v)` / `option_val(v)` を経由するため、`adt.awk` の変更だけで追従する。

---

## 5. スコープ外（将来対応）

- Effect のランタイム実装（非同期実行機構）
- `cache.get` / `db.find` の実際の実装
- `Option<T>` の `map` / `flat_map` 等のコンビネータ
