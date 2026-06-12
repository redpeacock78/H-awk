# DSL拡張設計: env/hawk dispatch・型アノテーション・`??`演算子

**Date:** 2026-06-12

## 概要

H-awkのDSLに以下の機能を追加する。

1. `env.get(key)` など dot記法でenv名前空間にアクセスできるようにする（`env::dispatch`追加）
2. `hawk.app.on` / `hawk.app.all` をDSLから呼べるようにする
3. `hawk.app.listen` が非数値ポートをエラーとして扱う
4. `??` 演算子（null合体演算子）をDSL全体で使えるようにする
5. `let name: Type = expr` 型アノテーション構文を追加する
6. 型変換・検証のランタイムモジュール `core/type.awk` を追加する

---

## 変更対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `core/env.awk` | `dispatch` 関数追加 |
| `core/hawk.awk` | `dispatch` に `a3` 追加、`on`/`all`追加、`listen` 数値検証 |
| `core/type.awk` | 新規: `type::coerce(val, typename)` |
| `hawk.awk` | `@include "core/type.awk"` 追加 |
| `dsl/desugar_state.awk` | `_DS_tc_count = 0` 追加 |
| `dsl/desugar_nullcoalesce.awk` | 新規: `??` 汎用変換 |
| `dsl/desugar_let.awk` | 型アノテーション対応 |
| `dsl/desugar.awk` | パイプライン更新 |
| `app.awk` | 新記法に更新 |

---

## Section 1: dispatch拡張

### `core/env.awk` — `env::dispatch` 追加

`env.get(key)` のDSL変換先として `env::dispatch` を実装する。

```awk
function dispatch(path, a1, a2) {
    if (path == "get") return get(a1)
    if (path == "set") { set(a1, a2); return }
    if (path == "del") { del(a1);     return }
    if (path == "has") return has(a1)
    print "env::dispatch: unknown path: " path > "/dev/stderr"
}
```

### `core/hawk.awk` — `dispatch` 拡張

`a3` パラメータを追加し、`on`/`all` を新たにサポートする。

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

`listen` は非数値ポートを受け取った場合に `exit 1` する。

```awk
function listen(port) {
    if (port !~ /^[0-9]+$/ || port + 0 == 0) {
        print "hawk::listen: invalid port: \"" port "\"" > "/dev/stderr"
        exit 1
    }
    awk::listen(port + 0)
}
```

ポート `0` は無効とする（OSアサインは非サポート）。

---

## Section 2: `core/type.awk`

型変換・検証のランタイムモジュール。変換失敗時は `stderr` にメッセージを出力して `exit 1`。

```awk
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

`hawk.awk` に `@include "core/type.awk"` を追加する。

---

## Section 3: DSLデシュガーパイプライン拡張

### パイプライン順序

```
desugar_strings → desugar_dot → desugar_nullcoalesce → desugar_let（拡張） → hoisting
```

dot変換後に `??` を展開し、その後 `let` 型アノテーションが適用される。

---

### `dsl/desugar_nullcoalesce.awk`（新規）

`??` を行のどこでも使える汎用変換。文字列・コメント外のみ処理。

**変換ルール:**

`EXPR ?? DEFAULT` を検出したとき:
- `??` の左側: 直近の `(` または `,`（depth 0）まで逆スキャンして EXPR を特定
- `??` の右側: `)` または `,`（depth 0）までスキャンして DEFAULT を特定
- グローバルカウンタ `_DS_tc_count++` でtemp変数名 `_ds_tc_N` を生成（`desugar_state.awk` の `_ds_init` に `_DS_tc_count = 0` 追加）

**入力:**
```awk
hawk.app.listen(env.get("PORT") ?? 8080)
```

**dot変換後:**
```awk
hawk::dispatch("app.listen", env::dispatch("get", "PORT") ?? 8080)
```

**`??` 変換後（2行出力）:**
```awk
_ds_tc_1 = env::dispatch("get", "PORT")
hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
```

---

### `dsl/desugar_let.awk` 拡張

型アノテーション `let name: Type = expr` を処理する。`??` は前段で処理済みのため、`let` 段階では型変換のみ担当。

**追加パターン（既存パターンより前に試す）:**

```
let name: Type = expr  →  name = type::coerce(expr, "Type")
```

正規表現:
```
/^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/
```

`name` は `_DS_let_locals` に登録（hoisting対象）。

**`_ds_tc_N` の hoisting:** `desugar_nullcoalesce.awk` が `_ds_tc_N` を生成する際、`_DS_let_locals` に登録する。これにより `??` を関数本体内で使った場合でも temp var が関数ローカルに hoisting される。gawk では宣言なき変数はグローバルになるため、登録しないと複数関数間で temp var が衝突するリスクがある。

---

## 記法の対応表

| DSL記法 | デシュガー後 |
|---------|------------|
| `env.get("PORT")` | `env::dispatch("get", "PORT")` |
| `env.set("K", "V")` | `env::dispatch("set", "K", "V")` |
| `hawk.app.on(m, p, h)` | `hawk::dispatch("app.on", m, p, h)` |
| `hawk.app.all(p, h)` | `hawk::dispatch("app.all", p, h)` |
| `hawk.app.listen(8080)` | `hawk::dispatch("app.listen", 8080)` |
| `let port: Int = expr` | `port = type::coerce(expr, "Int")` |
| `expr ?? default` | temp var + 三項演算子 |

---

## `app.awk` 更新例

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

---

## テスト方針

`tests/unit/dsl/` に以下のfixture追加:

| fixture | 検証内容 |
|---------|---------|
| `env_dispatch/` | `env.get(k)` → `env::dispatch("get", k)` |
| `nullcoalesce_basic/` | `expr ?? default` → temp var + 三項 |
| `nullcoalesce_in_call/` | 関数引数内の `??` |
| `type_int/` | `let x: Int = expr` → `type::coerce` |
| `type_all/` | `Int`, `Str`, `Float`, `Bool` 各型 |
| `type_with_nullcoalesce/` | `let x: Int = expr ?? default` の組合せ |

---

## 対象外（Phase 2以降）

- `??` のネスト（`a ?? b ?? c`）
- `let` 以外での複数 `??`（同一行に複数）
- ポート `0`（OS割当）のサポート
- 型アノテーション付き bare `let name: Type`（初期値なし）
