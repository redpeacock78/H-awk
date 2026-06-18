# hawk DSL 9-Issue 修正設計

**日付**：2026-06-18
**対象ブランチ**：master
**実装順序**：アプローチ B（安全性・安定性から修正）

---

## 背景

全体コードレビューで9件の問題が特定された。
実装順序は以下の優先度に基づく。

1. **Phase 1**：ADT 基盤修正（バグと安全性）
2. **Phase 2**：API 拡張（機能制限の解除）
3. **Phase 3**：型システム強化（機能拡張）
4. **Phase 4**：ドキュメント改善（制限の明文化）

---

## Phase 1：ADT 基盤修正

### Issue #2：ADT エンコーディング Base64 化

**問題**：`Result<T,E>` と `Option<T>` は ASCII Unit Separator（`\x1F`）で文字列エンコードされている。
値に `\x1F` が含まれる場合（バイナリデータ等）エンコーディングが壊れる。
`result_val(v)` は `substr(v, 4)` という固定オフセット実装であり、バイナリ安全ではない。

**修正方針**：値部分を Base64 エンコードする。

**実装詳細**：

- ファイル：`dsl/adt.awk`
- 関数ごとの新ワイヤーフォーマット：
  - `ok`：`"ok\x1F" b64encode(val)` → `result_val(v)` は `b64decode(substr(v, 4))`
  - `ng`：`"ng\x1F" type "\x1F" b64encode(msg)`（msg 空の場合は `"ng\x1F" type`）→ `result_err_type(v)` は `split(substr(v, 4), a, "\x1F"); return a[1]`（変更なし）、`result_err(v)` は `b64decode(a[2])`
  - `some`：`"some\x1F" b64encode(val)` → `option_val(v)` は `b64decode(substr(v, 6))`
- pure AWK の Base64 実装を `adt.awk` 内に追加
- ただし gawk の `-b`（バイナリ）フラグと locale の影響に注意。NUL バイトを含む値は別途検証が必要
- lookup table 方式（約 30 行）で `_adt_b64_encode(s)` / `_adt_b64_decode(s)` を実装

**影響範囲**：
- `result_err()` の戻り値が `"TypeName\x1Fmsg"` 形式から decoded msg 単体に変わる
- `desugar_match.awk` の `ng <TypeName>:` マッチは `result_err_type()` を使うため影響なし
- `\x1F` を含む error message のテストケースを追加

---

### Issue #7：型エイリアス循環参照検出

**問題**：`type::accepts` のコメントに「aliases must not be circular」と明記されているが、
ユーザーが循環する型エイリアスを定義した場合に無限ループになる。

**修正方針**：ユーザーエイリアス登録直後にインクリメンタル DFS で循環を検出する。

**実装詳細**：

- ファイル：`dsl/type.awk`、`dsl/desugar.awk`
- `BEGIN` 末尾での一括チェックは不可。ユーザー定義エイリアスは `desugar.awk:64` の主パスで登録されるため
- 代替：`_DS_TYPE_ALIAS[name] = target` を書き込む直後に `type::check_alias_cycles(name)` を呼び出す
- DFS ローカル変数はすべてパラメータリストに宣言（AWK の慣行に従い、`visiting`, `visited`, `stack` を引数として渡す）
- 循環発見時は `_ds_error` でコンパイルエラーを出力し `exit 1`
- Issue #1 の型推論より前に循環チェックが完了していることを保証する（型推論が `type::normalize` を呼ぶため）

---

## Phase 2：API 拡張

### Issue #3：safe.html.fragment 可変長引数対応

**問題**：`safe.html.fragment` は最大 3 引数に固定されている。
4 つ以上の HTML 部品を結合する場合にネストが必要になる。

**修正方針**：引数数を制限せず、各引数が `HtmlPart` ブランド型（または静的リテラル文字列）であれば許可する。

**実装詳細**：

- ファイル：`dsl/sig.awk`、`dsl/typecheck.awk`、`dsl/desugar_strings.awk`
- `sig.awk`：`_DS_SIG_ARITY["safe.html.fragment"] = -1`（`-1` を可変arity のセンチネルとして使用）
- `typecheck.awk` の `_ds_typecheck_call`：
  - arity が `-1` のとき引数数チェックをスキップ
  - `safe.html.fragment` の場合、各引数の型チェックは `HtmlPart` または静的リテラル文字列のみ許可（`Str` を無制限に許可しない）
  - 既存の `actual == "Str" && split_args[i] ~ /^"[^"]*"$/` による静的リテラル特例を維持
- `desugar_strings.awk`：html.fragment の展開ロジックをループで可変引数に対応

---

### Issue #6：パイプ演算子 `|>` LHS 複雑式対応

**問題**：`|>` の LHS は単純な識別子のみ許可されている。
複雑な式は事前に `let tmp = expr` で変数に代入する必要がある。

**修正方針**：LHS が識別子でない場合、自動で一時変数に割り当てる。

**実装詳細**：

- ファイル：`dsl/desugar_pipe.awk`
- 現在の `_ds_pipe_left_start()` は識別子文字（`[a-zA-Z0-9_]`）を後方スキャンするのみで、関数呼び出し `f(x)` の LHS を正しく切り出せない
- `_ds_pipe_left_start()` を**均衡括弧スキャナー**に置き換える：`)` / `]` を検出したら対応する開き括弧まで逆スキャン、文字列リテラルも考慮
- 切り出した LHS が識別子パターン `^[a-zA-Z_][a-zA-Z0-9_]*$` に一致しない場合、`__pipe_tmp_N`（カウンタ `_DS_pipe_tmp_cnt` でユニーク保証）に自動割り当て
- 生成される一時変数は既存の `_ds_p_N` 系と衝突しないよう `__pipe_tmp_` プレフィックスを使用
- `Result<T,E>` と `Option<T>` の sealed-pipe ルール（パイプ禁止）は維持

---

## Phase 3：型システム強化

### Issue #1：ユーザー定義関数 return 型推論

**問題**：型推論はリテラルと既知の DSL 関数の戻り値のみ機能する。
ユーザー定義関数の戻り値を変数に代入した場合、型アノテーションがなければ `Any` として扱われ型チェックがスキップされる。

**修正方針**：Pass 1 でユーザー定義関数のボディをスキャンし、`return` 文から戻り型を推論する。

**Pre-pass 順序**（依存関係を考慮）：

1. **Pass 1a**：全ファイルをスキャンし、`type X = ...` エイリアスとエラーコンストラクタを収集
2. **Pass 1b**（Issue #7 後）：循環参照チェック完了後に関数 return 型推論を実施

Pass 1 で `_ds_infer_type()` を直接呼ぶと `_ds_error()` 等の副作用が発生する（`desugar_let.awk:40` の未知関数エラー等）。
そのため、Pass 1b 用に副作用フリーの `_ds_infer_type_safe(expr)` を別途実装する。

**実装詳細**：

- ファイル：`dsl/desugar.awk`（Pass 1 拡張）
- `_ds_infer_type_safe(expr)`：`_ds_infer_type` と同ロジックだが未知関数でエラーを出さず `""` を返す
- Pass 1b でアノテーションなし関数を検出した場合、`}` の行まで（brace depth 追跡）ボディをスキャン
- brace depth 追跡には `_ds_split_code_segs()` で文字列リテラル・コメントをマスクしてから `{`/`}` をカウント
- `return <expr>` 行から `_ds_infer_type_safe(expr)` を実行
- 全 `return` 文の推論型が一致した場合、その型を `_DS_SIG_RET[fname]` に設定
- 型が不一致または推論不能の場合、`"Any"` のまま（警告なし）
- アノテーションが明示されている場合は推論をスキップ（アノテーション優先）
- Pass 1 専用の行カウンタ `_DS_pass1_lineno` を導入（`_DS_current_lineno` は主パス用のため）

**制約**：

- Pass 1 では `_DS_VAR_TYPES` が未設定のため、変数参照の推論は不可
- リテラルと既知関数呼び出しのみ推論対象
- 再帰関数の場合は推論をスキップして `"Any"`

---

### Issue #9：`when...of...end` 網羅性チェック拡張

**問題**：typed union の網羅性チェックは、戻り型が `Result<T, E1 | E2>` と明示的にアノテーションされている場合のみ機能する（`desugar_match.awk:165`）。
推論型が `Result<T,E1|E2>` の場合でも union メンバーの網羅性が検証されない。

**修正方針**：Issue #1 の型推論と連携し、推論型でも union 網羅性チェックを実施する。

**実装詳細**：

- ファイル：`dsl/desugar_match.awk`
- `when` ブロック開始時に `_ds_infer_type(match_expr)` を実行
- 推論結果が `Result<T, E1 | E2>` の場合（union error 型）、各 `ng` アームの型カバレッジを検証
- 推論結果が `Option<T>` の場合、`none` アームの存在を必須とする
- 不足時は `_ds_error` で網羅性エラーを出力
- Issue #1 完了後に実装（推論精度に依存）

---

## Phase 4：ドキュメント改善

### Issue #4：`let` のホイスティング意味論

**問題**：`let` の名前は JavaScript の `let`（ブロックスコープ）を想起させるが、
実際は AWK の関数シグネチャにホイストされる（`var` に近い意味論）。
`if` ブロック内で `let` を宣言しても、実際には関数全体でスコープが有効になる。

**対応**：

- `README.md`：`let` セクションに「AWK の制約によりブロックスコープではなく関数スコープ」を明記
- `--strict` モード：`if` / `while` などのブロック内で `let` を使用した場合に警告出力
- `desugar_let.awk`：意図的なホイスティング実装である旨をコメントで記載

---

### Issue #5：`??` 演算子と AWK 型システムの非互換

**問題**：`??` は「空文字列の場合にデフォルト値を使う」という実装だが、
AWK では数値 `0` と空文字列 `""` が文脈によって等価になるため、
`0 ?? default` がデフォルト値を返さない点が直感に反する場合がある。

**対応**：

- コード変更なし（AWK 仕様上の制約）
- `README.md`：`??` セクションに「`0` はデフォルト値を返さない（AWK では `0` は空文字列と区別される）」を明記
- 例示：`"" ?? "default"` は `"default"`、`0 ?? "default"` は `0`

---

### Issue #8：正規表現ベースパーサーの制限

**問題**：デシュガーは AWK の正規表現で実装されており、真の AST パーサーではない。
関数定義の検出は正規表現 1 行で行われているため、複数行にまたがる関数シグネチャは処理できない。

**対応**：

- コード変更なし（根本的修正には AST パーサーへの全面書き換えが必要）
- `README.md`：DSL の制約として「関数定義は 1 行で記述すること」を明記
- `desugar.awk`：正規表現ベースの実装であることと既知の制限をコメントで記載

---

## アーキテクチャへの影響

### 変更ファイル一覧

- **Phase 1**：`dsl/adt.awk`（Base64 エンコード/デコード追加、ng ワイヤーフォーマット更新）
- **Phase 1**：`dsl/type.awk`（循環参照インクリメンタル DFS 追加）
- **Phase 1**：`dsl/desugar.awk`（エイリアス登録後に循環チェック呼び出し）
- **Phase 2**：`dsl/sig.awk`（html.fragment に `-1` arity センチネル設定）
- **Phase 2**：`dsl/typecheck.awk`（可変 arity 対応と HtmlPart 型チェック維持）
- **Phase 2**：`dsl/desugar_strings.awk`（html.fragment 展開可変化）
- **Phase 2**：`dsl/desugar_pipe.awk`（均衡括弧スキャナーと LHS 自動テンポ変数生成）
- **Phase 3**：`dsl/desugar.awk`（Pass 1a/1b 分割、副作用フリー推論、Pass 1 行カウンタ）
- **Phase 3**：`dsl/desugar_match.awk`（推論型での union 網羅性チェック）
- **Phase 4**：`dsl/desugar_let.awk`（strict モードホイスティング警告）
- **Phase 4**：`README.md`（各制限の明文化）

### テスト方針

- 既存テストが全て通ることを確認（回帰テスト）
- 各 Phase に対応するテストケースを `tests/` に追加
- Base64 エンコーディング：バイナリ値と `\x1F` を含む ADT テスト、ng メッセージの round-trip テスト
- 型推論：アノテーションなし関数での型伝播テスト
- 可変長 html.fragment：4 引数以上のテスト、非 HtmlPart 引数の拒否テスト
- 均衡括弧 LHS：ネスト呼び出し式（`f(g(x))` 等）のパイプテスト
- 循環型エイリアス：循環定義時のコンパイルエラーテスト

---

## 実装ノート

- **Issue #7 と #1 の依存関係**：循環チェックは `type::normalize` を呼ぶ推論パスより前に完了している必要がある
- **Pass 1 の順序**：Pass 1a（エイリアス収集）→ 循環チェック（Issue #7）→ Pass 1b（return 型推論）の順で実行
- **Issue #1 と #9 の依存関係**：#9 は #1 完了後に実装
- Base64 の gawk locale 安全性：`-b` フラグでのバイナリ動作を検証してから本番採用を判断
- `--strict` フラグは既存のメカニズムを使用
