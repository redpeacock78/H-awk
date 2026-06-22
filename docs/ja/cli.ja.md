🌐 [English](../cli.md) | [← README に戻る](../../README.ja.md)

# CLI リファレンス

```sh
./bin/hawk [serve] [--workers N] [--debug] <app.awk>
./bin/hawk emit    [--strict]             <app.awk>
./bin/hawk check   [--strict]             <app.awk>
./bin/hawk help
```

| サブコマンド | 説明 |
|---|---|
| `serve` | HTTP サーバーを起動します。サブコマンドを省略した場合のデフォルト（`hawk app.awk` と `hawk serve app.awk` は等価）。 |
| `emit` | デシュガー後の AWK ソースを stdout に出力して終了します。DSL プリプロセッサの出力を確認するのに便利です。 |
| `check` | DSL プリプロセッサを実行してサーバーを起動せずに終了します。成功時は 0、エラー時は 1 で終了します。 |
| `help` | 使用方法のサマリーを表示します。 |

`--strict` はデシュガー済みの出力を `gawk --sandbox` で追加構文検証します。`emit` と `check` で使用できます。

`--debug` で生成ファイルを確認できます:

```sh
./bin/hawk serve --debug app.awk   # 一時ファイルのパスを stderr に出力
```
