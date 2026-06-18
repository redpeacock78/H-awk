# bin/hawk libexec リファクタリング設計

## 背景と目的

`bin/hawk` は現在221行の単一スクリプトで、以下の責務が混在している。

- 引数パース
- `.env` ファイルの読み込み
- プラグインファイルの収集
- Zigライブラリの検出
- マルチワーカー判定
- PIDファイル管理
- デシュガー実行
- ワーカー起動とスーパーバイザーループ

機能追加のたびにこのファイルが肥大化する構造になっており、責務を分割してメンテナンス性を向上させる。

設計の方針は二つある。一つは、`bin/hawk` を薄いディスパッチャに絞り込むこと。もう一つは、ユーザー向けのサブコマンドインターフェースを導入することである。

## ディレクトリ構造

```
bin/hawk          # libexec/hawk への exec のみ（3行程度）
libexec/
  hawk            # 環境変数セット + サブコマンドディスパッチ
  hawk-serve      # ワーカー起動 + スーパーバイザーループ
  hawk-emit       # デシュガー済みAWKをstdoutに出力して終了
  hawk-check      # デシュガー後に構文チェックのみ実行して終了
  hawk-libs       # 共有ヘルパー（プラグイン収集、ライブラリ検出、デシュガー）
  hawk-help       # ヘルプテキスト出力
```

### bin/hawk

```bash
#!/usr/bin/env bash
HAWK_LIBEXEC="$(cd "$(dirname "$0")/../libexec" && pwd)"
exec "${HAWK_LIBEXEC}/hawk" "$@"
```

`libexec/hawk` への exec のみ行う。環境変数の設定や引数パースはここでは行わない。

### libexec/hawk

環境変数を設定し、サブコマンド名に基づいて対応するスクリプトへディスパッチする。

```bash
export HAWK_LIB="$(cd "$(dirname "$0")/.." && pwd)"
export HAWK_LIBEXEC="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HAWK_LIBEXEC:$PATH"

CMD="${1:-}"
case "$CMD" in
  serve|emit|check|help)
    shift
    exec "hawk-$CMD" "$@"
    ;;
  *.awk|-*|"")
    # サブコマンドなし: デフォルトで serve に委譲
    exec hawk-serve "$@"
    ;;
  *)
    echo "[hawk] unknown command '$CMD'" >&2
    exec hawk-help
    exit 1
    ;;
esac
```

## サブコマンドインターフェース

現行の `--emit` / `--no-emit` フラグは廃止し、サブコマンドへ移行する。後方互換は提供しない。

```
hawk [serve] [--workers N] [--debug] <app.awk>
hawk emit    [--strict]             <app.awk>
hawk check   [--strict]             <app.awk>
hawk help
```

`serve` はデフォルトのサブコマンドである。`hawk app.awk` と `hawk serve app.awk` は等価に動作する。

`--strict` フラグは `emit` と `check` の両方で使用できる。`serve` では使用しない。

`--workers` / `-w` は `serve` 専用のフラグである。

## hawk-libs の設計

`hawk-libs` は共有ヘルパーとして、各サブコマンドから subprocess として呼び出す callable スクリプトである。texenv における `texenv-libs` と同じ役割を持つ。副作用はデシュガー時のテンポラリファイル生成のみである。

### インターフェース

```bash
LIBS="$(command -v hawk-libs)"

# プラグインファイルの収集
PLUGIN_FILES="$("$LIBS" plugins)"
# 出力例: "-f plugins/foo/manifest.awk -f plugins/foo/foo.awk"

# Zigライブラリの検出（eval で変数をセット）
eval "$("$LIBS" libs)"
# セットされる変数:
#   LIBS_ARGS="-l /path/to/libhawk_net.dylib"
#   LIBS_VARS="-v HAWK_LIBS_net=1"
#   HAS_NET=1

# デシュガー（テンポラリAWKファイルのパスを返す）
APP_AWK="$("$LIBS" desugar "$APP")"
# 出力例: /tmp/hawk.XXXXXX.awk
```

### サブコマンドの対応

| サブコマンド引数 | 処理内容                                          |
| ---              | ---                                               |
| `plugins`        | `plugins/*/` を走査し、`-f` フラグ列を標準出力   |
| `libs`           | `libs/*/zig-out/` を走査し、shell変数代入行を出力 |
| `desugar <src>`  | `dsl/desugar.awk` を実行し、tmpファイルのパスを出力 |

## 各サブコマンドの責務

### hawk-serve

現行 `bin/hawk` のメイン処理を担う。

1. bash 4.3以上のバージョンチェック
2. `.env` の読み込み（`set -a; . ./.env; set +a`）
3. `hawk-libs plugins` でプラグインファイルを収集
4. `hawk-libs libs` でZigライブラリを検出（`eval` でセット）
5. `--workers` / `--debug` の引数パース
6. `HAS_NET` の値に基づく有効ワーカー数の決定（`HAS_NET=0` の場合は1に固定）
7. PIDファイルの管理（古いプロセスの終了と新規書き込み）
8. `hawk-libs desugar "$APP"` でテンポラリAWKファイルを生成
9. `trap shutdown INT TERM` の設定
10. Nワーカーの起動とスーパーバイザーループ

### hawk-emit

1. `.env` の読み込み
2. `--strict` フラグのパース
3. `hawk-libs desugar "$APP"` でテンポラリAWKファイルを生成
4. `--strict` 指定時: `gawk --sandbox` で構文チェック（失敗時は exit 1）
5. `cat "$APP_AWK"` で標準出力に出力
6. cleanup trap によるテンポラリファイルの削除

### hawk-check

1. `.env` の読み込み
2. `--strict` フラグのパース
3. `hawk-libs desugar "$APP"` でテンポラリAWKファイルを生成
4. `--strict` 指定時: `gawk --sandbox` で構文チェック（失敗時は exit 1）
5. 成功時は exit 0
6. cleanup trap によるテンポラリファイルの削除

### hawk-help

使用方法テキストを標準出力に出力して終了する。

## 設計上の決定事項

### .env の読み込みを hawk-libs に含めない理由

`set -a` / `set +a` による環境変数のエクスポートは、呼び出し元シェルのコンテキストで実行する必要がある。subprocess として呼び出す `hawk-libs` 内でこれを行っても、親プロセスの環境には影響しない。このため、`.env` の読み込みは各サブコマンドスクリプト内で直接行う。

### サブコマンドをファイルとして分離する理由

texenv のパターンに倣い、各サブコマンドを独立したファイルとして配置することで、以下の利点が得られる。

- 各スクリプトが独立して実行可能であり、テストが書きやすい
- 新しいサブコマンドの追加が `libexec/` にファイルを置くだけで済む
- `libexec/hawk` のディスパッチロジックが `exec "hawk-$CMD"` の一行で完結する
