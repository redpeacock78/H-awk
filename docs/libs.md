🌐 [日本語](ja/libs.ja.md) | [← Back to README](../README.md)

# Native Extensions (libs)

Optional Zig-compiled gawk extensions unlock capabilities beyond what AWK can do natively.

| Lib | Description |
|---|---|
| `libs/net` | Zig TCP event loop — keep-alive, SO_REUSEPORT multi-worker |
| `libs/binary` | Binary-safe file I/O (PNG, JPG, WebP, fonts, etc.) |
| `libs/multipart` | `multipart/form-data` parser for file uploads |
| `libs/crypto` | SHA-256 / HMAC-SHA256 |
| `libs/gzip` | Gzip / deflate compression |
| `libs/url` | High-performance URL encode/decode |
| `libs/cache` | Shared-memory cache backend for the [Cache API](api.md#cache-api-cache) |

H-awk runs without any libs. Missing libs degrade gracefully — e.g., the server falls back to gawk's `/inet/tcp/` transport if `libs/net` is absent, and the Cache API falls back to `file` or `memory` if `libs/cache` is absent.

## Multi-worker & Keep-Alive (`libs/net`)

When `libs/net` is built, `bin/hawk` spawns N independent gawk workers sharing the same port via `SO_REUSEPORT`. The OS kernel distributes incoming connections across workers. Each worker is supervised and auto-restarted on crash.

```sh
# CLI
./bin/hawk serve --workers 8 app.awk

# Make
make run WORKERS=8

# Environment
HAWK_WORKERS=8 ./bin/hawk app.awk
```

HTTP/1.1 keep-alive is enabled by default. Workers maintain idle connections and close them after a configurable timeout:

```sh
HAWK_KEEPALIVE_TIMEOUT=30 ./bin/hawk app.awk   # 30s idle timeout (default: 75)
```

| Variable | Default | Description |
|---|---|---|
| `HAWK_WORKERS` | `4` | Number of worker processes (requires `libs/net`) |
| `HAWK_KEEPALIVE_TIMEOUT` | `75` | Idle keep-alive timeout in seconds |

## Setup

```sh
# Build all libs (requires Zig 0.14+)
make build-libs

# Or fetch precompiled binaries (no Zig required)
HAWK_REPO=<owner>/<repo> make fetch-libs
```

Enabled libs are shown at startup:

```text
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```
