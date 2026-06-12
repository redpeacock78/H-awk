# hawk DSL レイヤー 設計仕様

**作成日**: 2026-06-12  
**ステータス**: 承認待ち

---

## 概要

hawk に AWK++ にインスパイアされた DSL レイヤーを追加する。  
ユーザーは `hawk.app.get(...)` のようなドット記法とローカル変数宣言 `let` を使って記述し、起動時に一度だけ純粋な gawk スクリプトへ変換（デシュガー）してから実行する。

---

## セクション 1: ディレクトリ構造

```
dsl/                        # デシュガーツール専用（アプリコードは置かない）
  desugar.awk               # エントリポイント: @include + メイン処理ループ
  desugar_state.awk         # 共有状態: brace_depth, in_function, current_func 等
  desugar_strings.awk       # 文字列・コメント領域の検出（誤変換防止）
  desugar_dot.awk           # ドット記法 → hawk::dispatch(...) 変換
  desugar_let.awk           # let 宣言収集 + function シグネチャへの巻き上げ

tests/unit/dsl/             # デシュガー単体テスト（フィクスチャ方式）
  dot_basic/
  let_hoist/
  string_no_mangle/
  ...

examples/dsl/               # DSL 記法のサンプルアプリ（e2e テスト用）
```

アプリコード（例: `app.awk`）はプロジェクトルートまたは任意の場所に配置する。`dsl/` はツールのみ。

---

## セクション 2: 変換パイプライン

### 2-1. ドット記法 → 動的ディスパッチ

**対象パターン**: 文字列・コメント領域外の `identifier.identifier[.identifier]*(` 

変換ルール: `ns.a.b.c(args)` → `ns::dispatch("a.b.c", args)`  
先頭セグメントがネームスペース（ディスパッチャ）、残りがパス文字列になる。

```awk
# DSL 記法
hawk.app.get("/", "todo_index")   # ns=hawk, path="app.get"
hawk.csrf.token.verify("abc")     # ns=hawk, path="csrf.token.verify"
ctx.req.form("title")             # ns=ctx,  path="req.form"

# デシュガー後
hawk::dispatch("app.get", "/", "todo_index")
hawk::dispatch("csrf.token.verify", "abc")
ctx::dispatch("req.form", "title")
```

変換ロジック:
1. `desugar_strings.awk` で文字列・コメント領域を特定
2. 文字列外の箇所でドット連鎖 + `(` にマッチ
3. ドットで分割してパス文字列を構築
4. 引数部分はネスト括弧を考慮して末尾 `)` まで抽出

### 2-2. `let` 宣言 → gawk ローカル変数巻き上げ

gawk のローカル変数はシグネチャ末尾に空白区切りで宣言する慣習を利用する。

```awk
# DSL 記法
function todo_add() {
  let row = []
  let title = ctx.req.form("title")
  ...
}

# デシュガー後
function todo_add(    row, title) {
  delete row
  title = ctx::dispatch("req.form", "title")
  ...
}
```

変換ロジック:
1. `function` 定義行でスコープ開始、`let` 収集バッファを初期化
2. `let name` → バッファ追加、行を削除
3. `let name = expr` → バッファ追加、行を `name = expr` に変換
4. `let name = []` → バッファ追加、行を `delete name` に変換
5. スコープ対応する `}` 検出時にシグネチャを書き換えて出力

`brace_depth` カウンタでネストを追跡する。

---

## セクション 3: `bin/hawk` 統合

### デシュガーの起動条件

常時実行。プレーンな AWK ファイルはパススルーとなるため条件分岐不要。

### mktemp 方式（推奨）

`<(...)` プロセス置換は macOS の gawk で `-f /dev/fd/N` が不安定なケースがあるため、mktemp を一元化した方式を採用する。

```bash
_hawk_run_with_desugar() {
  local src="$1"; shift
  local tmp
  tmp=$(mktemp /tmp/hawk.XXXXXX.awk)
  trap "rm -f '$tmp'" EXIT

  gawk -f "${HAWK_LIB}/dsl/desugar.awk" "$src" > "$tmp"
  if [[ $? -ne 0 || ! -s "$tmp" ]]; then
    echo "hawk: desugar failed" >&2
    exit 1
  fi

  gawk -f "$tmp" "${HAWK_LIB}/core/"*.awk "$@"
}
```

`--debug` フラグ時は `trap` による削除をスキップし、変換後コードを確認できる。

---

## セクション 4: テスト戦略

### デシュガー単体テスト（フィクスチャ方式）

```
tests/unit/dsl/<テスト名>/input.awk     # DSL 記法の入力
tests/unit/dsl/<テスト名>/expected.awk  # 期待する変換後出力
```

テストランナー:
```bash
gawk -f dsl/desugar.awk input.awk > actual.awk
diff expected.awk actual.awk
```

必須テストケース:
- `dot_basic`: 基本ドット記法の変換
- `dot_nested`: 3 段以上のネスト（`hawk.csrf.token.verify`）
- `let_hoist`: スカラー・配列の巻き上げ
- `let_assign`: `let x = expr` の変換
- `string_no_mangle`: 文字列内の `.` を変換しないこと
- `comment_no_mangle`: コメント内の `let`/`.` を変換しないこと
- `nested_function`: ネストしたブロック内での `brace_depth` 追跡

既存 Makefile の `test-unit` ターゲットに追加する。

### e2e テスト

`examples/dsl/` に DSL 記法で書いた todo アプリ等を配置し、既存 e2e テストと同様に curl で動作確認する。

---

## セクション 5: エラーハンドリング

### デシュガー時エラー

```
dsl error: app.awk:12: 'let' outside function body
dsl error: app.awk:45: unclosed function 'todo_add'
```

`/dev/stderr` に出力して `exit 1`。

### 生成コードの行番号追跡

変換後のコードに gawk の `#line` ディレクティブを挿入することで、gawk 実行時のエラーメッセージがオリジナル DSL ファイルの行番号を指すようにする。

```awk
# desugar が出力するコードの冒頭・変換箇所に挿入
# line 1 "app.awk"
```

---

## 設計上の判断メモ

| 決定事項 | 選択 | 理由 |
|----------|------|------|
| ドット記法の解決方式 | 動的ディスパッチ | 拡張性・統一性 |
| デシュガーツール言語 | AWK 自身 | 外部依存ゼロ |
| `let` スコープ処理 | 巻き上げあり | gawk ローカル変数の正確な表現 |
| DSL ファイル配置 | `dsl/*.awk` (ツールのみ) | アプリコードと分離 |
| 起動方式 | mktemp 一元化 | macOS 安定性・デバッグ性 |
| プリプロセッサ構造 | ライン指向 + `@include` 分割 | hawk.awk と同じモジュール方式 |
