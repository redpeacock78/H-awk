🌐 [English](../plugins.md) | [← README に戻る](../../README.ja.md)

# プラグイン

`plugins/<name>/` にプラグインディレクトリを配置すると、H-awk が起動時に自動発見してロードします。

```awk
# plugins/logger/manifest.awk
function plugin_logger_manifest(meta) {
  meta["name"]        = "logger"
  meta["version"]     = "0.1.0"
  meta["description"] = "Per-request stdout logger"
  meta["hooks"]       = "post_request"
}
```

```awk
# plugins/logger/logger.awk
function plugin_logger_post_request(req, res) {
  log_info(sprintf("%s %s %d", req["method"], req["path"], res["status"]))
}
```

## プラグインフック

| フック | シグネチャ | 説明 |
|---|---|---|
| `init` | `(meta)` | 起動時に 1 回呼び出されます |
| `pre_request` | `(req, res)` | ディスパッチ前。`1` を返すと処理を短絡できます |
| `post_request` | `(req, res)` | レスポンス送信後 |
| `shutdown` | `(meta)` | シャットダウン時に 1 回呼び出されます |

削除せずにプラグインを無効化する:

```sh
touch plugins/logger/.disabled
```

プラグインはスタンドアロンの Git リポジトリとして配布され、`git submodule` で追加されます:

```sh
git submodule add https://github.com/<owner>/hawk-plugin-csrf plugins/csrf
git submodule update --init plugins/csrf
```
