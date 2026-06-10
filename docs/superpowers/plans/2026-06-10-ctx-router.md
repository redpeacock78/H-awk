# ctx Namespace + Router Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ctx::` namespace (Hono-style Context API) so handlers can be written without `req`/`res` arguments, and add `listen(port)` so the entry file can explicitly start the server in `BEGIN`. Full backward compatibility with existing `function handler(req, res)` style is required.

**Architecture:** Four files change: (1) new `core/ctx.awk` with `@namespace "ctx"` provides `ctx::req[]`, `ctx::res[]`, and helper functions; (2) `core/router.awk` wraps each handler call with `_ctx_load`/`_ctx_save` copy-in/copy-out; (3) `hawk.awk` adds `@include "core/ctx.awk"` after router; (4) `core/http.awk` extracts `_hawk_serve()` and adds `listen(port)`. gawk silently ignores extra args on functions with fewer params — old-style handlers still receive `req`/`res`, new-style handlers ignore them.

**Tech Stack:** gawk 5.0+ (`@namespace` support required), existing H-awk test infrastructure

---

### Task 1: Create `core/ctx.awk`

**Files:**
- Create: `core/ctx.awk`

- [ ] **Step 1: Write the failing tests first**

Create `tests/unit/test_ctx.awk`:

```awk
# SPDX-License-Identifier: MIT
# tests/unit/test_ctx.awk

function test_ctx_load_copies_req(    req, res) {
  delete req
  delete res
  req["method"] = "GET"
  req["path"] = "/test"
  req["query:limit"] = "10"
  req["params:id"] = "42"
  req["header:content-type"] = "application/json"
  res["status"] = 200

  _ctx_load(req, res)

  assert_eq(ctx::req["method"],           "GET",              "ctx_load: method copied")
  assert_eq(ctx::req["path"],             "/test",            "ctx_load: path copied")
  assert_eq(ctx::req["query:limit"],      "10",               "ctx_load: query copied")
  assert_eq(ctx::req["params:id"],        "42",               "ctx_load: param copied")
  assert_eq(ctx::req["header:content-type"], "application/json", "ctx_load: header copied")
  assert_eq(ctx::res["status"],           200,                "ctx_load: res status copied")
}

function test_ctx_save_copies_res_back(    req, res) {
  delete req
  delete res
  res["status"] = 200

  _ctx_load(req, res)

  ctx::res["status"] = 201
  ctx::res["body"] = "created"
  ctx::res["header:content-type"] = "application/json"

  _ctx_save(res)

  assert_eq(res["status"],               201,           "ctx_save: status written back")
  assert_eq(res["body"],                 "created",     "ctx_save: body written back")
  assert_eq(res["header:content-type"],  "application/json", "ctx_save: header written back")
}

function test_ctx_query_helper(    req, res) {
  delete req
  delete res
  req["query:page"] = "3"
  _ctx_load(req, res)
  assert_eq(ctx::query("page"), "3", "ctx::query reads query param")
}

function test_ctx_param_helper(    req, res) {
  delete req
  delete res
  req["params:id"] = "99"
  _ctx_load(req, res)
  assert_eq(ctx::param("id"), "99", "ctx::param reads path param")
}

function test_ctx_get_header_helper(    req, res) {
  delete req
  delete res
  req["header:accept"] = "text/html"
  _ctx_load(req, res)
  assert_eq(ctx::get_header("Accept"), "text/html", "ctx::get_header normalizes to lowercase")
  assert_eq(ctx::get_header("accept"), "text/html", "ctx::get_header lowercase input works")
}

function test_ctx_body_helper(    req, res) {
  delete req
  delete res
  req["body"] = "raw body content"
  _ctx_load(req, res)
  assert_eq(ctx::body(), "raw body content", "ctx::body returns raw body")
}

function test_ctx_json_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::json("{\"ok\":true}")
  _ctx_save(res)
  assert_eq(res["body"],                     "{\"ok\":true}", "ctx::json sets body")
  assert_eq(res["header:content-type"], "application/json; charset=utf-8", "ctx::json sets content-type")
}

function test_ctx_text_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::text("hello")
  _ctx_save(res)
  assert_eq(res["body"],                     "hello",            "ctx::text sets body")
  assert_eq(res["header:content-type"], "text/plain; charset=utf-8", "ctx::text sets content-type")
}

function test_ctx_status_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::status(404)
  _ctx_save(res)
  assert_eq(res["status"], 404, "ctx::status sets status code")
}

function test_ctx_set_header_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::set_header("X-Custom", "myvalue")
  _ctx_save(res)
  assert_eq(res["header:x-custom"], "myvalue", "ctx::set_header sets response header")
}

function test_ctx_load_clears_previous(    req1, req2, res) {
  delete req1
  delete req2
  delete res
  req1["query:old"] = "stale"
  _ctx_load(req1, res)
  assert_eq(ctx::req["query:old"], "stale", "ctx_load: first load sets value")

  req2["query:new"] = "fresh"
  _ctx_load(req2, res)
  assert_eq(ctx::req["query:new"], "fresh",  "ctx_load: second load sets new value")
  assert_eq(ctx::req["query:old"], "",       "ctx_load: previous keys cleared")
}
```

- [ ] **Step 2: Register tests in `tests/unit/run.awk`**

In `tests/unit/run.awk`, add `@include` at the end of the includes section:

```awk
@include "tests/unit/test_ctx.awk"
```

And add test calls in the `BEGIN` block, after the router tests:

```awk
  test_ctx_load_copies_req()
  test_ctx_save_copies_res_back()
  test_ctx_query_helper()
  test_ctx_param_helper()
  test_ctx_get_header_helper()
  test_ctx_body_helper()
  test_ctx_json_helper()
  test_ctx_text_helper()
  test_ctx_status_helper()
  test_ctx_set_header_helper()
  test_ctx_load_clears_previous()
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
make test-unit 2>&1 | head -20
```

Expected: failures referencing `_ctx_load`, `ctx::req`, `ctx::query`, etc. not defined.

- [ ] **Step 4: Create `core/ctx.awk`**

```awk
# SPDX-License-Identifier: MIT
# core/ctx.awk -- Hono-style Context API
#
# ctx::req[], ctx::res[] are populated by _ctx_load() before each handler call.
# _ctx_save() copies ctx::res[] back to res[] after the handler returns.
# Handler functions that accept (req, res) args continue to work unchanged.
# Handler functions with no args (or only local vars) use ctx:: directly.
#
# Requires gawk 5.0+ (@namespace support).

@namespace "ctx"

# Global arrays populated per-request
# (declared implicitly by use; listed here for documentation)
# ctx::req[] -- request data, same key schema as core/request.awk req[]
# ctx::res[] -- response data, same key schema as core/response.awk res[]

# --- Request helpers ---

function query(key)      { return ctx::req["query:" key] }
function param(key)      { return ctx::req["params:" key] }
function get_header(key) { return ctx::req["header:" awk::to_lower(key)] }
function body()          { return ctx::req["body"] }

# --- Response helpers ---

function json(data)         { awk::json(ctx::res, data) }
function text(data)         { awk::text(ctx::res, data) }
function html(data)         { awk::html(ctx::res, data) }
function render(tpl, d)     { awk::render(ctx::res, tpl, d) }
function redirect(url, c)   { awk::redirect(ctx::res, url, c) }
function status(code)       { awk::status(ctx::res, code) }
function set_header(name, v) { awk::header(ctx::res, name, v) }

@namespace "awk"

# _ctx_load: copy req[] and res[] into ctx:: namespace before calling handler
function _ctx_load(req, res,    k) {
  delete ctx::req
  for (k in req) ctx::req[k] = req[k]
  delete ctx::res
  for (k in res) ctx::res[k] = res[k]
}

# _ctx_save: copy ctx::res[] back into res[] after handler returns
function _ctx_save(res,    k) {
  for (k in ctx::res) res[k] = ctx::res[k]
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make test-unit 2>&1 | tail -5
```

Expected: all ctx tests pass, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add core/ctx.awk tests/unit/test_ctx.awk tests/unit/run.awk
git commit -m "feat(core/ctx): add ctx namespace with request/response helpers"
```

---

### Task 2: Update `core/router.awk` to wire ctx:: copy-in/copy-out

**Context:** `router_dispatch` currently calls `@handler(req, res)` at line 64. Wrap it with `_ctx_load` before and `_ctx_save` after. Old handlers that use `req`/`res` args are unaffected — gawk passes them normally. New handlers that use `ctx::` will find their data pre-loaded.

**Files:**
- Modify: `core/router.awk` lines 63-65

- [ ] **Step 1: Run existing router tests as baseline**

```bash
make test-unit 2>&1 | grep -E "router|FAIL"
```

Expected: all router tests pass.

- [ ] **Step 2: Apply the change to `router_dispatch`**

In `core/router.awk`, find (approximately line 63-65):

```awk
        handler = ROUTES[k[1], k[2], "handler"]
        @handler(req, res)
        return 1
```

Replace with:

```awk
        handler = ROUTES[k[1], k[2], "handler"]
        _ctx_load(req, res)
        @handler(req, res)
        _ctx_save(res)
        return 1
```

- [ ] **Step 3: Run full unit tests**

```bash
make test-unit 2>&1 | tail -5
```

Expected: same pass count as before, 0 failed (backward compatibility confirmed).

- [ ] **Step 4: Commit**

```bash
git add core/router.awk
git commit -m "feat(core/router): wire ctx copy-in/copy-out around handler dispatch"
```

---

### Task 3: Add `@include "core/ctx.awk"` to `hawk.awk`

**Context:** `core/ctx.awk` must be included after `core/router.awk` (because it references `awk::json`, `awk::text`, etc. from `core/response.awk`, and defines `_ctx_load`/`_ctx_save` that `core/router.awk`'s `router_dispatch` calls at runtime — gawk resolves function calls dynamically so order is not critical for correctness, but the include comment documents the dependency).

**Files:**
- Modify: `hawk.awk`

- [ ] **Step 1: Add the include**

In `hawk.awk`, after the line `@include "core/router.awk"`, add:

```awk
@include "core/ctx.awk"
```

The resulting include order in `hawk.awk`:

```awk
@include "core/util.awk"
@include "core/libs.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/router.awk"
@include "core/ctx.awk"
@include "core/plugin.awk"
@include "core/http.awk"
```

- [ ] **Step 2: Run full unit tests**

```bash
make test-unit 2>&1 | tail -5
```

Expected: all tests pass, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add hawk.awk
git commit -m "feat(hawk): include core/ctx.awk in load order"
```

---

### Task 4: Add `listen(port)` and `_hawk_serve()` to `core/http.awk`

**Context:** Currently the `END` block contains all server startup logic inline. Extract it into `_hawk_serve()`. Add `listen(port)` that calls `_hawk_serve()` and sets `_HAWK_LISTEN_CALLED = 1`. The `END` block checks the flag to skip if `listen()` already ran. Port priority: `listen(port)` arg → `PORT` env var → 8080 default.

**Files:**
- Modify: `core/http.awk`

- [ ] **Step 1: Read the current END block to understand what to extract**

Current `END` block (lines 12-42 of `core/http.awk`):
```awk
END {
  if (!("HAWK_NO_SERVE" in ENVIRON)) {
    HAWK_PORT             = ENVIRON["PORT"]                  ? ENVIRON["PORT"]                  + 0 : 8080
    HAWK_MAX_HEADER_SIZE  = ENVIRON["HAWK_MAX_HEADER_SIZE"]  ? ENVIRON["HAWK_MAX_HEADER_SIZE"]  + 0 : 8192
    HAWK_MAX_BODY_SIZE    = ENVIRON["HAWK_MAX_BODY_SIZE"]    ? ENVIRON["HAWK_MAX_BODY_SIZE"]    + 0 : 1048576
    HAWK_REQUEST_TIMEOUT  = ENVIRON["HAWK_REQUEST_TIMEOUT"]  ? ENVIRON["HAWK_REQUEST_TIMEOUT"]  + 0 : 30
    HAWK_DEV              = (ENVIRON["DEV"] == "1")

    plugin_discover()
    ...
    http_serve()
    ...
    call_hooks("shutdown")
  }
}
```

- [ ] **Step 2: Refactor `core/http.awk`**

Replace the current `END` block with the following (the rest of the file — `http_serve`, `_http_serve_inet`, `_http_serve_zig`, etc. — stays unchanged):

```awk
END {
  if (!_HAWK_LISTEN_CALLED && !("HAWK_NO_SERVE" in ENVIRON)) {
    _hawk_serve()
  }
}

function listen(port) {
  if (port > 0) HAWK_PORT = port
  _hawk_serve()
  _HAWK_LISTEN_CALLED = 1
}

function _hawk_serve(    libs_list, lib) {
  # Apply env-based defaults (listen(port) arg already set HAWK_PORT if provided)
  if (!HAWK_PORT)            HAWK_PORT            = ENVIRON["PORT"]               ? ENVIRON["PORT"]               + 0 : 8080
  if (!HAWK_MAX_HEADER_SIZE) HAWK_MAX_HEADER_SIZE = ENVIRON["HAWK_MAX_HEADER_SIZE"] ? ENVIRON["HAWK_MAX_HEADER_SIZE"] + 0 : 8192
  if (!HAWK_MAX_BODY_SIZE)   HAWK_MAX_BODY_SIZE   = ENVIRON["HAWK_MAX_BODY_SIZE"]   ? ENVIRON["HAWK_MAX_BODY_SIZE"]   + 0 : 1048576
  if (!HAWK_REQUEST_TIMEOUT) HAWK_REQUEST_TIMEOUT = ENVIRON["HAWK_REQUEST_TIMEOUT"] ? ENVIRON["HAWK_REQUEST_TIMEOUT"] + 0 : 30
  HAWK_DEV = (ENVIRON["DEV"] == "1")

  plugin_discover()
  if (PLUGIN_REGISTER_ERROR) {
    log_error("plugin registration failed, exiting.")
    exit 1
  }
  call_hooks("init")

  libs_list = ""
  for (lib in LIBS_LOADED) {
    libs_list = libs_list (libs_list == "" ? "" : ", ") lib
  }
  log_info(sprintf("H-awk listening on http://0.0.0.0:%d%s", \
    HAWK_PORT, \
    libs_list == "" ? "" : " [libs: " libs_list "]"))

  HAWK_SHUTDOWN = 0
  http_serve()

  log_info("shutting down")
  call_hooks("shutdown")
}
```

- [ ] **Step 3: Run unit tests**

```bash
make test-unit 2>&1 | tail -5
```

Expected: all tests pass, 0 failed.

- [ ] **Step 4: Smoke test — old style (no `listen()` call)**

```bash
# Old style: no listen() in BEGIN, server starts from END
cat > /tmp/test_old_style.awk << 'EOF'
BEGIN {
  GET("/", "index")
}
function index(req, res) { text(res, "old style ok") }
EOF
DEV=1 timeout 3 ./bin/hawk /tmp/test_old_style.awk &
sleep 0.5
curl -s http://localhost:8080/
kill %1 2>/dev/null; wait 2>/dev/null
rm /tmp/test_old_style.awk
```

Expected: `old style ok`

- [ ] **Step 5: Smoke test — new style (explicit `listen()` in BEGIN)**

```bash
cat > /tmp/test_new_style.awk << 'EOF'
BEGIN {
  GET("/", "index")
  listen(8080)
}
function index(    ) {
  ctx::text("ctx style ok")
}
EOF
DEV=1 timeout 3 ./bin/hawk /tmp/test_new_style.awk &
sleep 0.5
curl -s http://localhost:8080/
kill %1 2>/dev/null; wait 2>/dev/null
rm /tmp/test_new_style.awk
```

Expected: `ctx style ok`

- [ ] **Step 6: Commit**

```bash
git add core/http.awk
git commit -m "feat(core/http): add listen(port) and extract _hawk_serve() for explicit startup"
```

---

### Task 5: Run full CI and verify

**Files:** none (verification only)

- [ ] **Step 1: Run full test suite**

```bash
make test 2>&1 | tail -10
```

Expected: all unit + e2e tests pass.

- [ ] **Step 2: Verify backward compat with existing example**

```bash
ls examples/
# pick any existing example (e.g. hello or todo)
DEV=1 timeout 3 ./bin/hawk examples/hello/app.awk &
sleep 0.5
curl -s http://localhost:8080/
kill %1 2>/dev/null; wait 2>/dev/null
```

Expected: example responds normally, no crashes.

- [ ] **Step 3: Verify ctx:: query/param in a handler**

```bash
cat > /tmp/test_ctx_query.awk << 'EOF'
BEGIN {
  GET("/items/:id", "show")
}
function show(    id, limit) {
  id    = ctx::param("id")
  limit = ctx::query("limit")
  ctx::text(id ":" limit)
}
EOF
DEV=1 timeout 3 ./bin/hawk /tmp/test_ctx_query.awk &
sleep 0.5
curl -s "http://localhost:8080/items/42?limit=10"
kill %1 2>/dev/null; wait 2>/dev/null
rm /tmp/test_ctx_query.awk
```

Expected: `42:10`
