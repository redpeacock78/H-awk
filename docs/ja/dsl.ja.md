🌐 [English](dsl.md) | [← README に戻る](../README.ja.md)

# DSL プリプロセッシング

`bin/hawk` はすべてのアプリケーションファイルを gawk に渡す前に `dsl/desugar.awk` で処理します。以下の変換が適用されます。

**ドット記法 → ディスパッチ**

```awk
# DSL
hawk.app.get("/todos", "list_todos")
ctx.req.form("title")

# 変換後
hawk::dispatch("app.get", "/todos", "list_todos")
ctx::dispatch("req.form", "title")
```

規則：`ns.a.b.c(args)` → `ns::dispatch("a.b.c", args)`。先頭のセグメントがディスパッチャのネームスペースとなり、残りがパス文字列になります。

**`let` → gawk ローカル変数**

```awk
# DSL
function handler() {
  let title = "hello"
  let items = []
  let tmp
  ...
}

# 変換後
function handler(    title, items, tmp) {
  title = "hello"
  delete items
  ...
}
```

`let` 宣言は gawk のローカル変数として関数シグネチャに巻き上げられます（4 スペース慣習）。`let name = []` は `delete name` に変換されます。`let name` のみの宣言は巻き上げだけが行われ、その行は削除されます。

`let` は関数スコープであり、ブロックスコープではありません。`if`・`for`・`while` 内に書かれた `let` も関数シグネチャに巻き上げられるため、ブロック終了後も変数は参照可能です。ストリクトモード（`_DS_strict=1`）では、制御フローブロック内に `let` が現れた場合に警告が出力されます。

**`let` の型アノテーション**

```awk
# 初期値付き型付き let — デシュガー時に静的チェックを実施
function handler() {
  let n: Int = 42
}

# 変換後
function handler(    n) {
  n = 42
}
```

```awk
# 型のみ宣言 — 巻き上げのみ、型付き代入は自動型強制
function handler() {
  let n: Int
  n = "42"   # auto-coerced + static check
}

# 変換後
function handler(    n) {
  n = type::coerce("42", "Int")
}
```

デシュガー時に静的型チェックが行われ、型が一致しない場合はエラーになります：

```sh
# Desugar-time error: string literal assigned to Int
let port: Int = "hello"
# dsl error: app.awk:5: type mismatch: cannot assign Str to Int
```

**ユニオン型アノテーション**

```awk
# Union type: accepts any member type
function handler() {
  let port: Int | Str = env.get("PORT") ?? 8080
}
```

```sh
# Desugar-time error: Bool is not a member of Int | Str
let port: Int | Str = true
# dsl error: app.awk:3: type mismatch: cannot assign Bool to Int|Str
```

`??` 演算子は 2 つのオペランドからユニオン型を推論します（`env.get("PORT") ?? 8080` の場合は `Str | Int`）。組み込みの `Port` 型エイリアスは `Int|NumericStr|Str` に展開されるため、`hawk.app.listen(env.get("PORT") ?? 8080)` は型チェックを通過します。

サポートされる型：`Int`、`Float`、`Str`、`Bool`、`NumericStr`、`Array`、`Map`、`Response`、`Option<T>`、`Result<T, E>`、`Untrusted<T>`、`HtmlEscapedStr`、`HtmlFragment`、`HtmlAttrEscapedStr`、`Void`、`Any`、およびユニオン `A | B`。`HtmlPart` エイリアスは `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr` に展開されます。リテラルと既知の DSL 関数については型推論が機能します。

**関数型アノテーション**

```awk
# Argument and return type annotations (both optional)
function normalize(text: Str) -> Str {
  return text
}

function handler() -> Response {
  let result: Str = normalize("hello")
  return ctx.res.text(result)
}

# Desugared
function normalize(text) {
  return text
}

function handler(    result) {
  result = normalize("hello")
  return ctx::dispatch("res.text", result)
}
```

アノテーションは gawk の出力から除去されます。デシュガー時にのみ使用されます。アノテーションのないパラメータと戻り値型はデフォルトで `Any`（チェックなし）になります。アノテーションにはユニオン型も使用できます：

```awk
function process(id: Int | Str) -> Str {
  return id
}
```

ユーザー定義関数に対するデシュガー時のチェック：

```sh
# Wrong argument type
normalize(123)
# dsl error: app.awk:8: normalize argument 1 expects Str, got Int

# Wrong arity
normalize("a", "b")
# dsl error: app.awk:8: normalize expects 1 argument(s), got 2

# Wrong return type
function hello() -> Response {
  return "hello"
}
# dsl error: app.awk:2: function hello expects return Response, got Str

# Void with value
function setup() -> Void {
  return ctx.res.text("ok")
}
# dsl error: app.awk:2: function setup expects Void, got Response
```

**安全な HTML 出力（`safe.*`）**

`ctx.res.html()` には `HtmlEscapedStr` または `HtmlFragment` が必要です。平文の `Str` 値はデシュガー時に拒否されます。これにより XSS はランタイムの驚きではなくコンパイル時のエラーになります。

`safe.*` ネームスペースには 4 つのサニタイザがあり、それぞれブランド型を生成します：

| 関数 | 入力 | 出力 | 用途 |
|---|---|---|---|
| `safe.html.escape(s)` | `Str\|Untrusted<Str>` | `HtmlEscapedStr` | ユーザー入力テキストを HTML ボディ用にエスケープ |
| `safe.attr.escape(s)` | `Str\|Untrusted<Str>` | `HtmlAttrEscapedStr` | ユーザー入力テキストを HTML 属性用にエスケープ |
| `safe.html.raw(s)` | `Str` | `HtmlFragment` | 信頼の明示 — 既知の安全な文字列にのみ使用 |
| `safe.html.fragment(parts...)` | `HtmlPart` 引数 | `HtmlFragment` | ブランド型の HTML パーツをフラグメントに合成。4 引数以上の可変長呼び出しをサポート |
| `safe.str.trust(s)` | `Untrusted<Str>` | `Str` | 明示的な信頼の宣言 — 変換なしで Untrusted ラッパーを除去 |

`HtmlPart` は `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr` のエイリアスです。`safe.html.fragment` への文字列リテラル引数も信頼済みの静的 HTML として受け入れられます。4 引数以上の呼び出しは可変長フラグメントヘルパー経由で処理されます。

```awk
function render_item(id: Str, title: Str) -> HtmlFragment {
  return safe.html.raw(sprintf(
    "<li id=\"item-%s\">%s</li>",
    safe.attr.escape(id),
    safe.html.escape(title)
  ))
}
```

ブランド型は平文の文字列代入では生成できません。`safe.*` サニタイザのみが生成できます：

```sh
# Desugar-time error: plain Str cannot be passed to ctx.res.html
let html: Str = "<b>hello</b>"
return ctx.res.html(html)
# dsl error: app.awk:3: ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Str

# Desugar-time error: brand type cannot be created by annotation alone
let frag: HtmlFragment = user_input
# dsl error: app.awk:4: brand type HtmlFragment cannot be assigned Untrusted<Str>
```

**文字列補間（`#{...}`）**

`#{expr}` を使用して文字列内に式を埋め込みます。デシュガーによって `sprintf` 呼び出しに展開されます：

```awk
# DSL
let greeting: Str = "Hello, #{name}!"

# Desugared
greeting = sprintf("Hello, %s!", name)
```

1 つの文字列に複数の式を使用できます：

```awk
let msg: Str = "#{first} #{last} (#{age})"
# → sprintf("%s %s (%s)", first, last, age)
```

埋め込まれた式のいずれかが `Untrusted<T>` の場合、結果の変数は `Untrusted<Str>` として推論されます：

```awk
when ctx.req.form("name") of
  ok raw_name:
    let greeting: Str = "Hello, #{raw_name}!"
    # → greeting is Untrusted<Str> because raw_name is Untrusted<Str>
  ng:
    return ctx.res.status(400)
end
```

補間は `safe.html.fragment(...)` 呼び出し内でも使用できます。`#{...}` マーカー間のリテラルテキストは信頼済みの静的 HTML として扱われ、埋め込まれた式は `HtmlPart` として型チェックされます：

```awk
when ctx.req.form("title") of
  ok raw_title:
    return ctx.res.html(safe.html.fragment(
      "<li class=\"item\">#{safe.html.escape(raw_title)}</li>"
    ))
  ng:
    return ctx.res.status(400)
end
```

**正規表現リテラル**

正規表現リテラルは 1 行に収める必要があります。DSL パーサーは複数行にわたる正規表現リテラルをサポートしていません。

**`??` null 合体演算子**

```awk
# DSL
hawk.app.listen(env.get("PORT") ?? 8080)

# Desugared
_ds_tc_1 = env::dispatch("get", "PORT")
hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
```

規則：`expr ?? default` — `expr` が空文字列に評価される場合に `default` を使用します。関数引数の内部でも使用できます。

AWK では欠損値を空文字列で表現するため、`??` は null に相当する欠損値と空文字列の両方をfalsy として扱います。

**`|>` パイプ演算子**

```awk
# DSL
function handler() {
  when ctx.req.form("title") of
    ok raw:
      let safe = raw |> strip()
      return ctx.res.text(safe)
    ng:
      return ctx.res.status(400)
  end
}

# Desugared — temp var injected, inserted as first arg
function handler(    _ds_mc_1, raw, _ds_p_1, safe) {
  _ds_mc_1 = ctx::dispatch("req.form", "title")
  if (result_ok(_ds_mc_1)) {
    raw = result_val(_ds_mc_1)
    _ds_p_1 = strip(raw)
    safe = _ds_p_1
    return ctx::dispatch("res.text", safe)
  } else {
    return ctx::dispatch("res.status", 400)
  }
}
```

規則：`expr |> f(args)` → `expr` 用の一時変数を作成し、`f(tempvar, args)` を呼び出します。左から右へチェーンします。左辺は単純な識別子でなければなりません（複雑な式には先に `let tmp = expr` を使用してください）。

シールドパイプ規則：`Result<T, E>` と `Option<T>` の値は直接パイプできません。先に `?=` または `when...of` でアンラップしてください。

ドット記法の関数もパイプの右辺として使用できます：

```awk
let escaped = raw_title |> safe.html.escape()
# → _ds_p_1 = safe::dispatch("html.escape", raw_title)
```

**`when...of...end` 式**

`Result<T, E>` と `Option<T>` の値に対してパターンマッチを行います。if/else チェーンに変換されます。

```awk
# DSL
function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng err:
      return ctx.res.status(500)
  end
}

# Desugared
function handler(    _ds_mc_1, body, err) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
```

**すべてのアーム形式：**

```
when EXPR of
  # Result<T, E> アーム
  ok name:           # ok — 値を name にバインド
  ok:                # ok — バインドなし
  ng e<TypeName>:    # ng — 型付き、エラーを e にバインド（型によるディスパッチ）
  ng <TypeName>:     # ng — 型付き、バインドなし
  ng name:           # ng — 型なし、エラーを name にバインド
  ng:                # ng — 型なし、バインドなし
  default name:      # キャッチオール、name にバインド
  default:           # キャッチオール、バインドなし

  # Option<T> アーム
  some name:         # some — 値を name にバインド
  some:              # some — バインドなし
  none:              # none — バインドなし（Option のキャッチオールとして扱う）
end
```

**複数の型付き `ng` アーム** — ランタイムにエラー型でディスパッチ：

```awk
type AuthError    = Error
type NotFoundError = Error

function handler() {
  when fetch_user(id) of
    ok user:
      return ctx.res.json(user)
    ng e<AuthError>:
      return ctx.res.status(401)
    ng e<NotFoundError>:
      return ctx.res.status(404)
    default:
      return ctx.res.status(500)
  end
}

# Desugared
function handler(    _ds_mc_1, user, e) {
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
}
```

**`Option<T>` に対する `some`/`none` アーム：**

```awk
# DSL
function handler() {
  when find_title(id) of
    some title:
      return ctx.res.text(title)
    none:
      return ctx.res.status(404)
  end
}

# Desugared
function handler(    _ds_mc_1, title) {
  _ds_mc_1 = find_title(id)
  if (option_some(_ds_mc_1)) {
    title = option_val(_ds_mc_1)
    return ctx::dispatch("res.text", title)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

`ng`/`none`/`default` がない場合はデシュガー時エラーになります。

**ユニオンエラー型の網羅性チェック：** 関数に `-> Result<T, E1 | E2>` のアノテーションがある場合、型付き `ng` アームはすべてのユニオンメンバーを網羅するか、`default:`/`ng:` のキャッチオールアームが必要です：

```sh
# Desugar-time error: NotFoundError arm is missing
function handler() {
  when fetch_user(id) of
    ok user:
      return ctx.res.json(user)
    ng e<AuthError>:
      return ctx.res.status(401)
  end
}
# dsl error: app.awk:9: when...of missing arm for NotFoundError (add 'ng e<NotFoundError>:' or 'default:')
```

**`type` 宣言**

カスタムエラー型を定義して `ng` アームで使用します：

```awk
# DSL
type AuthError    = Error
type NotFoundError = Error

# Desugared
function AuthError(msg)     { return result_ng("AuthError", msg) }
function NotFoundError(msg) { return result_ng("NotFoundError", msg) }
```

関数での使用例：

```awk
function fetch_user(id) -> Result<Str, AuthError | NotFoundError> {
  if (!authenticated()) return AuthError("token expired")
  if (!found(id))       return NotFoundError("user " id)
  return result_ok_make(id)
}
```

**ユニオン型とインターセクション型のエイリアス**

`|`（ユニオン）または `&`（インターセクション）で型エイリアスを定義します：

```awk
type Status   = Int | Str          # Status accepts Int or Str
type Config   = Str | Int | Bool   # multi-member union
type Precise  = Int & Str          # Precise requires both Int and Str
```

それぞれがバリデータ関数を生成し、型エイリアスを登録します：
```awk
# Desugared
function Status(val) { if (type::accepts("Int|Str", val)) return val; return result_ng("TypeError:Status", "expected Int|Str, got " val) }
```

関数シグネチャでの使用：
```awk
function parse(raw: Str) -> Int | Str {
  return 42
}
```

`let` アノテーションとしての使用：
```awk
function handler() {
  let port: Int | Str = env.get("PORT")
}
```

**ADT エンコーディング**

`Result` と `Option` の値は ASCII Unit Separator（`\x1F`、U+001F）を使った文字列としてエンコードされます：

| 状態 | エンコーディング |
|---|---|
| `ok(val)` | `"ok\x1F" val` |
| `ng(TypeName)` | `"ng\x1F" TypeName` |
| `ng(TypeName, msg)` | `"ng\x1F" TypeName "\x1F" msg` |
| `some(val)` | `"some\x1F" val` |
| `none` | `"none\x1F"` |

センチネルプレフィックスにより、空文字列を保持する `Option<Str>` は `none` と区別できます。

ランタイムヘルパー（`dsl/adt.awk` で定義、常に利用可能）：

```awk
result_ok(v)              # → 1 if v is ok
result_val(v)             # → inner value of ok
result_ok_make(val)       # → ok-encoded string
result_ng(type, msg)      # → ng-encoded string
result_err_type(v)        # → TypeName of ng value
result_err(v)             # → "TypeName" or "TypeName\x1Fmsg"

option_some(v)            # → 1 if some
option_none(v)            # → 1 if none
option_val(v)             # → inner value of some
option_some_make(val)     # → some-encoded string
option_none_make()        # → none-encoded string
```

**`option.some` / `option.none` の構築**

`option.*` ネームスペースを使って DSL コード内で `Option<T>` の値を構築します：

```awk
# DSL
function find_title(id: Str) -> Option<Str> {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}

# Desugared
function find_title(id) {
  if (!(id in rows)) {
    return option_none_make()
  }
  return option_some_make(rows[id])
}
```

`option.some(val)` は `val` の型から戻り値型を `Option<T>` として推論します。明示的なアノテーションは不要です。`option.none()` は `Option<Any>` を返し、任意の `Option<T>` アノテーションと互換性があります。

**`?=` 安全アンラップ演算子**

`Result<T, E>` または `Option<T>` の値を 1 ステップでアンラップします。失敗した場合、ハンドラはエラーステータスで早期リターンします。`Option` の `none` は 404 を返します。`Result` の `ng` はエラー型を HTTP ステータスコードにマッピングします：`ParseError` → 400、`AuthError` → 401、`NotFoundError` → 404、その他のエラー → 500。右辺の型が `Option` または `Result` の場合にのみ有効です。

```awk
# DSL — Result<T, E> (returns by error type on ng)
function create_todo() {
  let body ?= ctx.req.json()
  # body is now the unwrapped Untrusted<Str> value
}

# Desugared
function create_todo(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
    return ctx::dispatch("res.status", 500)
  }
  body = result_val(_ds_tc_1)
}
```

```awk
# DSL — Option<T> (returns 404 on none)
function handler() {
  let title ?= find_title(id)
  return ctx.res.text(title)
}

# Desugared
function handler(    _ds_tc_1, title) {
  _ds_tc_1 = find_title(id)
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  title = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", title)
}
```

右辺の型が `Option` または `Result` でない場合はデシュガー時エラーになります：

```sh
let port ?= env.get("PORT")
# dsl error: app.awk:5: ?= requires Option or Result, got Str
```

`?=` アンラップ後、変数は `Untrusted<T>` を保持します。HTML 出力で使用する前に `safe.*` サニタイザに渡してください。

**`Effect<T>` 型アノテーション**

`Effect<T>` は、将来的に非同期化される関数（キャッシュ参照、データベースクエリなど）のための型レベルラッパーです。関数に `-> Effect<Option<Str>>` や `-> Effect<Result<T, E>>` のアノテーションを付けることで、呼び出し元を変更せずに意図を表明できます。`?=` と `when...of` は `Effect` ラッパーを自動的に除去してから通常の `Option`/`Result` 処理を行います。

```awk
# DSL
function get_cached(key: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  let val ?= get_cached("foo")   # Effect<Option<Str>> → Option<Str> → unwrap
  return ctx.res.text(val)
}
```

```awk
# DSL — when...of also strips Effect
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

ランタイムでは AWK は同期的であり、`Effect` はオーバーヘッドなしのパススルーです。このアノテーションは将来的に非同期実行を追加する際に呼び出し元の変更が不要になるよう存在します。

**`classify:` アノテーション**

```awk
function strip(s: Str) -> Str {
  classify: transform
  return s
}
```

関数のデータフローにおける役割を示します：
- `transform` — `Untrusted<T>` 入力を受け付け、入力が信頼されていない場合は `Untrusted` を出力に伝播
- `validator` — `Untrusted<T>` 入力を受け付け、`Untrusted` ラッパーを除去して平文の `T` を返す（検証済みだがサニタイズはしない）
- `sanitizer` — `Untrusted<T>` 入力を受け付け、ブランド安全な出力（例：`HtmlEscapedStr`）を生成
- `sink` — 終端コンシューマ（出力なし）

つまり、`classify: validator` は検証済みの `Untrusted<T>` の結果を平文の `T` に変換しますが、HTML 安全なブランドは生成しません。

`classify:` 行は gawk 出力から除去されます。アノテーション専用です。

**DSL 関数呼び出しのチェック**

デシュガーはすべての組み込み DSL 関数とユーザー定義のアノテーション付き関数のアリティと引数型を検証します：

```sh
# Wrong number of arguments
ctx.res.status()
# dsl error: app.awk:5: ctx.res.status expects 1 argument(s), got 0

# Wrong argument type
ctx.res.status("ok")
# dsl error: app.awk:5: ctx.res.status argument 1 expects Int, got Str
```

型アノテーション付きのユーザー定義関数も同様にチェックされます。前方参照も機能します。ソースファイルで定義される前に関数を呼び出すことができます。

生成されたファイルを検査するには `--debug` を使用します：

```sh
./bin/hawk serve --debug app.awk   # prints temp file path to stderr
```
