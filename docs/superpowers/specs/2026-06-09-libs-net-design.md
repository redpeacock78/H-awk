# libs/net Design Spec

## Overview

Replace gawk's built-in `/inet/tcp/` synchronous single-connection handling with a Zig-backed async TCP server that manages multiple simultaneous connections. AWK user code (`app.awk`) remains completely unchanged.

## Goals

- Multiple simultaneous TCP connections (not serialized by gawk's single-thread)
- HTTP/1.1 Keep-Alive support managed entirely by Zig
- AWK code under `app.awk` and `router.awk` is untouched
- Graceful fallback to `/inet/tcp/` when `libs/net` is not loaded
- Shared HTTP parsing code reusable by future `libs/fetch`

## Non-Goals

- AWK multi-threading (gawk remains single-threaded; Zig queues requests)
- TLS/HTTPS (out of scope)
- HTTP/2 or HTTP/3

## Architecture

```
[Client A] ──┐
[Client B] ──┤── TCP ──▶ [Zig event loop (background thread)]
[Client C] ──┘               │  epoll (Linux) / kqueue (macOS)
                              │  HTTP/1.1 parse per connection
                              │  conn_id → request queue
                              │
                         hawk_net_poll()  ◀── AWK (blocks until request ready)
                              │
                         returns: "conn_id\nmethod\npath\nheaders\nbody"
                              │
                         AWK → router.awk → app.awk → response.awk
                              │
                         hawk_net_respond(conn_id, status, headers, body)
                              │
                         [Zig] → Keep-Alive decision → [Client]
```

Zig's background thread starts at `dl_load` time. AWK calls `hawk_net_poll()` in a tight loop — this call blocks until a complete HTTP request is available. Zig handles all socket I/O asynchronously; AWK remains synchronous and single-threaded from its own perspective.

## AWK-Facing API

### `hawk_net_listen(port)`

- Binds TCP socket, starts Zig background event loop thread
- Idempotent: calling twice on the same port is a no-op
- Returns `1` on success, `0` on failure (port in use, etc.)

### `hawk_net_poll()`

- Blocks until a complete HTTP/1.1 request is ready
- Returns a newline-delimited string:

```
conn_id
METHOD
/path
Header-Name: value\r\nHeader-Name2: value2\r\n
body_bytes
```

- Returns empty string `""` on Zig thread failure (triggers fallback)

### `hawk_net_respond(conn_id, status_line, headers, body)`

- Sends HTTP response to the identified connection
- `status_line`: e.g. `"HTTP/1.1 200 OK"`
- `headers`: raw header block, e.g. `"Content-Type: text/plain\r\nContent-Length: 5\r\n"`
- `body`: response body bytes
- Zig decides Keep-Alive vs close based on request's `Connection` header
- Returns `1` on success, `0` if conn_id is unknown/closed

## Fallback Behavior

`http.awk` detects whether `libs/net` is loaded via `PROCINFO["identifiers"]`:

```awk
function http_serve(    ...) {
  if ("hawk_net_listen" in PROCINFO["identifiers"]) {
    _http_serve_zig()
  } else {
    _http_serve_inet()  # existing /inet/tcp/ implementation
  }
}
```

`_http_serve_inet()` is the current `http_serve()` body, renamed. No behavior change when `libs/net` is absent.

## Files Changed

### New files

- `libs/net/build.zig` — build definition, links against `libs/_common/gawk_ffi.zig`
- `libs/net/src/root.zig` — `dl_load` via `ffi.makeDlLoad`, registers 3 functions
- `libs/net/src/event_loop.zig` — epoll (Linux) / kqueue (macOS) event loop
- `libs/net/src/http_parser.zig` — HTTP/1.1 request parser (future: shared with `libs/fetch`)
- `libs/net/src/conn_pool.zig` — connection state management (conn_id → socket fd + state)

### Modified files

- `core/http.awk` — add fallback dispatch; extract `_http_serve_inet()` from current `http_serve()`; add `_http_serve_zig()` using `hawk_net_listen/poll/respond`
- `core/request.awk` — add `parse_request_zig(poll_result)` that reads structured fields from `hawk_net_poll()` output; existing `parse_request()` retained for fallback
- `build.zig` (root) — add `libs/net` to build targets
- `Makefile` — add `libs/net` to `build-libs` and `test-libs` targets

## Data Flow: Zig Path

1. `http.awk` calls `hawk_net_listen(PORT)`
2. Loop: `hawk_net_poll()` → blocks
3. Zig delivers next complete request: `"<id>\n<method>\n<path>\n<headers>\n<body>"`
4. `request.awk:parse_request_zig()` splits on `\n`, populates `req[]` array
5. `router.awk` dispatches to handler, `app.awk` runs user logic
6. `response.awk` builds status/headers/body strings
7. `http.awk` calls `hawk_net_respond(id, status, headers, body)`
8. Back to step 2

## Error Handling

| Event | Zig behavior | AWK behavior |
|---|---|---|
| Client disconnects before respond | Drop conn_id silently | `hawk_net_respond()` returns `0`; AWK ignores |
| Client disconnects mid-request | Zig discards partial read | Never delivered to AWK |
| `hawk_net_respond()` on stale conn_id | Zig returns `0` | AWK logs warning, continues loop |
| Zig thread panic | `hawk_net_poll()` returns `""` | AWK exits loop, process exits (same as current SIGTERM behavior) |
| Port already bound | `hawk_net_listen()` returns `0` | AWK logs error, falls through to `/inet/tcp/` |
| Request exceeds `HAWK_MAX_BODY_SIZE` | Zig sends 413, closes conn | Never delivered to AWK |
| Connection idle > `HAWK_REQUEST_TIMEOUT` seconds | Zig closes conn | Never delivered to AWK |

## Keep-Alive

Zig reads the `Connection` header from the parsed request:
- `Connection: keep-alive` (or HTTP/1.1 default) → Zig holds socket open after `hawk_net_respond()`
- `Connection: close` → Zig closes after sending response

AWK has no visibility into Keep-Alive state. Each `hawk_net_poll()` return is always a complete, independent request.

## Shared Code for Future `libs/fetch`

`http_parser.zig` is designed to parse both requests and responses:
- Request parse: `parseRequest(buf) → Request{ method, path, headers, body }`
- Response parse: `parseResponse(buf) → Response{ status, headers, body }`

`conn_pool.zig` manages both inbound (server) and outbound (client) connections with a unified interface. `libs/fetch` will `@import` these modules directly.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | Listen port (existing) |
| `HAWK_REQUEST_TIMEOUT` | `30` | Seconds before idle connection closed (existing, now enforced by Zig) |
| `HAWK_MAX_BODY_SIZE` | `1048576` | Max request body bytes (existing, now enforced by Zig) |
| `HAWK_MAX_CONNECTIONS` | `1024` | Max simultaneous connections (new) |

## Testing

- Unit tests in `libs/net/src/` (Zig test blocks): event loop, HTTP parser, conn pool
- Integration test: `make test` e2e suite runs against Zig path when `libs/net` is built
- Fallback test: `HAWK_NO_NET_LIB=1` env var skips `libs/net` load, verifies `/inet/tcp/` path still passes all e2e tests
- Concurrency test: `ab -n 1000 -c 50 http://localhost:8080/` smoke test (not in CI, manual)
