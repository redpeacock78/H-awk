# 設計仕様: when...of 構文変更 + type システム拡張

**日付**: 2026-06-17  
**ステータス**: 承認済み

---

## 概要

2つの独立した変更をまとめた仕様。

1. `when...of` の `ng` アームの構文変更（命名規則依存の廃止）
2. `type` 宣言の拡張（Union/Intersection Type対応、非Errorユーザー定義型）

---

## Feature 1: `when...of` 構文変更

### 問題

現行構文では `ng` アームの型判別が「大文字始まり = 型名、小文字始まり = 変数名」という命名規則に依存している。パッと見て型なのか変数なのか分かりにくい。

### 新構文

```
when xxx of
  ok x:           # ok bind（変化なし）
  ng y<Error1>:   # typed bind: 変数 y、型 Error1
  ng <Error2>:    # typed no-bind: 型 Error2 のみ（変数束縛なし）
  ng z:           # untyped bind: 変数 z（型指定なし）
  default:        # catch-all（変化なし）
  default w:      # catch-all bind（変化なし）
end
```

### 旧構文との対応

| 旧構文 | 新構文 | 意味 |
|--------|--------|------|
| `ng e: AuthError:` | `ng e<AuthError>:` | typed bind |
| `ng AuthError:` | `ng <AuthError>:` | typed no-bind |
| `ng e:` | `ng e:` | untyped bind（変化なし） |

### 変更箇所: `dsl/desugar_match.awk`

`_ds_match_collect()` 内の `ng` アーム判別ロジックを以下のregexに置き換える:

```awk
# typed bind: ng y<Error1>:
/^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)<([^>]+)>[[:space:]]*:[[:space:]]*$/

# typed no-bind: ng <Error2>:
/^[[:space:]]*ng[[:space:]]*<([^>]+)>[[:space:]]*:[[:space:]]*$/

# untyped bind: ng z:（変化なし）
/^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/
```

### 破壊的変更

既存テスト・サンプルの更新が必要:
- `tests/unit/dsl/when_typed_ng_single/`
- `tests/unit/dsl/when_typed_ng_multi/`
- `tests/unit/dsl/when_typed_ng_exhaustive_error/`
- `examples/` 内の関連ファイル

---

## Feature 2: `type` 構文拡張

### 問題

現行は `type X = Error` のみサポート。ユーザー定義の型エイリアス（Union/Intersection）を宣言できない。

### 新構文

```
type AuthError = Error           # 既存（変化なし）
type Status = Int | Str          # Union type エイリアス
type Config = Str | Int | Bool   # 多項 Union
type Precise = Int & Str         # Intersection type エイリアス
```

### デシュガー出力

`type X = <式>` は以下を emit する:

1. `_DS_TYPE_ALIAS["X"] = "<正規化された型式>"` を登録
2. バリデータ関数を出力:

```awk
# type Status = Int | Str
function Status(val) {
  if (type::accepts("Int|Str", val)) return val
  return result_ng("TypeError:Status", "expected Int|Str, got " val)
}

# type Precise = Int & Str
function Precise(val) {
  if (type::accepts("Int&Str", val)) return val
  return result_ng("TypeError:Precise", "expected Int&Str, got " val)
}
```

`type X = Error` は従来通り `result_ng` コンストラクタを emit（変化なし）。

### 変更箇所

**`dsl/desugar.awk`**:
- `type X = Error` の regex を汎用化: RHS が `Error` → 既存パス、それ以外 → alias + validator パス
- `_ds_extract_return_type()`: `-> Int | Str` など複合型を許容するよう regex 拡張

**`dsl/type.awk`**:
- `accepts()` に Intersection (`&`) 対応を追加: 全メンバーが accept すれば OK
- `normalize()` に `&` の正規化処理を追加（メンバーをソートして一意化）

### 関数返り値型への対応

```
function parse(s: Str) -> Int | Str {
  ...
}
```

`_DS_func_ret_type` に `"Int|Str"` として格納し、`type::accepts()` で return 文の型検証を行う。

---

## スコープ外

- nominal 型（struct など）
- ジェネリクス
- 型推論の強化
