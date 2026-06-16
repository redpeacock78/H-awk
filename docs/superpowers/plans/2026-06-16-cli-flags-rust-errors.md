# CLI Flags + Rust-style Error Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--no-emit` / `--emit` / `--strict` CLI flags to `bin/hawk`, and upgrade all DSL error messages to a Rust-style multi-line format with source context.

**Architecture:** `_ds_error()` helper added to `dsl/desugar.awk` provides the Rust-style output; all error sites in `desugar_let.awk` and `desugar_match.awk` migrate to it. `bin/hawk` gains three new flags controlling whether to start the server or emit desugared AWK to stdout. Existing tests keep passing because the test runner does substring matching and existing `expected_stderr` fixtures contain message text that appears in the new format too.

**Tech Stack:** gawk (AWK), bash

---

## File Map

| File | Change |
|------|--------|
| `dsl/desugar.awk` | Add `_DS_src_lines[FNR]` buffer rule; add `_ds_error()` helper; migrate 4 error sites |
| `dsl/desugar_let.awk` | Migrate 4 error sites to `_ds_error()` |
| `dsl/desugar_match.awk` | Migrate 3 error sites to `_ds_error()` |
| `bin/hawk` | Add `--no-emit`, `--emit`, `--strict` flag parsing and flow control |
| `tests/unit/dsl/rust_error_format/input.awk` | New test fixture (TDD for new format) |
| `tests/unit/dsl/rust_error_format/expected_stderr` | Expects `  -->` marker (new format signal) |
| `tests/unit/cli/run.sh` | New test script for CLI flags |

---

## Task 1: Add `_ds_error()` helper and source line buffer (TDD)

**Files:**
- Modify: `dsl/desugar.awk`
- Create: `tests/unit/dsl/rust_error_format/input.awk`
- Create: `tests/unit/dsl/rust_error_format/expected_stderr`

- [ ] **Step 1: Write failing test fixture**

Create `tests/unit/dsl/rust_error_format/input.awk`:
```awk
function handler() {
  let n: Int = "hello"
}
```

Create `tests/unit/dsl/rust_error_format/expected_stderr`:
```
  -->
```

(The `-->` substring only appears in the new Rust-style format, not the old `dsl error:` format.)

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -A3 "rust_error_format"
```

Expected: `FAIL: rust_error_format` (old format has no `-->`)

- [ ] **Step 3: Add source line buffer rule to `dsl/desugar.awk`**

Add this rule between `FNR == 1 { ... }` and `{ _ds_process_line($0, FNR) }` at line 37-42:

```awk
FNR == 1 {
  _DS_src_file = FILENAME
  print "# line 1 \"" FILENAME "\""
}

{ _DS_src_lines[FNR] = $0 }

{ _ds_process_line($0, FNR) }
```

- [ ] **Step 4: Add `_ds_error()` helper function to `dsl/desugar.awk`**

Add after the `_ds_net_braces` function (after line 219):

```awk
function _ds_error(lineno, msg, help,    src, use_color, r, n, b) {
    use_color = (ENVIRON["TERM"] != "" && ENVIRON["NO_COLOR"] == "")
    r = use_color ? "\033[31m" : ""  # red
    b = use_color ? "\033[1m"  : ""  # bold
    n = use_color ? "\033[0m"  : ""  # reset
    src = (lineno in _DS_src_lines) ? _DS_src_lines[lineno] : ""
    printf "%serror%s: %s\n", b r, n, msg > "/dev/stderr"
    printf "  --> %s:%d\n", _DS_src_file, lineno > "/dev/stderr"
    print "   |" > "/dev/stderr"
    if (src != "") printf "%3d | %s\n", lineno, src > "/dev/stderr"
    print "   |" > "/dev/stderr"
    if (help != "") printf "   = help: %s\n", help > "/dev/stderr"
    _DS_had_error = 1
}
```

- [ ] **Step 5: Migrate one error site in `dsl/desugar.awk` to use `_ds_error()`**

Migrate the 'let' outside function body error at lines 57-60. Replace:
```awk
      print "dsl error: " _DS_src_file ":" lineno \
        ": 'let' outside function body" > "/dev/stderr"
      _DS_had_error = 1
      exit 1
```

With:
```awk
      _ds_error(lineno, "'let' outside function body", \
        "move 'let' declarations inside a function")
      exit 1
```

- [ ] **Step 6: Run test to verify it passes**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -5
```

Expected: `rust_error_format` PASS. All other tests still pass (substring match still works).

- [ ] **Step 7: Commit**

```bash
git add dsl/desugar.awk tests/unit/dsl/rust_error_format/
git commit -m "feat(dsl): add _ds_error() helper with Rust-style error format"
```

---

## Task 2: Migrate remaining error sites in `dsl/desugar.awk`

**Files:**
- Modify: `dsl/desugar.awk`

Three remaining error sites: END block "unclosed function", and two return-type errors in `_ds_check_return`.

- [ ] **Step 1: Migrate END block "unclosed function" error (lines 46-50)**

Replace:
```awk
END {
  if (_DS_had_error) exit 1
  if (_DS_in_function) {
    print "dsl error: " _DS_src_file ": unclosed function '" _DS_func_name "'" \
      > "/dev/stderr"
    exit 1
  }
}
```

With:
```awk
END {
  if (_DS_had_error) exit 1
  if (_DS_in_function) {
    _ds_error(_DS_current_lineno, \
      "unclosed function '" _DS_func_name "'", \
      "add a closing '}' to end the function body")
    exit 1
  }
}
```

- [ ] **Step 2: Migrate return type Void error in `_ds_check_return` (lines 271-274)**

Replace:
```awk
  if (_DS_func_ret_type == "Void") {
    print "dsl error: " _DS_src_file ":" lineno \
        ": function " _DS_func_name " expects Void, got " actual > "/dev/stderr"
    _DS_had_error = 1
    return
  }
```

With:
```awk
  if (_DS_func_ret_type == "Void") {
    _ds_error(lineno, \
      "function " _DS_func_name " expects Void, got " actual, \
      "remove the return value, or change the function's return type")
    return
  }
```

- [ ] **Step 3: Migrate return type mismatch error in `_ds_check_return` (lines 276-280)**

Replace:
```awk
  if (!type::accepts(_DS_func_ret_type, actual)) {
    print "dsl error: " _DS_src_file ":" lineno \
        ": function " _DS_func_name " expects return " _DS_func_ret_type ", got " actual > "/dev/stderr"
    _DS_had_error = 1
  }
```

With:
```awk
  if (!type::accepts(_DS_func_ret_type, actual)) {
    _ds_error(lineno, \
      "function " _DS_func_name " expects return " _DS_func_ret_type ", got " actual, \
      "return a value of type " _DS_func_ret_type ", or update the return type annotation")
  }
```

- [ ] **Step 4: Run all unit tests**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add dsl/desugar.awk
git commit -m "feat(dsl): migrate desugar.awk error sites to _ds_error()"
```

---

## Task 3: Migrate error sites in `dsl/desugar_let.awk`

**Files:**
- Modify: `dsl/desugar_let.awk`

Four error sites.

- [ ] **Step 1: Migrate unknown function error (lines 52-55)**

Replace:
```awk
        print "dsl error: " _DS_src_file ":" _DS_current_lineno \
            ": unknown function " fname > "/dev/stderr"
        _DS_had_error = 1
        return ""
```

With:
```awk
        _ds_error(_DS_current_lineno, "unknown function " fname, \
            "define the function before use, or check the spelling")
        return ""
```

- [ ] **Step 2: Migrate brand forgery error (lines 68-73)**

Replace:
```awk
        print "dsl error: " _DS_src_file ":" lineno \
            ": safe/brand type cannot be created by annotation" > "/dev/stderr"
        print "  " declared " must be constructed by trusted sanitizer" > "/dev/stderr"
        _DS_had_error = 1
        return
```

With:
```awk
        _ds_error(lineno, "safe/brand type cannot be created by annotation", \
            declared " must be constructed by a trusted sanitizer function")
        return
```

- [ ] **Step 3: Migrate type mismatch error (lines 75-77)**

Replace:
```awk
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
```

With:
```awk
    _ds_error(lineno, "type mismatch: cannot assign " inferred " to " declared, \
        "use a value of type " declared ", or remove the type annotation")
```

- [ ] **Step 4: Migrate `?=` requires Option/Result error (lines 132-135)**

Replace:
```awk
      print "dsl error: " _DS_src_file ":" lineno \
          ": ?= requires Option or Result, got " declared > "/dev/stderr"
      _DS_had_error = 1
      return ""
```

With:
```awk
      _ds_error(lineno, "?= requires Option or Result, got " declared, \
          "use ?= only with Option<T> or Result<T,E> types")
      return ""
```

- [ ] **Step 5: Run all unit tests**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_let.awk
git commit -m "feat(dsl): migrate desugar_let.awk error sites to _ds_error()"
```

---

## Task 4: Migrate error sites in `dsl/desugar_match.awk`

**Files:**
- Modify: `dsl/desugar_match.awk`

Three error sites.

- [ ] **Step 1: Migrate "body line before any arm" error (lines 97-100)**

Replace:
```awk
      print "dsl error: " _DS_src_file ":" lineno \
        ": when...of body line before any arm" > "/dev/stderr"
      _DS_had_error = 1
      return ""
```

With:
```awk
      _ds_error(lineno, "when...of body line before any arm", \
          "move this line inside an ok:, ng:, or default: arm")
      return ""
```

- [ ] **Step 2: Migrate "missing ng/none/default branch" error (lines 127-131)**

Replace:
```awk
  if (_DS_match_ng_arms == 0) {
    print "dsl error: " _DS_src_file ":" lineno \
      ": when...of missing ng/none/default branch" > "/dev/stderr"
    _DS_had_error = 1
    _ds_match_reset()
    return
  }
```

With:
```awk
  if (_DS_match_ng_arms == 0) {
    _ds_error(lineno, "when...of missing ng/none/default branch", \
        "add an ng: or default: arm to handle the error case")
    _ds_match_reset()
    return
  }
```

- [ ] **Step 3: Migrate union exhaustiveness error (lines 175-180)**

Replace:
```awk
            print "dsl error: " _DS_src_file ":" lineno \
              ": when...of missing arm for " _ds_union_members[i] \
              " (add 'ng e: " _ds_union_members[i] ":' or 'default:')" > "/dev/stderr"
            _DS_had_error = 1
```

With:
```awk
            _ds_error(lineno, \
              "when...of missing arm for " _ds_union_members[i], \
              "add 'ng e: " _ds_union_members[i] ":' or 'default:'")
```

- [ ] **Step 4: Run all unit tests**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add dsl/desugar_match.awk
git commit -m "feat(dsl): migrate desugar_match.awk error sites to _ds_error()"
```

---

## Task 5: Add CLI flags to `bin/hawk`

**Files:**
- Modify: `bin/hawk`
- Create: `tests/unit/cli/run.sh`
- Create: `tests/unit/cli/fixtures/valid.awk`
- Create: `tests/unit/cli/fixtures/invalid.awk`

- [ ] **Step 1: Create CLI test script**

Create `tests/unit/cli/fixtures/valid.awk`:
```awk
BEGIN {
  hawk.app.get("/", "index")
  hawk.app.listen(8080)
}

function index() {
  return ctx.res.text("ok")
}
```

Create `tests/unit/cli/fixtures/invalid.awk`:
```awk
function handler() {
  let n: Int = "bad"
}
```

Create `tests/unit/cli/run.sh`:
```bash
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0
HAWK=./bin/hawk
VALID=tests/unit/cli/fixtures/valid.awk
INVALID=tests/unit/cli/fixtures/invalid.awk

check() {
  local name="$1" expected_exit="$2"
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [[ "$actual" -eq "$expected_exit" ]]; then
    printf "  PASS: %s\n" "$name"
    PASS=$((PASS+1))
  else
    printf "  FAIL: %s (expected exit %d, got %d)\n" "$name" "$expected_exit" "$actual"
    FAIL=$((FAIL+1))
  fi
}

# --no-emit: valid file exits 0
check "no_emit_valid_exits_0"   0  $HAWK --no-emit "$VALID"
# --no-emit: invalid file exits 1
check "no_emit_invalid_exits_1" 1  $HAWK --no-emit "$INVALID"
# --emit: valid file exits 0, produces output
set +e
emit_out=$(HAWK_NO_LIBS=1 $HAWK --emit "$VALID" 2>/dev/null)
emit_exit=$?
set -e
if [[ "$emit_exit" -eq 0 && -n "$emit_out" ]]; then
  printf "  PASS: emit_produces_output\n"; PASS=$((PASS+1))
else
  printf "  FAIL: emit_produces_output (exit=%d, output=%s)\n" "$emit_exit" "$emit_out"
  FAIL=$((FAIL+1))
fi
# --no-emit and --emit together: exits 1 with error message
set +e
combo_out=$(HAWK_NO_LIBS=1 $HAWK --no-emit --emit "$VALID" 2>&1)
combo_exit=$?
set -e
if [[ "$combo_exit" -ne 0 ]] && printf '%s' "$combo_out" | grep -q "mutually exclusive"; then
  printf "  PASS: no_emit_and_emit_error\n"; PASS=$((PASS+1))
else
  printf "  FAIL: no_emit_and_emit_error (exit=%d)\n" "$combo_exit"
  FAIL=$((FAIL+1))
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

Make executable:
```bash
chmod +x tests/unit/cli/run.sh
```

- [ ] **Step 2: Run CLI tests to verify they fail**

```bash
bash tests/unit/cli/run.sh
```

Expected: all FAIL (flags not yet implemented).

- [ ] **Step 3: Add flag parsing to `bin/hawk`**

In `bin/hawk`, add `NO_EMIT`, `EMIT`, `STRICT` variables and parsing. Find the existing `while [[ $# -gt 0 ]]; do` loop (around line 20) and add cases:

```bash
NO_EMIT=0
EMIT=0
STRICT=0
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers|-w)
      WORKERS="$2"
      shift 2
      ;;
    --workers=*)
      WORKERS="${1#*=}"
      shift
      ;;
    --debug)
      HAWK_DEBUG=1
      shift
      ;;
    --no-emit)
      NO_EMIT=1
      shift
      ;;
    --emit)
      EMIT=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
```

- [ ] **Step 4: Add mutual exclusion check and mode handling**

After the `APP` file existence check (after the current `if [[ ! -f "$APP" ]]; then` block), add:

```bash
if [[ "$NO_EMIT" -eq 1 && "$EMIT" -eq 1 ]]; then
  echo "[hawk] --no-emit and --emit are mutually exclusive" >&2
  exit 1
fi
```

After the `APP_AWK=$(_hawk_desugar_app "$APP")` call (and the trap line), add the mode handling before the worker loop:

```bash
# --emit: print desugared AWK to stdout, exit
if [[ "$EMIT" -eq 1 ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    gawk --sandbox -f "$APP_AWK" < /dev/null 2>/dev/null || {
      echo "[hawk] --strict: gawk syntax error in desugared output" >&2
      exit 1
    }
  fi
  cat "$APP_AWK"
  exit 0
fi

# --no-emit: type-check only, exit without starting server
if [[ "$NO_EMIT" -eq 1 ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    gawk --sandbox -f "$APP_AWK" < /dev/null 2>/dev/null || {
      echo "[hawk] --strict: gawk syntax error in desugared output" >&2
      exit 1
    }
  fi
  exit 0
fi
```

The block should appear between the `[[ -z "${HAWK_DEBUG}" ]] && trap ...` line and the `# Start N workers` comment.

- [ ] **Step 5: Run CLI tests to verify they pass**

```bash
bash tests/unit/cli/run.sh
```

Expected: all PASS.

- [ ] **Step 6: Run all unit tests to verify no regression**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add bin/hawk tests/unit/cli/
git commit -m "feat(cli): add --no-emit, --emit, --strict flags to bin/hawk"
```

---

## Self-Review Checklist

- [x] **Spec coverage**: All spec sections covered — CLI flags (Task 5), error format (Tasks 1-4), `--strict` gawk check (Task 5 Step 4)
- [x] **No placeholders**: All steps have concrete code
- [x] **Type consistency**: `_ds_error(lineno, msg, help)` signature used consistently across Tasks 1-4
- [x] **Existing tests**: All existing `expected_stderr` fixtures use substring matching; new format still contains the same message text, so no fixture updates needed
- [x] **`--strict` limitation noted in spec**: gawk has no parse-only mode; `--sandbox + /dev/null` is the practical workaround
