<div align="center">

# H-awk

**Express-style HTTP server for GNU AWK**

[![CI](https://github.com/redpeacock78/hawk/actions/workflows/ci.yml/badge.svg)](https://github.com/redpeacock78/hawk/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Write backends in plain AWK. No Node. No Python. No compiled binaries.

</div>

---

## Features

- **Express-like routing** — `hawk.app.get`, `.post`, `.del`, and friends
- **Type-safe DSL** — `let`, `when...of`, `??`, `|>`, and compile-time type annotations
- **XSS-safe by design** — brand types make unsafe HTML a desugar-time error
- **Multi-worker** — `SO_REUSEPORT` + HTTP/1.1 keep-alive via optional Zig extensions

## Quick Start

**Requirements:** gawk 5.0+, bash 4.3+, GNU make

```sh
cp .env.example .env
./bin/hawk app.awk        # Start on :8080 with 4 workers
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
```

```awk
BEGIN {
  hawk.app.get("/todos", "list_todos")
  hawk.app.post("/todos", "add_todo")
  hawk.app.listen(8080)
}

function list_todos() {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let payload = []
  payload["count"] = n
  return ctx.res.json(payload)
}

function add_todo() {
  when ctx.req.form("title") of
    ok raw:
      ctx.res.status(201)
      return ctx.res.html(safe.html.fragment(
        "<li>", safe.html.escape(raw), "</li>"
      ))
    ng:
      ctx.res.status(400)
      return ctx.res.text("title required")
  end
}
```

## Documentation

| | |
|---|---|
| [Setup & Installation](wiki/setup.md) | Requirements, build-libs, fetch-libs |
| [CLI Reference](wiki/cli.md) | Subcommands and flags |
| [Routing](wiki/routing.md) | Route registration, router files |
| [DSL Reference](wiki/dsl.md) | `let`, `when...of`, `??`, `\|>`, types, safe HTML |
| [API Reference](wiki/api.md) | Context API, request/response, `env::` |
| [Plugins](wiki/plugins.md) | Plugin hooks, submodule distribution |
| [Native Extensions](wiki/libs.md) | Zig libs, cache API, multi-worker |
| [Testing](wiki/testing.md) | Test targets and CI |

---

MIT © redpeacock78 · 🌐 [日本語](README.ja.md)
