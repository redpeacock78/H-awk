# DSL Phase 4: Documentation Improvements

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document three known DSL limitations clearly in README.md, and add a `--strict` mode warning for `let` inside control-flow blocks.

**Architecture:** README.md edits for Issues #4, #5, #8. A strict-mode warning in `desugar_let.awk` for Issue #4 (let hoisting).

**Tech Stack:** gawk 5.3.1, existing DSL test harness (`make test-dsl`).

**Prerequisite:** Phases 1–3 complete (documentation reflects final behavior).

---

## File Map

- Modify: `README.md` — document let hoisting, ?? semantics, parser limitation
- Modify: `dsl/desugar_let.awk` — strict mode warning for let inside if/while blocks
- Create: `tests/unit/dsl/let_in_block_strict_warn/input.awk`
- Create: `tests/unit/dsl/let_in_block_strict_warn/expected_stderr`

---

## Task 1: `let` hoisting strict-mode warning (RED)

**Files:**
- Create: `tests/unit/dsl/let_in_block_strict_warn/input.awk`
- Create: `tests/unit/dsl/let_in_block_strict_warn/expected_stderr`

- [ ] **Step 1: Write the failing test**

`tests/unit/dsl/let_in_block_strict_warn/input.awk`:
```awk
function handler() -> Response {
  if (1) {
    let x: Str = "hello"
  }
  return ctx.res.text(x)
}
```

`tests/unit/dsl/let_in_block_strict_warn/expected_stderr`:
```
let inside control-flow block
```

Also create a matching `expected_exit` file (warnings in strict mode exit non-zero):

`tests/unit/dsl/let_in_block_strict_warn/expected_exit`:
```
0
```

Note: this test must pass the DSL source through with `--strict` flag. Check how other strict tests are handled in `tests/unit/dsl/run.sh`:

```bash
grep -n "strict" tests/unit/dsl/run.sh
```

If no strict-flag support exists in the runner, add it in Task 2 Step 1.

- [ ] **Step 2: Run and verify FAIL**

```bash
make test-dsl 2>&1 | grep let_in_block_strict_warn
```

Expected: FAIL (no warning currently emitted).

---

## Task 2: Add strict-mode let-in-block warning to desugar_let.awk

**Files:**
- Modify: `dsl/desugar_let.awk`
- Possibly modify: `tests/unit/dsl/run.sh`

- [ ] **Step 1: Check if test runner supports strict mode**

```bash
grep -n "strict\|STRICT\|\-\-strict" tests/unit/dsl/run.sh
```

If not found, add support by checking for a `strict` flag file in each test dir. Add to `tests/unit/dsl/run.sh`, inside the loop after `name=$(basename "$dir")`:

```bash
  # strict flag: run desugar with HAWK_STRICT=1 env var if "strict" file exists
  strict_args=""
  if [[ -f "${dir}strict" ]]; then
    strict_args="-v _DS_strict=1"
  fi
```

Then use `$strict_args` in the gawk invocations.

- [ ] **Step 2: Create strict flag file for the test**

```bash
echo "" > tests/unit/dsl/let_in_block_strict_warn/strict
```

- [ ] **Step 3: Add warning in desugar_let.awk**

In `dsl/desugar_let.awk`, find where `let` inside the function body is processed (the code that emits local variable declarations). Look for the block that handles `let x: T = expr` patterns.

Find the function that processes a `let` statement — likely called from `_ds_process_line`. Add a block-depth check:

```bash
grep -n "_DS_block_depth\|block.depth\|let.*inside\|if.*let" dsl/desugar_let.awk | head -10
```

If `_DS_block_depth` is tracked (it should be — `if`/`while` increase it), add:

```awk
# Strict warning: let inside control-flow block behaves as function-scope var
if (awk::_DS_strict && _DS_block_depth > 0) {
    printf "%s: warning: let inside control-flow block (hoisted to function scope) at line %d\n", \
        _DS_src_file, _DS_current_lineno > "/dev/stderr"
}
```

Place this check inside the `let` processing function, before the variable is added to `_DS_let_locals`.

Check `desugar_state.awk` for how `_DS_block_depth` is incremented:

```bash
grep -n "_DS_block_depth\|block_depth" dsl/desugar_state.awk dsl/desugar.awk | head -15
```

If `_DS_block_depth` is not tracked, add tracking in the main `_ds_process_line` function in `desugar.awk`:

```awk
# Track control-flow block depth (for strict let warning)
if ($0 ~ /^[[:space:]]*(if|while|for)[[:space:]]*\(/) _DS_block_depth++
if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/ && _DS_block_depth > 0) _DS_block_depth--
```

And add `_DS_block_depth = 0` in `_ds_init()`.

Also add `_DS_strict` initialization:

```awk
# In _ds_init() in desugar_state.awk:
_DS_strict = (ENVIRON["HAWK_STRICT"] == "1" || ("_DS_strict" in ARGV))
```

Or more simply, `_DS_strict` is passed as a `-v` argument from the test runner.

- [ ] **Step 4: Run let_in_block_strict_warn test**

```bash
make test-dsl 2>&1 | grep let_in_block_strict_warn
```

Expected: PASS.

- [ ] **Step 5: Verify no regression on existing let tests**

```bash
make test-dsl 2>&1 | grep let
```

Expected: all let tests PASS (strict warning only fires when `_DS_strict=1` and `_DS_block_depth > 0`).

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_let.awk dsl/desugar_state.awk dsl/desugar.awk \
  tests/unit/dsl/let_in_block_strict_warn/ tests/unit/dsl/run.sh
git commit -m "feat(dsl): strict-mode warning for let inside control-flow blocks

let is always function-scoped (AWK constraint). In --strict mode,
using let inside if/while/for emits a warning to stderr."
```

---

## Task 3: Document `let` hoisting in README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the let documentation section**

```bash
grep -n "^## let\|^### let\|## Variables\|let x:" README.md | head -10
```

Note the line number of the `let` section.

- [ ] **Step 2: Add hoisting caveat**

In the `let` section of `README.md`, after the existing examples, add:

```markdown
**Scope note:** `let` declarations are function-scoped, not block-scoped.
AWK transforms all `let` bindings into function parameter locals regardless of
where they appear in the function body.
A `let` inside an `if` block is visible for the entire function — behaving
like JavaScript's `var`, not `let`.

```awk
function example() {
  if (condition) {
    let x: Str = "hello"   # x is visible for the whole function
  }
  return x  # valid, but may be "" if condition was false
}
```

Use `--strict` mode (`HAWK_STRICT=1`) to get a warning when `let` appears inside a control-flow block.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document let hoisting (function-scope, not block-scope)"
```

---

## Task 4: Document `??` operator AWK semantics in README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the ?? documentation section**

```bash
grep -n "??\|nullcoal\|null coalescing" README.md | head -10
```

- [ ] **Step 2: Add AWK semantics caveat**

In the `??` section, add after the existing description:

```markdown
**AWK semantics note:** `??` tests for empty string `""`, not for falsy values.
The number `0` is not an empty string in AWK, so `0 ?? "default"` evaluates to `0`,
not `"default"`.

| Expression | Result |
|-----------|--------|
| `"" ?? "default"` | `"default"` |
| `0 ?? "default"` | `0` |
| `"hello" ?? "default"` | `"hello"` |

If you need to guard against both `""` and `0`, use an explicit `if`:
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document ?? operator AWK semantics (empty string, not falsy)"
```

---

## Task 5: Document regex-parser limitation in README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find where function syntax is documented**

```bash
grep -n "^## function\|^### function\|function.*->" README.md | head -10
```

- [ ] **Step 2: Add one-line constraint**

In the function definition section, add:

```markdown
**Parser constraint:** Function definitions must fit on a single line.
The DSL preprocessor uses regex-based parsing (not an AST), so multi-line
function signatures are not supported:

```awk
# Not supported — multi-line signature
function handler(
  id: Str
) -> Response { ... }

# Correct — single line
function handler(id: Str) -> Response { ... }
```
```

Also add a comment in `dsl/desugar.awk` near line 1:

```awk
# NOTE: regex-based preprocessor — function signatures must fit on one line.
# Multi-line signatures are silently ignored (not an error).
```

- [ ] **Step 3: Commit**

```bash
git add README.md dsl/desugar.awk
git commit -m "docs: document regex-parser limitation (single-line function defs only)"
```

---

## Task 6: Full regression

- [ ] **Step 1: Run all tests**

```bash
make test 2>&1 | tail -10
```

Expected: 0 failed.
