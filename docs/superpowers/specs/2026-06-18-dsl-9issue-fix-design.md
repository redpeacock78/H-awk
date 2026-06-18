# hawk DSL 9-Issue 修正設計

**日付**: 2026-06-18  
**対象ブランチ**: master  
**実装順序**: アプローチB（安全性・安定性から修正）

---

## 背景

全体コードレビューで9件の問題が特定された。実装順序は以下の優先度に基づく：

1. **Phase 1** — ADT基盤修正（バグ・安全性）
2. **Phase 2** — API拡張（機能制限の解除）
3. **Phase 3** — 型システム強化（機能拡張）
4. **Phase 4** — ドキュメント改善（制限の明文化）

---

## Phase 1: ADT基盤修正

### Issue #2 — ADTエンコーディング Base64化

**問題**: `Result<T,E>` と `Option<T>` は ASCII Unit Separator (`\x1F`) で文字列エンコードされている。値に `\x1F` が含まれる場合（バイナリデータ等）エンコーディングが壊れる。`result_val(v)` は `substr(v, 4)` という固定オフセット実装。

**修正方針**: 値部分を Base64 エンコードする。

**実装詳細**:

- ファイル: `dsl/adt.awk`
- `result_ok(v)`、`result_err(v)`、`option_some(v)` でセット時に Base64 エンコード
- `result_val(v)`、`result_err_val(v)`、`option_val(v)` でゲット時に Base64 デコード
- pure AWK の Base64 実装を `adt.awk` 内に追加（gawk 5.3.1 には built-in base64 なし）
- lookup table 方式（~30行）で `_adt_b64_encode(s)` / `_adt_b64_decode(s)` を実装
- タグ部分（`"ok\x1F"` 等）は変更なし、値部分のみエンコード
- 固定オフセット `substr(v, 4)` は `_ds_adt_decode(substr(v, 4))` に置き換え

**影響範囲**: ADT値の生成・取得は全て `adt.awk` の関数経由のため、呼び出し側の変更は不要。

---

### Issue #7 — 型エイリアス循環参照検出

**問題**: `type::accepts` のコメントに「aliases must not be circular」と明記されているが、ユーザーが循環する型エイリアスを定義した場合に無限ループになる。

**修正方針**: コンパイル時に DFS で循環検出し、エラーを出力する。

**実装詳細**:

- ファイル: `dsl/type.awk`
- 新関数 `type::check_alias_cycles()` を追加
- `_DS_TYPE_ALIAS` テーブルをグラフとして DFS 巡回
- 訪問中フラグ（gray set）で循環検出
- 循環発見時 → `_ds_error` でコンパイルエラー（エラー後 `exit 1`）
- `BEGIN` ブロック末尾（全エイリアス登録後）に呼び出す

---

## Phase 2: API拡張

### Issue #3 — safe.html.fragment 可変長引数対応

**問題**: `safe.html.fragment` は最大3引数に固定。4つ以上の HTML 部品を結合する場合にネストが必要。

**修正方針**: 引数数を制限せず、各引数が `Str` または `Safe<Str>` であれば許可する。

**実装詳細**:

- ファイル: `dsl/sig.awk`、`dsl/typecheck.awk`
- `sig.awk`: `safe.html.fragment` の固定 arity 定義を削除（または -1 で可変を示す）
- `typecheck.awk` の `_ds_typecheck_call`: `safe.html.fragment` の場合は引数数チェックをスキップし、各引数の型チェック（`Str` または `Safe<Str>`）のみ実施
- `desugar_strings.awk`: html.fragment の展開ロジックを可変引数に対応（ループで結合）

**シグネチャ変更**:
```
# 変更前
safe.html.fragment(a: Str, b: Str, c: Str) -> Safe<Str>

# 変更後（概念的）
safe.html.fragment(...args: Str) -> Safe<Str>
```

---

### Issue #6 — パイプ演算子 `|>` LHS 複雑式対応

**問題**: `|>` の LHS は単純な識別子のみ許可。複雑な式は事前に `let tmp = expr` が必要。

**修正方針**: LHS が識別子でない場合、自動で一時変数に割り当てる。

**実装詳細**:

- ファイル: `dsl/desugar_pipe.awk`
- LHS パターンマッチ: `[a-zA-Z_][a-zA-Z0-9_]*` に一致しない場合、自動テンポ変数を生成
- テンポ変数名: `__pipe_tmp_N`（カウンタ `_DS_pipe_tmp_cnt` でユニーク保証）
- 生成コード例:
  ```awk
  # ユーザー入力: get_user(id) |> validate
  # 生成:
  __pipe_tmp_1 = get_user(id)
  __pipe_tmp_1 = validate(__pipe_tmp_1)
  ```
- `Result<T,E>` と `Option<T>` の sealed-pipe ルール（パイプ禁止）は維持

---

## Phase 3: 型システム強化

### Issue #1 — ユーザー定義関数 return 型推論

**問題**: 型推論はリテラルと既知の DSL 関数の戻り値のみ機能する。ユーザー定義関数の戻り値を変数に代入した場合、型アノテーションがなければ `Any` として扱われ型チェックがスキップされる。

**修正方針**: Pass 1 でユーザー定義関数のボディをスキャンし、`return` 文から戻り型を推論する。

**実装詳細**:

- ファイル: `dsl/desugar.awk`（Pass 1 拡張）
- Pass 1 でアノテーションなし関数を検出した場合、`}` まで（brace depth 追跡）ボディをスキャン
- `return <expr>` 行から `_ds_infer_type(expr)` を実行
- 全 `return` 文の推論型が一致 → その型を `_DS_SIG_RET[fname]` に設定
- 型が不一致または推論不能 → `"Any"` のまま（警告なし）
- アノテーションが明示されている場合は推論をスキップ（アノテーション優先）

**制約**:
- Pass 1 では `_DS_VAR_TYPES` が未設定のため、変数参照の推論は不可
- リテラル・既知関数呼び出しのみ推論対象
- 再帰関数の場合は推論をスキップして `"Any"`

---

### Issue #9 — `when...of...end` 網羅性チェック拡張

**問題**: 網羅性チェックは戻り型が `Result<T, E1 | E2>` と明示的にアノテーションされている場合のみ機能する。アノテーションなしでは `ng` アームが欠けてもエラーにならない。

**修正方針**: Issue #1 の型推論と連携し、推論型でも網羅性チェックを実施する。

**実装詳細**:

- ファイル: `dsl/desugar_match.awk`
- `when` ブロック開始時に `_ds_infer_type(match_expr)` を実行
- 推論結果が `Result<T,E>` または `Option<T>` の場合、`ng` / `none` アームの存在を必須とする
- 不足時 → `_ds_error` で網羅性エラー
- Issue #1 完了後に実装（推論精度に依存）

---

## Phase 4: ドキュメント改善

### Issue #4 — `let` ホイスティング意味論

**問題**: `let` の名前は JavaScript の `let`（ブロックスコープ）を想起させるが、実際は AWK の関数シグネチャにホイストされる（`var` に近い意味論）。

**対応**:
- `README.md`: `let` セクションに「AWK 制約によりブロックスコープではなく関数スコープ」を明記
- `--strict` モード: `if` / `while` などのブロック内で `let` を使用した場合に警告出力
- コメント追加: `desugar_let.awk` に意図的なホイスティング実装である旨を記載

### Issue #5 — `??` 演算子と AWK 型システムの非互換

**問題**: AWK では数値 `0` と空文字列 `""` が文脈によって等価になるため、`0 ?? default` の挙動が直感に反する場合がある。

**対応**:
- コード変更なし（AWK 仕様上の制約）
- `README.md`: `??` セクションに「`0` はデフォルト値を返さない（AWK では `0` は空文字列と異なる）」を明記
- 例示: `"" ?? "default"` → `"default"`、`0 ?? "default"` → `0`

### Issue #8 — 正規表現ベースパーサーの制限

**問題**: デシュガーは AWK の正規表現で実装されており、真の AST パーサーではない。複数行にまたがる関数シグネチャなどは処理できない。

**対応**:
- コード変更なし（根本的修正には AST パーサーへの全面書き換えが必要）
- `README.md`: DSL の制約として「関数定義は1行で記述すること」を明記
- `desugar.awk` のコメント: 正規表現ベースの実装であることと既知の制限を記載

---

## アーキテクチャへの影響

### 変更ファイル一覧

| Phase | ファイル | 変更内容 |
|-------|---------|---------|
| 1 | `dsl/adt.awk` | Base64エンコード/デコード追加 |
| 1 | `dsl/type.awk` | 循環参照DFS検出追加 |
| 2 | `dsl/sig.awk` | html.fragment 可変arity対応 |
| 2 | `dsl/typecheck.awk` | html.fragment 型チェック可変化 |
| 2 | `dsl/desugar_strings.awk` | html.fragment 展開可変化 |
| 2 | `dsl/desugar_pipe.awk` | LHS自動テンポ変数生成 |
| 3 | `dsl/desugar.awk` | Pass 1ボディスキャン追加 |
| 3 | `dsl/desugar_match.awk` | 推論型での網羅性チェック |
| 4 | `dsl/desugar_let.awk` | strictモードホイスティング警告 |
| 4 | `README.md` | 各制限の明文化 |

### テスト方針

- 既存テストが全て通ることを確認（回帰テスト）
- 各 Phase に対応するテストケースを `tests/` に追加
- Base64 エンコーディング: バイナリ値を含む ADT テスト
- 型推論: アノテーションなし関数での型伝播テスト
- 可変長 html.fragment: 4引数以上のテスト

---

## 実装ノート

- Issue #1 と #9 は依存関係あり（#9 は #1 完了後に実装）
- Base64 エンコーディング変更は既存のシリアライズ形式を変更するため、ファイルベースのセッション保存があれば移行が必要（現時点では不要と判断）
- `--strict` フラグは既存のメカニズムを使用
