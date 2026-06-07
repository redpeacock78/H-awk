# H-awk v0.2 Island Plugin Hook Foundation

**Date**: 2026-06-07
**Scope**: core hook dispatch infrastructure only (no sample plugins)
**Plugin delivery**: `plugins/` as git submodules (each plugin is its own repo)

## 1. Overview

H-awk のコアに `pre_request` / `post_request` hook dispatch を追加し、外部プラグインがリクエスト処理の前後に介入できる土台を作る。

実際のプラグイン実装 (CSRF/CORS/Logger/Postgres/S3 等) は各々の git submodule で管理する。コアは「hook の登録と呼び出し」だけを提供する。

## 2. Architecture

```
┌──────────────────────────────────────┐
│ gawk HTTP loop                       │
│   listen → accept → parse → dispatch │
│                              │       │
│                              ▼       │
│   ┌────────────────────────────────┐
│   │ router.dispatch(req, res)      │
│   │   run_hooks("pre_request")       │
│   │       │                         │
│   │       ▼  (abort: skip handler) │
│   │   handler(req, res)            │
│   │       │                         │
│   │       ▼  (always run)          │
│   │   run_hooks("post_request")      │
│   └────────────────────────────────┘
└──────────────────────────────────────┘
```

### Hook lifecycle

- `pre_request`: handler 実行前。`status(res, ...)` + `send()` で abort 可能。
- `post_request`: handler 実行後 (成否に関係なく)。logging, metrics 等。

## 3. Changes to `core/plugin.awk`

### Current behaviour
`load_plugins()` scans `plugins/*/` and calls `plugin_{name}_manifest(meta)`. The manifest declares metadata but hooks are not stored in a runnable table.

### New behaviour

**`load_plugins()` — extended to build hook dispatch table:**

```awk
function load_plugins(   pname, cmd, func_name, meta, n, m, j, keys, hooks, hook_name) {
    HOOKS_COUNT["pre_request"]  = 0
    HOOKS_COUNT["post_request"] = 0
    cmd = "ls plugins 2>/dev/null"
    while ((cmd | getline pname) > 0) {
        func_name = "plugin_" pname "_manifest"
        delete meta
        @func_name(meta)

        PLUGINS[pname, "version"] = meta["version"]
        PLUGINS[pname, "api"]     = meta["api"]

        # Register hooks
        m = split(meta["hooks"], hooks, ",")
        for (j = 1; j <= m; j++) {
            hook_name = hooks[j]
            HOOKS[hook_name, ++HOOKS_COUNT[hook_name]] = "plugin_" pname "_" hook_name
        }
    }
    close(cmd)
}
```

**`run_hooks(name, req, res)` — new:**

```awk
function run_hooks(name, req, res,    i, fx, ret) {
    for (i = 1; i <= HOOKS_COUNT[name]) i++) {
        fx = HOOKS[name, i]
        ret = @fx(req, res)
        if (ret != 0) return ret   # abort chain
    }
    return 0
}
```

Rules:
- Hook signature: `function plugin_NAME_HOOKNAME(req, res)`  returns `0` (continue) or non-zero (abort).
- Only `pre_request` honours abort. `post_request` runs all hooks regardless.
- Hook registration is order-of-discovery (filesystem order, stable enough for MVP).

## 4. Changes to `core/router.awk`

Wrap existing dispatch so hooks fire before/after the handler.

```awk
function dispatch(req, res,    idx, key, k, pattern, params, names, i,
                     handler, handler_name, m, abort) {
    # pre_request hooks
    abort = run_hooks("pre_request", req, res)
    if (abort) {
        send_response(res)
        return
    }

    # Existing route match
    for (idx = 1; idx <= ROUTES_COUNT; idx++) {
        key = ROUTES_ORDER[idx]
        split(key, k, "\t")
        if (k[1] != req["method"]) continue
        pattern = ROUTES[k[1], k[2], "pattern"]
        if (match(req["path"], pattern, arr)) {
            params = ROUTES[k[1], k[2], "params"]
            split(params, names, ",")
            for (i in names) req["params:" names[i]] = arr[i]
            handler = ROUTES[k[1], k[2], "handler"]
            @handler(req, res)
            goto post
        }
    }

    # Static / 404 / 405 (existing logic unchanged)
    if (serve_static(req, res)) goto post
    if (method_mismatch(req))   return  # 405 already sent
    not_found(res)

    post:
    run_hooks("post_request", req, res)
    send_response(res)
}
```

Note: `goto` is acceptable in gawk for this tight control flow; alternative is to extract route match into `try_match_route(req, res)` helper.

## 5. Plugin Interface (external)

Each plugin lives in its own repo and is added as a git submodule under `plugins/<name>/`.

### Directory layout (per plugin)

```
plugins/
├── csrf/          (git submodule)
│   ├── manifest.awk
│   └── csrf.awk
└── logger/        (git submodule)
    ├── manifest.awk
    └── logger.awk
```

### manifest.awk convention

```awk
function plugin_csrf_manifest(meta) {
    meta["name"]    = "csrf"
    meta["version"] = "0.1.0"
    meta["api"]     = "csrf_token,csrf_validate"
    meta["hooks"]   = "pre_request"
}
```

`meta["hooks"]` is a comma-separated list of hook names the plugin implements.

### Implementation file convention

`plugins/<name>/<name>.awk` defines at minimum the hook functions referenced in the manifest.

```awk
# plugins/csrf/csrf.awk
function plugin_csrf_pre_request(req, res) {
    if (req["method"] == "GET") return 0
    # ... validate token ...
    if (invalid) {
        status(res, 403)
        text(res, "CSRF token mismatch")
        return 1   # abort
    }
    return 0
}

function csrf_token(session_id) {
    # public API used by app.awk
    return "..."
}
```

## 6. Dependencies

- No new external dependencies in core.
- Plugin submodules bring their own dependencies (e.g. `psql` binary, `curl`, etc.) documented in their own README.

## 7. Testing

### Unit tests
- Add `tests/unit/test_plugin_hooks.awk`:
  - Register a dummy `pre_request` hook that sets a flag → verify it runs.
  - Register a dummy `pre_request` hook that returns abort → verify handler skipped.
  - Register a `post_request` hook → verify it runs even after 404.

### E2E tests
- No E2E changes required for the foundation itself.
- E2E for actual plugins belong in their own repos.

## 8. Future Work (out of scope for this spec)

- Postgres plugin (`plugin_postgres_pre_request` + connection helper API)
- S3 plugin (presigned-URL helpers)
- Logger plugin (structured access logs)
- CSRF/CORS plugins (security helpers)
- Template variable interpolation (`{{var}}` in views)
- `routes/` auto-mount file-based routing
- Wildcard routes (`*` / `**`)
- HTMX partial template system
