# H-awk Full Review Fix 設計仕様

## 概要

本仕様は、H-awk リポジトリのコードレビューで発見された、優先度の高い不整合とランタイム上の危険性を修正する作業を定義する。
広範なリライトは行わず、小さく検証可能な変更を積み重ねる方針をとる。
ただし P0-3（TSV ロック）、P1-2（`ctx.res.json` セマンティクス変更）は破壊的変更を含む。
いずれも既存コードの誤りを修正するものであり、互換維持より正しい動作を優先する。

対象となるリポジトリの構成は以下のとおりである。

- `bin/hawk` および `libexec/hawk-*` による CLI 層
- `dsl/desugar.awk` を中心とする DSL-to-AWK コンパイラ
- 型付き DSL シグネチャと型チェック
- `Result` / `Option` ADT ランタイム
- safe HTML ブランディング
- gawk HTTP ランタイム
- オプションの Zig ネイティブライブラリ（`libs/net`）

---

## Phase 0: ベースライン検証

コードを変更する前に、現在のテストスイートを実行して既存の失敗を記録する。
新たな回帰と既存の失敗を混同しないようにするためである。

実行コマンドは以下のとおりである。

```sh
make lint
make test-dsl
make test-unit
make test-e2e
make ci
zig version || true
```

Zig 0.13 以上が利用可能な場合は、追加で以下を実行する。

```sh
make test-libs
make ci-full
```

---

## Phase 1: P0 Critical Fixes

### P0-1: `libs/net` リクエスト完全受信の保証

#### 問題

`libs/net/src/event_loop.zig` は、接続バッファに `\r\n\r\n` が存在した時点でリクエストを完了とみなす。
POST / PUT リクエストではリクエストボディが後続の TCP パケットで到着することがあるため、この実装は不完全なリクエストをエンキューする危険性がある。

#### 要求仕様

リクエストが完了したとみなす条件は以下の 3 つをすべて満たすこととする。

1. ヘッダー終端子 `\r\n\r\n` がバッファに存在する。
2. `Content-Length` の有無を確定済みである（存在すること、または存在しないことが確認されていること）。
3. バッファが `header_end + 4 + content_length` バイト以上のデータを保持している。

`Content-Length` が存在しないリクエストは、ボディ長を 0 として扱う。
これは GET / DELETE / HEAD など本来ボディを持たないメソッドに対する安全なデフォルトである。
POST / PUT に `Content-Length` が存在しない場合も 0 として扱い、ボディは受け取らない（クライアントが `Content-Length` を省略した場合は不正なリクエストとみなす）。

`Transfer-Encoding: chunked` はサポート対象外とし、`501 Not Implemented` を返してから接続を閉じる。
残余バイトを接続バッファに保持したまま次のリクエストを試みてはならない。

Keep-alive に対応するため、1 バッファに複数の完全なリクエストが含まれる場合は以下の処理とする。

1. 完全なリクエストを 1 件だけ解析してエンキューする。
2. 残余バイトを接続の読み取りバッファに保持する。
3. 次のループ / 読み取りで残余バイトを処理する。

#### 変更対象ファイル

- `libs/net/src/event_loop.zig`
- `libs/net/src/http_parser.zig`
- `libs/net/tests/net_test.zig`

#### 追加するテスト

ヘッダーを先に送信し、ボディを後から送信するシナリオで、以下をすべて検証するテストを追加する。

- ボディ全体が到着する前にリクエストがエンキューされないこと。
- ボディ全体が到着した後にリクエストが正しくエンキューされること。
- ボディの内容が完全に保持されていること。
- `Transfer-Encoding: chunked` リクエストに対して `501` を返し、接続を閉じること。

テストはネットワーク層の分割送信を再現するため、`curl` ではなく raw ソケットで実装する。

---

### P0-2: DSL シグネチャとランタイムの arity 不整合修正

#### 問題

一部の API において、ランタイムのディスパッチテーブル、`dsl/sig.awk`、README ドキュメントの 3 者間で arity が一致していない。
既知の不整合は以下のとおりである。

- `hawk.app.on`: ランタイムは 3 引数（method, path, handler）だが、DSL シグネチャは 2 引数
- `ctx.res.redirect`: ランタイムは 2 引数（url, code）をサポートするが、DSL シグネチャは 1 引数のみ
- `safe.html.fragment`: README は可変長引数と説明しているが、ランタイムは 3 引数のみ受け付ける

#### 要求仕様

**`hawk.app.on`** の論理的なシグネチャは以下とする。

```
(Str|Array, Str|Array, HandlerName) -> Void
```

`dsl/sig.awk` の arity を 3 に修正し、偽の型エラーが発生しないようにする。

**`ctx.res.redirect`** はオプション引数形式を採用する。

```awk
ctx.res.redirect(url)        # 302 を使用
ctx.res.redirect(url, code)  # 任意のリダイレクトコード
```

`dsl/sig.awk` における arity の扱いを、オプション引数に対応するよう修正する。

**`safe.html.fragment`** は可変長引数に対応する。
実装方法は `safe.html.fragment` 専用のスペシャルケースとし、汎用的な `hawk_dispatch::callv` は導入しない。
`hawk_dispatch::callv` の導入は `core/dispatch.awk`、DSL シグネチャ、ランタイム API に対して広範な変更を要するため、本フェーズのスコープ外とする。

#### 変更対象ファイル

- `dsl/sig.awk`
- `core/hawk.awk`
- `core/ctx.awk`
- `core/safe.awk`
- `core/dispatch.awk`
- `README.md`
- `tests/unit/dsl/` 内の関連 fixtures

#### 追加するテスト

- `hawk.app.on("GET", "/x", "h")` の DSL チェックが通ること。
- `ctx.res.redirect("/x")` の DSL チェックが通ること。
- `ctx.res.redirect("/x", 303)` の DSL チェックが通ること。
- `safe.html.fragment` に 4 引数以上を渡した場合のランタイムテスト。

---

### P0-3: TSV ストレージへの書き込みロック追加

#### 問題

TSV ヘルパー関数は複数ワーカーによる同時書き込みに対して安全でない。
具体的な危険性は以下のとおりである。

- `append_tsv` はロックなしで追記する。
- `delete_tsv` と `update_tsv` は固定のパス `path ".tmp"` を一時ファイルに使用しており、複数ワーカーが同一パスを競合して書き込む。
- `libs/net` が存在する場合はマルチワーカーモードが有効になるため、デモアプリの `data/todos.tsv` が破損するリスクがある。

#### 要求仕様

AWK から `flock(1)` を呼び出すためのシェルラッパー関数 `tsv_lock(path)` および `tsv_unlock(path)` を実装する。
具体的には gawk の `system()` または `|&` プロセス置換を使って以下のロック操作を行う。

```
# ロック取得（最大 5 秒リトライ）
flock -w 5 "$lockfile" true

# ロックファイルパス
path ".lock"
```

`flock` が存在しない環境では、`mkdir "$path.lock"` を使ったアトミックなロックディレクトリ方式にフォールバックする。
リトライ間隔は 0.1 秒、最大リトライ回数は 50 回（合計 5 秒）とする。
ロック取得に失敗した場合は書き込みを中断してエラーを返す。

ロックファイルは書き込み完了後に必ず解放する。
gawk の `ENDFILE` ルールではなく、各関数の終端で明示的に解放処理を呼ぶ。

一時ファイルのパスは以下の形式とし、競合を回避する。
`srand(PROCINFO["pid"] + systime())` を初回呼び出し時に必ず実行してから `rand()` を使う。

```
path ".tmp." PROCINFO["pid"] "." systime() "." int(rand() * 1000000)
```

#### 変更対象ファイル

- `core/tsv.awk`
- `tests/unit/test_tsv.awk`

#### 追加するテスト

- `delete_tsv` と `update_tsv` が固定の共有 tmp パスを使用していないこと。
- ロック実装後、繰り返し書き込みを行うスモークテストが通ること。

---

### P0-4: DSL 波括弧カウントの文字列・コメント認識

#### 問題

`_ds_net_braces` は文字列リテラルおよびコメント内の `{` と `}` もカウントしている。
これにより、以下のような関数境界の追跡が誤った結果を生む。

```awk
function f() -> Str {
  let json: Str = "{\"ok\": true}"
  return json
}
```

上記のコードでは文字列内の `{}` がカウントされ、関数の終端検出が失敗する。

#### 要求仕様

`_ds_net_braces` のカウント対象をコードセグメントのみに限定する。
文字列リテラルおよびコメント内の波括弧はカウントしない。
既存のヘルパー `_ds_split_code_segs()` を使って実装し、生の文字スキャンを置き換える。

`_ds_split_code_segs()` が以下のケースを正しく処理することを実装前に確認し、対応していない場合は先に修正する。

- エスケープシーケンスを含む文字列（例: `"{\"ok\": true}"`）
- 複数行にまたがる文字列連結
- コメント行（`#` 以降）

#### 変更対象ファイル

- `dsl/desugar.awk`
- `dsl/desugar_strings.awk`（`_ds_split_code_segs()` に不足がある場合）
- `tests/unit/dsl/` 内の新規 fixtures

#### 追加するテスト

以下の各パターンに対応する DSL fixtures を追加する。

- `{` を含む文字列リテラル
- `}` を含む文字列リテラル
- エスケープ済み引用符を含む JSON 文字列を内部に持つ関数
- `{` を含むコメント
- `}` を含むコメント

---

## Phase 2: P1 Correctness Fixes

### P1-1: `ctx.req.*` の欠損と空値の区別

#### 問題

現在のヘルパーは空文字列と欠損キーを同一視している。
たとえば `title=` のようにフォームフィールドが存在しても値が空の場合、以下のパターンは欠損として誤判定する。

```awk
v = ctx::req["form:" key]
return v != "" ? result_ok_make(v) : result_ng("ParseError", "missing " key)
```

#### 要求仕様

値チェック（`v != ""`）をキー存在チェック（`("form:" key) in ctx::req`）に置き換える。
適用対象は以下のとおりである。

- `ctx::query`
- `ctx::param`
- `ctx::get_header`
- `ctx::req_form`
- `ctx::req_json`

`ctx::body` については以下のセマンティクスを明示する。
リクエストに `Content-Length: 0` が存在する場合、またはボディ区切り後に読み取れるバイト列が 0 バイトの場合は `ok("")` を返す。
ヘッダーが完全に受信されておらずボディの有無が未確定の場合のみ欠損として扱い、`ParseError` を返す。

#### 変更対象ファイル

- `core/ctx.awk`
- `tests/unit/test_ctx.awk`
- `tests/unit/test_request.awk`

#### 追加するテスト

- 空値を持つクエリパラメータが `ok("")` を返すこと（`?key=` の形式）。
- 空値を持つフォームフィールドが `ok("")` を返すこと（`key=` の形式）。
- 欠損キーが `ParseError` を返すこと。
- 空ボディ（`Content-Length: 0`）が `ok("")` を返すこと。

---

### P1-2: `ctx.res.json` セマンティクスの修正

#### 問題

低レベルの `response.awk` における `json(res, data)` は `json_encode(data)` でデータをエンコードする。
一方、コンテキストヘルパー `ctx::json(data)` はデータをエンコードせずそのままレスポンスボディに入れる。
この非対称性により、`ctx.res.json` は事実上 `ctx.res.json_raw` として動作している。

#### 要求仕様

`ctx.res.json(data)` は AWK 配列または値を `json_encode` でエンコードしてからレスポンスボディにセットする。
エンコード規則は以下のとおりである。

- AWK 配列：`json_encode` が処理するオブジェクト / 配列形式に変換する
- 文字列スカラー：JSON 文字列（`"..."` 形式）に変換する
- 数値スカラー：JSON 数値（クォートなし）に変換する

事前エンコード済みの JSON 文字列を直接セットするためのヘルパーとして `ctx.res.json_raw(str)` を追加する。

この変更は破壊的変更である。`ctx.res.json` に pre-encoded JSON 文字列を渡している既存コードはすべて二重エンコードになる。
修正対象のファイルは以下のとおりである（すべて確認・修正すること）。

- `app.awk`
- `tests/e2e/fixtures/app.awk`
- `tests/unit/test_ctx.awk` 内の既存テスト

#### 変更対象ファイル

- `core/response.awk`
- `core/ctx.awk`
- `dsl/sig.awk`
- `app.awk`
- `README.md`
- `tests/unit/test_ctx.awk`
- `tests/e2e/fixtures/app.awk`

#### 追加するテスト

- `ctx.res.json(data)` が AWK 配列を JSON オブジェクトにエンコードして返すこと。
- `ctx.res.json("hello")` が `"hello"` という JSON 文字列を返すこと（二重エンコードではないこと）。
- `ctx.res.json_raw(str)` が文字列をそのままボディにセットすること。
- e2e の `/echo` エンドポイントが引き続き有効な JSON を返すこと。

---

### P1-3: `when...of` パイププリルードへの dot 変換適用

#### 問題

通常の関数本体内では、パイプが生成するプリルード行に `_ds_dot_transform` が適用される。
`when...of` 本体内では、`_ds_match_process_body` がパイププリルード行を `_DS_body_buf` に挿入する際、`_ds_dot_transform` を適用していない場合がある。
この結果、以下のような変換されていないコードが出力される。

```awk
_ds_p_1 = safe.html.escape(raw)
```

正しい出力は以下となるべきである。

```awk
_ds_p_1 = safe::dispatch("html.escape", raw)
```

#### 要求仕様

`_ds_match_process_body` において、`pipe_pre[p]` を `_DS_body_buf` に追加する前に `_ds_dot_transform` を適用する。

#### 変更対象ファイル

- `dsl/desugar_match.awk`
- `tests/unit/dsl/` 内の新規 fixture

#### 追加するテスト

以下の入力に対して、出力に `safe::dispatch("html.escape", raw)` が含まれ、`safe.html.escape(raw)` が含まれないことを検証する。

```awk
function h() -> Response {
  when ctx.req.form("title") of
    ok raw:
      let escaped = raw |> safe.html.escape()
      return ctx.res.html(escaped)
    ng:
      return ctx.res.status(400)
  end
}
```

---

### P1-4: `when...of` catch-all アームの順序バリデーション

#### 問題

`default:` または非型付き `ng:` は `else { ... }` を生成する。
catch-all アームの後に型付き `ng e<Foo>:` が続く場合、生成される AWK コードが構文的に無効になる。

```awk
else {
  ...
} else if (...) {
  ...
}
```

#### 要求仕様

catch-all アームは `when...of` 式の最後のエラーアームとしてのみ許可し、それ以外の位置ではデシュガー時にエラーを出力する。

**catch-all アーム**の種類は以下のとおりである。

- `ng:`（Result の非型付きエラーキャッチ）
- `ng err:`（Result の非型付きエラーキャッチ、変数束縛あり）
- `default:`（Result の非型付きキャッチオール）
- `default err:`（同上、変数束縛あり）
- `none:`（Option の非型付きキャッチ。`ok` アームが存在する場合の最終アーム）

`none:` は Option 式の最終アームとして許可する。
Result 式と Option 式が混在する `when...of` はサポート対象外であり、混在が検出された場合は別途エラーを出力する。

catch-all アームの後に型付きアームが続く場合は、以下のエラーメッセージを出力する。

```
catch-all arm must be last
```

#### 変更対象ファイル

- `dsl/desugar_match.awk`
- `tests/unit/dsl/` 内の新規 fixture
- `README.md`

#### 追加するテスト

以下の無効な入力に対して `catch-all arm must be last` エラーが出力されることを検証する。

```awk
when fetch_user(id) of
  ok user:
    return ctx.res.text(user)
  default:
    return ctx.res.status(500)
  ng e<AuthError>:
    return ctx.res.status(401)
end
```

---

### P1-5: `render()` パスの制限

#### 問題

`template_read(path)` は任意のパスを読み取れる。
アプリコードが信頼できない入力を `ctx.res.render` に渡すと、任意ファイル読み取りになる。

#### 要求仕様

テンプレートパスをランタイムで検証し、以下のパスのみを許可する。

- `views/` プレフィックスで始まる相対パス

以下のパスは拒否してエラーレスポンス（500）を返す。

- 絶対パス（`/` で始まるパス）
- `..` を含むパス
- 空文字列

さらに、`realpath` コマンドが利用可能な場合は `system("realpath ...")` でパスを正規化し、解決後のパスが作業ディレクトリ配下の `views/` に収まることを確認する。
`realpath` が利用できない場合は文字列ベースのチェックのみとし、README にシンボリックリンクによる制限回避の可能性を注記する。

長期的な設計として `TemplatePath` ブランド型の導入を検討するが、本フェーズでは短期的なランタイムチェックのみを実装する。

#### 変更対象ファイル

- `core/template.awk`
- `core/response.awk`
- `core/ctx.awk`
- `dsl/sig.awk`
- `README.md`
- `tests/unit/test_template.awk`

#### 追加するテスト

- `ctx.res.render("views/index.html")` が成功すること。
- `ctx.res.render("../secret")` が失敗すること。
- 絶対パスが失敗すること。
- 空文字列が失敗すること。

---

## Phase 3: P2 Design Cleanup

### P2-1: `?=` エラーマッピングの改善

#### 問題

`?=` は現在、型に関わらず `Option none` を `404`、`Result ng` を `500` にマッピングする。
リクエスト解析エラーや認証エラー、バリデーションエラーを正しく表現できない。

#### 要求仕様

エラー型に基づくデフォルトマッピングを導入する。

- `ParseError` → 400
- `AuthError` → 401
- `NotFoundError` → 404
- 未知のエラー → 500
- `Option none` → 404（従来どおり）

型判定は `result_ng` の第 1 引数（エラー種別文字列）に対する文字列一致で実装する。
`Option none` は引き続き 404 にマッピングし、上記テーブルには含めない。

将来的には `let body ?= ctx.req.json() else 400` のような構文拡張を検討する。

#### 変更対象ファイル

- `dsl/desugar_nullcoalesce.awk`
- `README.md`

---

### P2-2: `classify: validator` セマンティクスの修正

#### 問題

README は `validator` が `Untrusted<T>` を受け取り plain `T` を返すと説明しているが、現在の実装は `transform` と同じ動作をしており `Untrusted` ラッパーを保持している。

#### 要求仕様

各 classify 種別のデータフローセマンティクスを以下のとおり定義する。

- **`transform`**: `Untrusted<T>` → `Untrusted<T>`（ラッパーを保持）
- **`validator`**: `Untrusted<T>` → `T`（ラッパーを除去）
- **`sanitizer`**: ブランドセーフな型を返す
- **`sink`**: 終端コンシューマー

`validator` によるバリデーション失敗の表現は DSL 型エラーとする。
`Untrusted<T>` を `validator` 関数に渡した場合、戻り値の型は `T` として扱われる。
検証ロジック自体が失敗する（`Result<T, E>` を返す）場合は、`classifier: validator` ではなく通常の関数として実装する。

#### 変更対象ファイル

- `dsl/type_dataflow.awk`
- `README.md`
- 関連テスト

---

### P2-3: 複合型再代入での `type::coerce` 回避

#### 問題

型付き再代入は現在 `type::coerce(rhs, "Type")` でラップする。
`type::coerce` がサポートするのは `Int`、`Float`、`Str`、`Bool` のみであるため、以下の複合型への再代入がランタイムエラーになる。

- union 型
- alias 型
- ブランド型
- `Option<T>`
- `Result<T, E>`
- `Effect<T>`

#### 要求仕様

複合型への再代入では `type::coerce` を使用しない。
代わりに `type::accepts(val, "TypeName")` を呼び出すランタイムアサーションヘルパーを生成する。

`type::accepts` の契約は以下のとおりである。

- 引数：値と型名文字列
- 戻り値：型が一致する場合は `val` をそのまま返す
- 型不一致の場合：gawk の `_hawk_fatal` でランタイムエラーを出力して終了する
- サポートする型名：`type.awk` に登録されているすべての型（プリミティブ・union・alias・ブランド・`Option<T>`・`Result<T,E>`・`Effect<T>`）
- ブランド型への強制変換は `type::accepts` でも行わない

静的型チェックで代入の型整合性が確定している場合は `type::accepts` の呼び出し自体を省略する。

#### 変更対象ファイル

- `dsl/desugar_let.awk`
- `dsl/type.awk`
- 関連テスト

---

### P2-4: レスポンスヘッダー名のバリデーション

#### 問題

ヘッダーの値から CRLF を除去しているが、ヘッダー名はバリデーションしていない。
無効なヘッダー名が `response_wire` から出力される可能性がある。

#### 要求仕様

以下の正規表現に一致しないヘッダー名は出力を拒否し、警告ログを出力する。
ヘッダーを無視して処理を継続するのではなく、そのヘッダーを含むレスポンス出力全体を中断してエラーレスポンスに切り替える。

```
^[!#$%&'*+.^_`|~0-9A-Za-z-]+$
```

「無視」ではなく「拒否」とする理由は、無効なヘッダー名がサイレントに欠落すると API の呼び出し元がデバッグできないためである。

#### 変更対象ファイル

- `core/response.awk`
- `tests/unit/test_response.awk`

#### 追加するテスト

- 有効なカスタムヘッダーが出力されること。
- 改行文字を含むヘッダー名が拒否されること。
- コロンを含むヘッダー名が拒否されること。
- スペースを含むヘッダー名が拒否されること。

---

### P2-5: プラグイン探索の堅牢化

#### 問題

`plugin_discover()` はプラグインディレクトリごとに `plugin_<name>_manifest` 関数を無条件で呼び出す。
有効な manifest 関数を持たないディレクトリが存在する場合、gawk が失敗する。

#### 要求仕様

`manifest.awk` を持たないプラグインディレクトリはスキップして警告を出力し、存在しない関数を indirect-call しない。
`manifest.awk` は存在するが `plugin_<name>_manifest` 関数が定義されていない場合も同様にスキップして警告を出力する。
関数の存在確認には gawk の `@include` 後に `(funcname) in FUNCTAB` で検証する。

#### 変更対象ファイル

- `core/plugin.awk`
- `libexec/hawk-libs`
- 関連テスト

---

## Phase 4: README 更新

Phase 1〜3 の実装完了後、`README.md` を以下の観点で更新する。

1. H-awk のアーキテクチャを明示する（CLI ラッパー、libexec サブコマンド、DSL プリプロセッシング、gawk ランタイム、オプションの Zig ライブラリの関係）。
2. TSV ストレージのロック実装（`flock` / `mkdir` フォールバック）を説明し、マルチワーカーでの利用条件を明示する。
3. `ctx.res.json` が AWK 配列と値を JSON エンコードすること、および `ctx.res.json_raw` が事前エンコード済み文字列用であることを説明する。
4. `safe.html.fragment` が可変長引数を受け付けることを明示する。
5. `render()` が `views/` 配下のパスのみを許可すること、および `realpath` が利用できない環境ではシンボリックリンクによる制限回避の可能性があることを注記する。
6. `?=` のデフォルトエラーマッピング（型別対応表）を記載する。
7. 以下の使用例を追加する。
   - `hawk.app.on`（3 引数形式）
   - `ctx.res.redirect`（オプション引数形式）
   - `when...of` 基本構造
   - `when` アーム内のパイプ
   - 空フォーム値の処理

---

## Phase 5: 最終検証

全 Phase 完了後に以下を実行し、すべてのテストが通ることを確認する。

```sh
make lint
make test-dsl
make test-unit
make test-e2e
make ci
```

Zig 0.13 以上が利用可能な場合は追加で以下を実行する。

```sh
make test-libs
make ci-full
```

---

## 受け入れ条件

本作業の完了条件は以下のとおりである。

- 既存のテストがすべて通ること。
- 新しい回帰テストがすべて通ること。
- `hawk.app.on` の arity がランタイムと DSL チェッカーで一致していること。
- `ctx.res.redirect` の動作がランタイムと DSL チェッカーで一致していること。
- `safe.html.fragment` の動作がランタイム、DSL チェッカー、README で一致していること。
- `libs/net` が不完全な POST ボディをエンキューしないこと。
- `libs/net` が `Transfer-Encoding: chunked` に対して `501` を返し接続を閉じること。
- `ctx.req.form("x")` が `x=` に対して `ok("")` を返すこと。
- `ctx.res.json(data)` が AWK 配列を JSON エンコードすること。
- `when` アーム内のパイプ右辺の dot 記法が正しくデシュガーされること。
- 文字列内の波括弧が関数境界の解析を壊さないこと。
- TSV ストレージがロックによって安全に使用できること。
- 無効なレスポンスヘッダー名が拒否されること。
- README が実際の動作と一致していること。

---

## コミット分割方針

以下の順序でコミットを分割する（フェーズ順に対応）。

```
fix(net): wait for complete content-length body before enqueue
fix(net): return 501 and close connection for chunked encoding
fix(dsl): align signature arities with runtime dispatch
fix(tsv): add flock-based write locking with mkdir fallback
fix(dsl): ignore braces inside strings and comments
fix(ctx): distinguish missing request keys from empty values
fix(ctx): encode data in ctx.res.json, add json_raw helper
fix(dsl): transform pipe preludes inside when arms
fix(dsl): reject catch-all when arms before typed arms
fix(template): restrict render path to views/ directory
fix(response): reject invalid header names
fix(dsl): fix validator classify to unwrap Untrusted
fix(dsl): avoid type::coerce for complex type reassignment
fix(dsl): improve ?= error type mapping with type-based defaults
fix(plugin): tolerate missing manifest in plugin discovery
docs: clarify storage, json, render, and DSL semantics
test: add regressions for reviewed edge cases
```
