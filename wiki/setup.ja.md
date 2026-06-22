🌐 [English](setup.md) | [← README に戻る](../README.ja.md)

# セットアップ

## 動作要件

- gawk 5.0+ (`gawk --version`)
- bash 4.3+（マルチワーカー用スーパーバイザーに必要）
- GNU make
- Zig 0.14+（`make build-libs` を使う場合のみ）
- curl（e2e テストのみ）

gawk 5.3.1 / macOS で動作確認済み。Linux も動作します。Windows は WSL 経由のみ。

## クイックスタート

```sh
cp .env.example .env

# オプション: ネイティブ拡張をビルド (バイナリ I/O、TCP トランスポート等)
make build-libs

# サーバー起動 (デフォルト :8080、libs/net なしはシングルワーカー)
./bin/hawk app.awk

# make 経由でも可
make run                  # 4 workers (libs/net 必須)
make run WORKERS=8        # 8 workers (libs/net 必須)
make run WORKERS=1        # 1 worker (libs/net 不要)
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
curl http://localhost:8080/todos.json
```

`make help` で利用可能な全ターゲットを確認できます。

## ネイティブ拡張のビルド

```sh
# 全ライブラリをビルド (Zig 0.14+ が必要)
make build-libs

# プリコンパイル済みバイナリを取得 (Zig 不要)
HAWK_REPO=<owner>/<repo> make fetch-libs
```

起動時に有効なライブラリが表示されます:

```text
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```

各ライブラリの詳細は [ネイティブ拡張](libs.ja.md) を参照してください。
