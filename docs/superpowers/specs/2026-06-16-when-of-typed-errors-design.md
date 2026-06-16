# 設計仕様: `when...of` 構文リネームと型付きエラーマッチング

**日付**: 2026-06-16  
**対象ブランチ**: master  
**フェーズ**: 2段階実装（Phase 1 → 検証 → Phase 2）

---

## 背景と動機

- `match` が gawk の予約語と競合するため、`when...of` にリネームする
- 現状の ADT エンコード（`ng = ""`）ではエラー型を区別できない
- 複数の `ng TypeName:` アームを並べて型ごとに分岐できる構文を追加する
- `type X = Error` でカスタムエラー型のコンストラクタを生成できるようにする
- `core/util.awk` の ADT 関数は DSL の責務なので `dsl/adt.awk` に移譲する

---

## Phase 1: 基盤変更

### 1. ADT エンコード変更

現状と変更後の比較:

| 状態 | 現状 | 変更後 |
|------|------|--------|
| ok | 任意の非空文字列 `v` | `"ok\x1F" value` |
| ng | `""` (空文字固定) | `"ng\x1F" TypeName` または `"ng\x1F" TypeName "\x1F" msg` |
| some | 任意の非空文字列 | 変更なし |
| none | `""` | 変更なし |

`\x1F` は ASCII 31 (Unit Separator)。gawk で安全に使用可能。

### 2. 新 ADT 関数 (`dsl/adt.awk`)

```awk
function result_ok(v)           { return substr(v, 1, 3) == "ok\x1F" }
function result_val(v)          { return substr(v, 4) }
function result_ng(type, msg)   {
  return "ng\x1F" type (msg != "" ? "\x1F" msg : "")
}
function result_err_type(v,  a) { split(substr(v, 4), a, "\x1F"); return a[1] }
function result_err(v)          { return substr(v, 4) }

function option_some(v) { return v != "" }
function option_val(v)  { return v }
```

`result_err(v)` は `"TypeName"` または `"TypeName\x1Fmsg"` を返す（後方互換のため全体を返す）。

### 3. `when...of` 構文（全アーム形式）

```
when EXPR of
  # Result<T, E>
  ok name:          # ok 値を name に bind
  ok:               # bind なし（新規）

  ng e: TypeName:   # typed ng、e に bind（新規）
  ng TypeName:      # typed ng、bind なし（新規）
  ng name:          # untyped ng、name に bind（後方互換）
  ng:               # untyped ng、bind なし（新規）

  default name:     # catch-all、name に bind（新規）
  default:          # catch-all、bind なし（既存）

  # Option<T>
  some name:        # some 値を name に bind（既存）
  some:             # bind なし（新規）
  none:             # bind なし（既存）
end
```

**型名と変数名の判別**: アーム先頭が `[A-Z]` 始まり → 型名、`[a-z_]` 始まり → bind 変数名。

### 4. desugar 出力例

入力:
```
when fetch_user(id) of
  ok user:
    return ctx.res.json(user)
  ng e: AuthError:
    return ctx.res.status(401)
  ng e: NotFoundError:
    return ctx.res.status(404)
  default:
    return ctx.res.status(500)
end
```

出力:
```awk
_ds_mc_1 = fetch_user(id)
if (result_ok(_ds_mc_1)) {
  user = result_val(_ds_mc_1)
  return ctx::dispatch("res.json", user)
} else if (result_err_type(_ds_mc_1) == "AuthError") {
  e = result_err(_ds_mc_1)
  return ctx::dispatch("res.status", 401)
} else if (result_err_type(_ds_mc_1) == "NotFoundError") {
  e = result_err(_ds_mc_1)
  return ctx::dispatch("res.status", 404)
} else {
  return ctx::dispatch("res.status", 500)
}
```

**バリデーション**: typed ng アームが1つ以上ある場合、`default:` / `ng:` / `default name:` のいずれかが必須（既存の「ng/default 必須チェック」を拡張）。

### 5. `type X = Error` 構文

入力:
```
type AuthError = Error
type NotFoundError = Error
```

desugar 後:
```awk
function AuthError(msg)      { return result_ng("AuthError", msg) }
function NotFoundError(msg)  { return result_ng("NotFoundError", msg) }
```

処理: `dsl/desugar.awk` のメインループでトップレベル行として処理。型名は `_DS_ERROR_TYPES["AuthError"] = 1` に登録（Phase 2 の union type 検査で利用）。

正規表現:
```
/^[[:space:]]*type[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*Error[[:space:]]*$/
```

使用例:
```awk
type AuthError = Error

function fetch_user(id) -> Result<User, AuthError | NotFoundError> {
  if (!authenticated()) return AuthError("token expired")
  if (!found(id))       return NotFoundError("user " id)
  return ctx.req.json()
}
```

### 6. 変更ファイル一覧（Phase 1）

| ファイル | 変更内容 |
|----------|----------|
| `dsl/adt.awk` | **新規** — ADT 関数群 |
| `core/util.awk` | ADT 関数5つを削除 |
| `dsl/desugar.awk` | `type X = Error` 処理追加、`@include "dsl/adt.awk"` |
| `dsl/desugar_match.awk` | `match→when` リネーム、全アームパターン拡張、typed ng emit 追加 |
| `dsl/desugar_state.awk` | typed ng アーム用 state 追加（`_DS_match_ng_arms[]` 等） |
| `hawk.awk` / runtime include | `dsl/adt.awk` を runtime include に追加 |
| `core/request.awk` 等 | `""` → `result_ng("ParseError")` 等に更新 |
| `app.awk` | `match → when` リネーム |
| `tests/unit/dsl/match_*/input.awk` | `match → when` リネーム |
| `tests/unit/dsl/match_*/expected.awk` | 新エンコード反映 |

### 7. 新規テスト（Phase 1）

- `when_typed_ng_single/` — `ng e: AuthError:` 単発
- `when_typed_ng_multi/` — 複数 typed ng アーム + default
- `when_ok_nobind/` — `ok:` bind なし
- `when_some_nobind/` — `some:` bind なし
- `when_default_bind/` — `default name:` bind あり
- `type_error_decl/` — `type X = Error` コンストラクタ生成確認

---

## Phase 2: 型システム拡張

Phase 1 の検証完了後に実施。

### 目標

- `Result<T, AuthError | NotFoundError>` のような union error type を型システムで追跡
- typed ng アームの exhaustiveness チェック（網羅性検証）
- 未宣言エラー型を `ng TypeName:` で使った場合の警告

### 変更ファイル（Phase 2）

| ファイル | 変更内容 |
|----------|----------|
| `dsl/type.awk` | union error type 解析 |
| `dsl/typecheck.awk` | typed arm exhaustiveness check |
| `dsl/desugar_state.awk` | `_DS_ERROR_TYPES[]` 活用 |

---

## 設計上の決定事項

1. **Option エンコードは変更しない** — Option は型付き分岐が不要なため現状維持
2. **型名/変数名の区別は先頭文字の大小文字** — `[A-Z]` 始まり = 型名、`[a-z_]` 始まり = 変数名
3. **`result_err(v)` は全体文字列を返す** — `"TypeName\x1Fmsg"` 形式。型だけ欲しい場合は `result_err_type(v)` を使う
4. **後方互換 `ng name:`** — 既存の untyped ng は Phase 1 以降も動作する
