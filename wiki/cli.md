🌐 [日本語](cli.ja.md) | [← Back to README](../README.md)

# CLI Reference

```sh
./bin/hawk [serve] [--workers N] [--debug] <app.awk>
./bin/hawk emit    [--strict]             <app.awk>
./bin/hawk check   [--strict]             <app.awk>
./bin/hawk help
```

| Subcommand | Description |
|---|---|
| `serve` | Start HTTP server. Default when no subcommand is given — `hawk app.awk` and `hawk serve app.awk` are equivalent. |
| `emit` | Print the desugared AWK source to stdout and exit. Useful for inspecting what the DSL preprocessor produces. |
| `check` | Run the DSL preprocessor and exit without starting the server. Exits 0 on success, 1 on error. |
| `help` | Print usage summary. |

`--strict` runs the desugared output through `gawk --sandbox` for additional syntax validation. Available in `emit` and `check`.

Use `--debug` to inspect the generated file:

```sh
./bin/hawk serve --debug app.awk   # prints temp file path to stderr
```
