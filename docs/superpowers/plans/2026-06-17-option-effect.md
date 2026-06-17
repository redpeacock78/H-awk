# Option<T> / Effect<T> Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Option<T> のエンコーディングを明示的センチネルに変更し、DSLから `option.some(val)` / `option.none()` を呼べるようにする。あわせて `Effect<T>` の型剥がしを `?=` / `when...of` に追加する。

**Architecture:** Approach A — 既存のパイプライン（desugar_dot → desugar_match/let → typecheck）に最小限の変更を加える。`adt.awk` のランタイムエンコーディングを変更し、`desugar_dot.awk` でドット記法を展開、`typecheck.awk` でジェネリック推論、`desugar_let.awk` / `desugar_match.awk` で Effect 剥がしを追加する。

**Tech Stack:** gawk (POSIX AWK + namespace extension), bats-like shell test runner (tests/unit/dsl/run.sh)

---

## ファイル変更マップ

| ファイル | 種別 | 変更内容 |
|---|---|---|
| `dsl/adt.awk` | Modify | エンコーディング変更、`option_some_make` / `option_none_make` 追加 |
| `dsl/desugar_dot.awk` | Modify | `option.some` / `option.none` → ランタイム関数マッピング追加 |
| `dsl/sig.awk` | Modify | `option.some` / `option.none` シグネチャ登録 |
| `dsl/typecheck.awk` | Modify | `option_some_make` ジェネリック推論、`_ds_strip_effect` 追加 |
| `dsl/desugar_let.awk` | Modify | `?=` で Option 対応 + Effect 剥がし |
| `dsl/desugar_match.awk` | Modify | `when...of` で Effect 剥がし |
| `tests/unit/dsl/match_option_basic/expected.awk` | Modify | `option_some` / `option_val` に修正 |
| `tests/unit/dsl/when_some_nobind/expected.awk` | Modify | `option_some` に修正 |
| `tests/unit/dsl/option_construction_basic/` | Create | `option.some(val)` / `option.none()` の desugar テスト |
| `tests/unit/dsl/option_some_type_infer/` | Create | `option.some(val)` → `Option<T>` 推論テスト |
| `tests/unit/dsl/option_unwrap_let_option/` | Create | `?=` が Option を正しく扱うテスト |
| `tests/unit/dsl/effect_strip_let/` | Create | `_ds_strip_effect` が `?=` で動くテスト |
| `tests/unit/dsl/effect_strip_match/` | Create | `when...of` で Effect 剥がしテスト |

---

## 重要な事前確認

現状の `when...of` は `type_t` が `""` (未知の関数) のとき `result_ok` / `result_val` にフォールバックする。`some:`/`none:` arm を持つ `when...of` が偶然動いているのはこのため。エンコーディング変更後は `option_some` / `option_val` を正しく使う必要があり、arm 名による型判定も追加が必要。

---

## Task 1: `adt.awk` エンコーディング変更

**Files:**
- Modify: `dsl/adt.awk`

`option_some_make` / `option_none_make` を追加し、既存の `option_some` / `option_val` を新エンコーディングに合わせる。

- [ ] **Step 1: 既存の `adt.awk` の Option 部分を確認する**

```bash
grep -n "option" dsl/adt.awk
```

現状: `option_some(v) { return v != "" }` と `option_val(v) { return v }`

- [ ] **Step 2: `adt.awk` の Option 関数を書き換える**

`dsl/adt.awk` 内の `option_some`, `option_val` 行を以下に変更し、`option_some_make` / `option_none_make` を追加する:

```awk
function option_some_make(val) { return "some\x1F" val }
function option_none_make()    { return "none\x1F" }
function option_some(v)        { return substr(v, 1, 5) == "some\x1F" }
function option_none(v)        { return v == "none\x1F" }
function option_val(v)         { return substr(v, 6) }
```

- [ ] **Step 3: インライン自己チェック**

`adt.awk` の末尾に以下を追加してエンコーディングを確認し、確認後に削除する（削除してコミット）:

```bash
gawk '
@include "dsl/adt.awk"
BEGIN {
    s = option_some_make("hello")
    assert(option_some(s), "some check")
    assert(!option_none(s), "not none")
    assert(option_val(s) == "hello", "val extract")
    n = option_none_make()
    assert(option_none(n), "none check")
    assert(!option_some(n), "not some")
    # 空文字列が正しく some として扱われる
    e = option_some_make("")
    assert(option_some(e), "empty string is some")
    assert(option_val(e) == "", "empty val")
    print "adt.awk encoding: OK"
}
'
```

期待出力: `adt.awk encoding: OK`

- [ ] **Step 4: コミット**

```bash
git add dsl/adt.awk
git commit -m "feat(adt): change Option encoding to explicit sentinel"
```

---

## Task 2: `when...of` の Option 対応修正

**Files:**
- Modify: `dsl/desugar_match.awk`
- Modify: `tests/unit/dsl/match_option_basic/expected.awk`
- Modify: `tests/unit/dsl/when_some_nobind/expected.awk`

現状は型不明時に `result_ok` にフォールバックしている。arm 名 (`some:`) から Option と判定するロジックを追加する。

- [ ] **Step 1: 既存テストが壊れることを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "FAIL|PASS" | grep -E "match_option|when_some"
```

エンコーディング変更後は `match_option_basic` と `when_some_nobind` が FAIL になる（expected が `result_ok` を期待しているため）。

- [ ] **Step 2: `desugar_match.awk` の型判定を修正する**

`dsl/desugar_match.awk` の `type_t = _ds_infer_type(_DS_match_expr)` の直後にある分岐を以下に変更する:

```awk
type_t = _ds_infer_type(_DS_match_expr)
# arm 名から Option/Result を判定（型不明時のフォールバック）
if (type_t ~ /^Option</ || (type_t == "" && _DS_match_ok_var == "some")) {
    check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
} else {
    check_fn = "result_ok"; val_fn = "result_val"; err_fn = "result_err"
}
```

`_DS_match_ok_var` は `some VAR:` arm のパース時に設定される変数名 (no-bind の場合は `"some"` として判定)。実際の変数名と `"some"` という arm キーワードの区別が必要なので、代わりに `_DS_match_is_option` フラグを使う:

```awk
# _ds_match_collect 内の some VAR: マッチ箇所に追加:
_DS_match_is_option = 1
```

そして判定箇所を:

```awk
if (type_t ~ /^Option</ || (type_t == "" && _DS_match_is_option)) {
    check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
} else {
    check_fn = "result_ok"; val_fn = "result_val"; err_fn = "result_err"
}
```

また `_ds_match_reset()` に `_DS_match_is_option = 0` を追加する。

- [ ] **Step 3: `match_option_basic/expected.awk` を修正する**

`tests/unit/dsl/match_option_basic/expected.awk` を以下に変更:

```awk
function handler(    _ds_mc_1, val) {
  _ds_mc_1 = find_item(id)
  if (option_some(_ds_mc_1)) {
    val = option_val(_ds_mc_1)
    return ctx::dispatch("res.json", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

- [ ] **Step 4: `when_some_nobind/expected.awk` を修正する**

`tests/unit/dsl/when_some_nobind/expected.awk` を以下に変更:

```awk
function handler(    _ds_mc_1) {
  _ds_mc_1 = find_item(id)
  if (option_some(_ds_mc_1)) {
    return ctx::dispatch("res.status", 200)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

- [ ] **Step 5: テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "match_option|when_some"
```

期待: `PASS: match_option_basic`, `PASS: when_some_nobind`

- [ ] **Step 6: コミット**

```bash
git add dsl/desugar_match.awk \
        tests/unit/dsl/match_option_basic/expected.awk \
        tests/unit/dsl/when_some_nobind/expected.awk
git commit -m "fix(match): use option_some/option_val for some/none arms"
```

---

## Task 3: `option.some` / `option.none` DSL構築関数

**Files:**
- Modify: `dsl/desugar_dot.awk`
- Modify: `dsl/sig.awk`
- Create: `tests/unit/dsl/option_construction_basic/input.awk`
- Create: `tests/unit/dsl/option_construction_basic/expected.awk`

- [ ] **Step 1: テストを書く**

`tests/unit/dsl/option_construction_basic/input.awk`:

```awk
function find_title(id) {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}
```

`tests/unit/dsl/option_construction_basic/expected.awk`:

```awk
function find_title(id) {
  if (!(id in rows)) {
    return option_none_make()
  }
  return option_some_make(rows[id])
}
```

- [ ] **Step 2: テストが FAIL することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_construction_basic"
```

期待: `FAIL: option_construction_basic`

- [ ] **Step 3: `sig.awk` にシグネチャを登録する**

`dsl/sig.awk` の `BEGIN` ブロックに追加:

```awk
# option constructors
_DS_SIG_RET["option.some"]    = "Option<Any>"
_DS_SIG_ARITY["option.some"]  = 1
_DS_SIG_ARG["option.some", 1] = "Any"

_DS_SIG_RET["option.none"]    = "Option<Any>"
_DS_SIG_ARITY["option.none"]  = 0
```

- [ ] **Step 4: `desugar_dot.awk` にマッピングを追加する**

`desugar_dot.awk` の `_ds_dispatch_from` 関数内、`ns` と `path` を確定した後、`option` namespace の特別処理を追加する:

```awk
# option.some / option.none は ns::dispatch でなく直接関数呼び出しに変換
if (ns == "option" && path == "some") {
    return "option_some_make(" (args != "" ? _ds_dot_transform(args) : "") ")" \
           _ds_dot_transform(after_close)
}
if (ns == "option" && path == "none") {
    return "option_none_make()" _ds_dot_transform(after_close)
}
```

この追加は `_ds_typecheck_call(ns "." path, args)` の呼び出しの後、`return ns "::dispatch(..."` の前に挿入する。

- [ ] **Step 5: テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_construction_basic"
```

期待: `PASS: option_construction_basic`

- [ ] **Step 6: 全テストが壊れていないことを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep FAIL
```

期待: FAIL なし（または既存 FAIL のみ）

- [ ] **Step 7: コミット**

```bash
git add dsl/desugar_dot.awk dsl/sig.awk \
        tests/unit/dsl/option_construction_basic/
git commit -m "feat(dsl): add option.some/option.none construction functions"
```

---

## Task 4: `option.some(val)` のジェネリック型推論

**Files:**
- Modify: `dsl/typecheck.awk`
- Create: `tests/unit/dsl/option_some_type_infer/input.awk`
- Create: `tests/unit/dsl/option_some_type_infer/expected.awk`

`option.some(val)` の呼び出しから `Option<T>` を推論する。`_ds_infer_type` で `option.some(...)` パターンを検出し、引数の型 T から `Option<T>` を返す。

- [ ] **Step 1: テストを書く**

`tests/unit/dsl/option_some_type_infer/input.awk`:

```awk
function find_title(id: Str) -> Option<Str> {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}
```

`tests/unit/dsl/option_some_type_infer/expected.awk`:

```awk
function find_title(id,    _ds_id) {
  _ds_id = type::coerce(id, "Str")
  if (!(id in rows)) {
    return option_none_make()
  }
  return option_some_make(rows[id])
}
```

期待 stderr: (空 — エラーなし)

このテストは `return type` が `Option<Str>` で `option.some(Str)` が型的に整合することを確認する。

- [ ] **Step 2: テストが FAIL することを確認する（型エラーが出るか確認）**

```bash
gawk -f dsl/desugar.awk tests/unit/dsl/option_some_type_infer/input.awk 2>&1
```

- [ ] **Step 3: `_ds_infer_type` に `option_some_make` の推論を追加する**

`dsl/desugar_let.awk` の `_ds_infer_type` 関数（desugar_let.awk:5）内、既知 DSL 関数呼び出しのマッチ後に追加:

```awk
# option_some_make(arg) → Option<T> (arg の型から T を推論)
if (match(expr, /^option_some_make\((.+)\)[[:space:]]*$/, m)) {
    arg_type = _ds_infer_type(_ds_trim(m[1]))
    return "Option<" (arg_type != "" ? arg_type : "Any") ">"
}
# option_none_make() → Option<Any>
if (expr ~ /^option_none_make\(\)[[:space:]]*$/) {
    return "Option<Any>"
}
```

ただし `_ds_infer_type` は desugar 後の式を受け取るため、`option.some(val)` は既に `option_some_make(val)` に変換済み。このパターンを追加する位置は `# 既知の DSL 関数呼び出し` のブロックの前。

- [ ] **Step 4: テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_some_type_infer"
```

期待: `PASS: option_some_type_infer`

- [ ] **Step 5: コミット**

```bash
git add dsl/desugar_let.awk \
        tests/unit/dsl/option_some_type_infer/
git commit -m "feat(typecheck): infer Option<T> from option_some_make(arg)"
```

---

## Task 5: `?=` の Option 対応

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/option_unwrap_let_option/input.awk`
- Create: `tests/unit/dsl/option_unwrap_let_option/expected.awk`

現状の `?=` は `result_ok` / `result_val` のみを使う。Option 型のとき `option_some` / `option_val` を使うよう修正する。none の場合は 404 を返す。

- [ ] **Step 1: テストを書く**

`tests/unit/dsl/option_unwrap_let_option/input.awk`:

```awk
function handler() {
  let title ?= find_title(id)
  return ctx.res.text(title)
}
```

`_DS_SIG_RET["find_title"] = "Option<Str>"` が登録されているとして（テストではその場でパッチするか、別途 sig 登録が必要）。テストフィクスチャとして `input.awk` の先頭に `BEGIN { _DS_SIG_RET["find_title"] = "Option<Str>"; _DS_SIG_ARITY["find_title"] = 1 }` を入れる方法もあるが、テストランナーが `desugar.awk` 経由で動くため、`sig.awk` に一時的に `find_title` を登録するか、テスト用の sig ファイルを用意する。

最もシンプルな方法: `option.none()` / `option.some()` を返す inline 関数をテスト内で定義し、その戻り型を `Option<Str>` とするアノテーション付き関数を使う:

`tests/unit/dsl/option_unwrap_let_option/input.awk`:

```awk
function find_title(id: Str) -> Option<Str> {
  return option.none()
}

function handler() {
  let title ?= find_title(id)
  return ctx.res.text(title)
}
```

`tests/unit/dsl/option_unwrap_let_option/expected.awk`:

```awk
function find_title(id,    _ds_id) {
  _ds_id = type::coerce(id, "Str")
  return option_none_make()
}

function handler(    _ds_tc_1, title) {
  _ds_tc_1 = find_title(id)
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  title = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", title)
}
```

- [ ] **Step 2: テストが FAIL することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_unwrap_let_option"
```

- [ ] **Step 3: `desugar_let.awk` の `?=` 処理を修正する**

`dsl/desugar_let.awk` の `?=` ブロック（`_ds_let_transform` 内）を以下に変更する:

```awk
if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\?=[[:space:]]*(.+)$/, arr)) {
    rhs = _ds_trim(arr[3])
    declared = _ds_infer_type(rhs)
    # Effect を剥がす（Task 6 で追加予定、今は pass-through）
    declared = _ds_strip_effect(declared)
    if (declared != "" && !_ds_is_nullable(declared) && !_ds_all_nullable(declared)) {
      _ds_error(lineno, "?= requires Option or Result, got " declared, \
          "use ?= only with Option<T> or Result<T,E> types")
      return ""
    }
    _DS_tc_count++
    _DS_let_locals[++_DS_let_count] = "_ds_tc_" _DS_tc_count
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_unwrap_union_type(declared)
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(_DS_VAR_TYPES[_DS_func_name, arr[2]])
    _DS_body_buf[++_DS_body_count] = arr[1] "_ds_tc_" _DS_tc_count " = " rhs
    # Option と Result で異なるチェック/値取り出し関数を使う
    if (_ds_is_option(declared)) {
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!option_some(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 404)"
      _DS_body_buf[++_DS_body_count] = arr[1] "}"
      _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = option_val(_ds_tc_" _DS_tc_count ")"
    } else {
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!result_ok(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 500)"
      _DS_body_buf[++_DS_body_count] = arr[1] "}"
      _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = result_val(_ds_tc_" _DS_tc_count ")"
    }
    return ""
}
```

注: `_ds_strip_effect` の実装も今の Step 3 で `typecheck.awk` に追加する（Task 6 Step 1 は確認のみ）:

`dsl/typecheck.awk` の末尾に追加:

```awk
function _ds_strip_effect(t,    m) {
    if (match(t, /^Effect<(.+)>$/, m)) return m[1]
    return t
}
```

- [ ] **Step 4: テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_unwrap_let_option"
```

期待: `PASS: option_unwrap_let_option`

- [ ] **Step 5: 既存の `option_unwrap_ok` / `option_unwrap_error` が壊れていないことを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "option_unwrap"
```

- [ ] **Step 6: コミット**

```bash
git add dsl/desugar_let.awk \
        tests/unit/dsl/option_unwrap_let_option/
git commit -m "fix(let): use option_some/option_val for ?= on Option types"
```

---

## Task 6: `Effect<T>` 型剥がし

**Files:**
- Modify: `dsl/typecheck.awk`
- Modify: `dsl/desugar_let.awk`
- Modify: `dsl/desugar_match.awk`
- Create: `tests/unit/dsl/effect_strip_let/input.awk`
- Create: `tests/unit/dsl/effect_strip_let/expected.awk`
- Create: `tests/unit/dsl/effect_strip_match/input.awk`
- Create: `tests/unit/dsl/effect_strip_match/expected.awk`

- [ ] **Step 1: `_ds_strip_effect` が `typecheck.awk` に存在することを確認する（Task 5 で追加済み）**

```bash
grep "_ds_strip_effect" dsl/typecheck.awk
```

期待: `function _ds_strip_effect` が表示される。未追加なら Task 5 Step 3 の手順で追加する。

- [ ] **Step 2: `effect_strip_let` テストを書く**

`tests/unit/dsl/effect_strip_let/input.awk`:

```awk
function get_cached(key: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  let val ?= get_cached("foo")
  return ctx.res.text(val)
}
```

`tests/unit/dsl/effect_strip_let/expected.awk`:

```awk
function get_cached(key,    _ds_key) {
  _ds_key = type::coerce(key, "Str")
  return option_none_make()
}

function handler(    _ds_tc_1, val) {
  _ds_tc_1 = get_cached("foo")
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  val = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", val)
}
```

- [ ] **Step 3: テストが FAIL することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "effect_strip_let"
```

- [ ] **Step 4: `desugar_let.awk` の `?=` に Effect 剥がしを適用する**

Task 5 のスタブ `_ds_strip_effect` を実装済みの関数で置き換える（typecheck.awk に追加済みのため、desugar.awk が両方を `@include` していれば自動で使える）。

`desugar_let.awk` の `?=` ブロック内の `declared = _ds_strip_effect(declared)` が Task 5 で既に追加されているため、Task 6 では追加作業不要。`_ds_strip_effect` の実装を typecheck.awk に入れることで自動的に機能する。

- [ ] **Step 5: `effect_strip_let` テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "effect_strip_let"
```

期待: `PASS: effect_strip_let`

- [ ] **Step 6: `effect_strip_match` テストを書く**

`tests/unit/dsl/effect_strip_match/input.awk`:

```awk
function get_item(id: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  when get_item(id) of
    some val:
      return ctx.res.text(val)
    none:
      return ctx.res.status(404)
  end
}
```

`tests/unit/dsl/effect_strip_match/expected.awk`:

```awk
function get_item(id,    _ds_id) {
  _ds_id = type::coerce(id, "Str")
  return option_none_make()
}

function handler(    _ds_mc_1, val) {
  _ds_mc_1 = get_item(id)
  if (option_some(_ds_mc_1)) {
    val = option_val(_ds_mc_1)
    return ctx::dispatch("res.text", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

- [ ] **Step 7: `desugar_match.awk` に Effect 剥がしを追加する**

`dsl/desugar_match.awk` の `type_t = _ds_infer_type(_DS_match_expr)` の直後に追加:

```awk
type_t = _ds_strip_effect(type_t)
```

- [ ] **Step 8: `effect_strip_match` テストが PASS することを確認する**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep "effect_strip_match"
```

期待: `PASS: effect_strip_match`

- [ ] **Step 9: 全テスト確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -5
```

期待: FAIL 0

- [ ] **Step 10: コミット**

```bash
git add dsl/typecheck.awk dsl/desugar_let.awk dsl/desugar_match.awk \
        tests/unit/dsl/effect_strip_let/ \
        tests/unit/dsl/effect_strip_match/
git commit -m "feat(dsl): add Effect<T> stripping in ?= and when...of"
```

---

## 完了チェックリスト

- [ ] `dsl/adt.awk`: `option_some_make` / `option_none_make` 追加、エンコーディング変更済み
- [ ] `dsl/desugar_match.awk`: `some:`/`none:` arm が `option_some`/`option_val` を使う
- [ ] `dsl/desugar_dot.awk`: `option.some(x)` → `option_some_make(x)` 変換済み
- [ ] `dsl/sig.awk`: `option.some` / `option.none` 登録済み
- [ ] `dsl/typecheck.awk`: `option_some_make` → `Option<T>` 推論済み、`_ds_strip_effect` 追加済み
- [ ] `dsl/desugar_let.awk`: `?=` が Option/Result を区別し、Effect を剥がす
- [ ] `dsl/desugar_match.awk`: `when...of` が Effect を剥がす
- [ ] 全テスト PASS
