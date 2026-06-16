# Design: CLI Flags (--no-emit / --emit / --strict) + Rust-style Error Messages

**Date**: 2026-06-16  
**Status**: Approved

## Overview

Two independent features:

1. **CLI flags** — `--no-emit`, `--emit`, `--strict` for type-checking and desugared output without starting the server.
2. **Rust-style error messages** — source line + caret + help text for all DSL errors.

## 1. CLI Flags

### New flags

| Flag | Behavior |
|------|----------|
| `--no-emit` | Run DSL desugar + typecheck only. No stdout output. No server start. Exit 0 on success, 1 on error. |
| `--emit` | Run DSL desugar, write desugared AWK to stdout. No server start. |
| `--strict` | Works with either flag above. After desugar, also runs `gawk --sandbox -f <tmp> < /dev/null` to catch AWK syntax errors. |

`--no-emit` and `--emit` together is an error (mutually exclusive).

### Usage examples

```bash
bin/hawk --no-emit app.awk           # CI: type-check only
bin/hawk --emit app.awk              # inspect desugared output
bin/hawk --no-emit --strict app.awk  # strict: DSL typecheck + gawk syntax
bin/hawk --emit --strict app.awk     # strict: emit + gawk syntax check
```

### Implementation

Changes in `bin/hawk` only (~20 lines):

- Parse `--no-emit`, `--emit`, `--strict` alongside existing flags.
- If both `--no-emit` and `--emit` given: print error to stderr, exit 1.
- After `_hawk_desugar_app`:
  - `--emit`: `cat "$APP_AWK"` to stdout, then exit (with exit code from desugar).
  - `--no-emit`: exit with desugar exit code (no server launch).
  - `--strict`: additionally run `gawk --sandbox -f "$APP_AWK" < /dev/null 2>&1` and propagate exit code.
- Without these flags: existing behavior unchanged.

**Note on `--strict`**: gawk has no parse-only mode. Running with `--sandbox` + `/dev/null` input blocks system calls and effectively validates AWK syntax from the desugared output. Not perfect (BEGIN block will attempt execution and fail silently), but catches AWK syntax errors in practice.

## 2. Rust-style Error Messages

### Format

```
error: type mismatch: cannot assign `Int` to `Str`
  --> app.awk:42
   |
42 |   let n: Int = "hello"
   |
  = help: use an Int literal or an arithmetic expression
```

Color: ANSI codes applied only when stderr is a tty (`ENVIRON["TERM"] != ""`).

Caret (`^^^`) for column-level highlighting is deferred. Line-level highlighting is sufficient for now.

### Implementation

**`dsl/desugar.awk`**:

1. Buffer source lines: add `{ _DS_src_lines[NR] = $0 }` to main loop.
2. Add shared helper:

```awk
function _ds_error(lineno, msg, help,    src) {
    src = _DS_src_lines[lineno]
    print "error: " msg > "/dev/stderr"
    print "  --> " _DS_src_file ":" lineno > "/dev/stderr"
    print "   |" > "/dev/stderr"
    printf "%3d | %s\n", lineno, src > "/dev/stderr"
    print "   |" > "/dev/stderr"
    if (help != "") print "   = help: " help > "/dev/stderr"
    _DS_had_error = 1
}
```

**`dsl/desugar_let.awk`** (4 error sites) — migrate to `_ds_error()` with English help text:

| Error | Help text |
|-------|-----------|
| unknown function | `define the function before use, or check the spelling` |
| safe/brand type annotation | `use a trusted sanitizer function to construct this type` |
| type mismatch on assignment | `use a value of type \`<declared>\` or remove the type annotation` |
| `?=` requires Option/Result | `\`?=\` only works with \`Option<T>\` or \`Result<T,E>\` types` |

**`dsl/desugar_match.awk`** (3 error sites) — same migration:

| Error | Help text |
|-------|-----------|
| body line before any arm | `move this line inside an \`ok:\`, \`ng:\`, or \`default:\` arm` |
| missing ng/none/default branch | `add an \`ng:\` or \`default:\` arm to handle the error case` |
| union exhaustiveness | `add \`ng e: <Type>:\` arms for each missing error type` |

## 3. Architecture Summary

```
bin/hawk
  ├── parse --no-emit / --emit / --strict
  ├── _hawk_desugar_app() → runs dsl/desugar.awk
  │     ├── buffers source lines (_DS_src_lines)
  │     ├── calls _ds_error() for all DSL errors (Rust-style output)
  │     └── exit 1 on error
  ├── [--emit]    → cat desugared AWK to stdout, exit
  ├── [--no-emit] → exit with desugar status
  ├── [--strict]  → gawk --sandbox syntax check, exit
  └── [default]   → launch gawk workers (unchanged)
```

## 4. Testing

- `--no-emit` exit code: valid file → 0, DSL error file → 1.
- `--emit` output: snapshot test comparing desugared stdout to expected.
- Error format: snapshot test comparing stderr to expected Rust-style output.
- Existing e2e tests (server startup): unaffected.
