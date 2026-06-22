🌐 [日本語](setup.ja.md) | [← Back to README](../README.md)

# Setup & Installation

## Requirements

- gawk 5.0+ (`gawk --version`)
- bash 4.3+ (for multi-worker supervisor)
- GNU make
- Zig 0.14+ (only for `make build-libs`)
- curl (e2e tests only)

Tested on gawk 5.3.1 / macOS. Linux works. Windows via WSL only.

## Quickstart

```sh
cp .env.example .env

# Optional: build native extensions (binary I/O, TCP transport, etc.)
make build-libs

# Start the server (default :8080, 4 workers)
./bin/hawk app.awk

# Or with make
make run                  # 4 workers (default)
make run WORKERS=8        # 8 workers
make run WORKERS=1        # single worker (debug)
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
curl http://localhost:8080/todos.json
```

`make help` lists all available targets.

## Building Native Extensions

```sh
# Build all libs (requires Zig 0.14+)
make build-libs

# Or fetch precompiled binaries (no Zig required)
HAWK_REPO=<owner>/<repo> make fetch-libs
```

Enabled libs are shown at startup:

```
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```

See [Native Extensions](libs.md) for details on what each lib provides.
