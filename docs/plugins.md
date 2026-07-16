🌐 [日本語](ja/plugins.ja.md) | [← Back to README](../README.md)

# Plugins

Drop a plugin directory into `plugins/<name>/`. H-awk auto-discovers and loads plugins at startup.

H-awk loads plugins from both `$HAWK_LIB/plugins` (the framework) and `./plugins` (the app working directory). If both contain the same plugin name, the app plugin wins; an app-side `.disabled` also shadows and disables the framework plugin of that name.

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

## Plugin hooks

| Hook | Signature | Notes |
|---|---|---|
| `init` | `(meta)` | Called once at startup |
| `pre_request` | `(req, res)` | Before dispatch; return `1` to short-circuit |
| `post_request` | `(req, res)` | After response is sent |
| `shutdown` | `(meta)` | Called once at teardown |

Disable a plugin without removing it:

```sh
touch plugins/logger/.disabled
```

Plugins are distributed as standalone git repositories and added via `git submodule`:

```sh
git submodule add https://github.com/<owner>/hawk-plugin-csrf plugins/csrf
git submodule update --init plugins/csrf
```
