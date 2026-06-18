# DSL Phase 3: Return Type Inference + Exhaustiveness Checking

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Infer return types of unannotated user functions from their `return` statements, and extend `when...of...end` exhaustiveness checking to use those inferred types.

**Architecture:** Pass 1 in `desugar.awk` is split into 1a (alias/error collection) then 1b (return-type inference). A side-effect-free `_ds_infer_type_safe` avoids errors during pass 1. `desugar_match.awk` uses `_ds_infer_type` on the match expression to check union exhaustiveness even without explicit annotations.

**Tech Stack:** gawk 5.3.1, existing DSL test harness (`make test-dsl`).

**Prerequisite:** Phase 1 complete (alias cycle detection must run before type normalization in inference).

---

## File Map

- Modify: `dsl/desugar.awk` — split BEGIN pass 1 into 1a+1b, add brace-aware body scan, `_DS_pass1_lineno`
- Modify: `dsl/desugar_let.awk` — add `_ds_infer_type_safe` (side-effect-free variant)
- Modify: `dsl/desugar_match.awk` — use `_ds_infer_type` on match expr for union exhaustiveness
- Create: `tests/unit/dsl/func_return_infer_str/input.awk`
- Create: `tests/unit/dsl/func_return_infer_str/expected.awk`
- Create: `tests/unit/dsl/func_return_infer_mismatch/input.awk`
- Create: `tests/unit/dsl/func_return_infer_mismatch/expected_stderr`
- Create: `tests/unit/dsl/when_inferred_result_exhaustive_error/input.awk`
- Create: `tests/unit/dsl/when_inferred_result_exhaustive_error/expected_stderr`

---

## Task 1: Return type inference test (RED)

**Files:**
- Create: `tests/unit/dsl/func_return_infer_str/input.awk`
- Create: `tests/unit/dsl/func_return_infer_str/expected.awk`
- Create: `tests/unit/dsl/func_return_infer_mismatch/input.awk`
- Create: `tests/unit/dsl/func_return_infer_mismatch/expected_stderr`

- [ ] **Step 1: Write inference test — returned literal propagates**

`tests/unit/dsl/func_return_infer_str/input.awk`:
```awk
function greet() {
  return "hello"
}

function handler() -> Response {
  let msg: Str = greet()
  return ctx.res.text(msg)
}
```

`tests/unit/dsl/func_return_infer_str/expected.awk`:
```awk
function greet() {
  return "hello"
}

function handler(    msg) {
  msg = greet()
  return ctx::dispatch("res.text", msg)
}
```

(This test should PASS already since it's about desugar output, not type errors. The type checking is the interesting part — `let msg: Str = greet()` should not error because `greet` is inferred as `Str`.)

- [ ] **Step 2: Write type-mismatch test**

`tests/unit/dsl/func_return_infer_mismatch/input.awk`:
```awk
function get_count() {
  return 42
}

function handler() -> Response {
  let msg: Str = get_count()
  return ctx.res.text(msg)
}
```

`tests/unit/dsl/func_return_infer_mismatch/expected_stderr`:
```
expects Str, got Int
```

- [ ] **Step 3: Run and verify current state**

```bash
make test-dsl 2>&1 | grep -E "func_return_infer"
```

Expected:
- `func_return_infer_str` — likely PASS already (desugar output is same; BUT type check may FAIL because `greet()` currently returns `Any`, allowing `let msg: Str = greet()` to pass silently — the test itself won't error)
- `func_return_infer_mismatch` — likely FAIL (current code returns `Any` for `get_count()`, no error)

Note the actual status for both tests; implement will fix `func_return_infer_mismatch`.

---

## Task 2: Add `_ds_infer_type_safe` to desugar_let.awk

**Files:**
- Modify: `dsl/desugar_let.awk`

- [ ] **Step 1: Add the safe variant**

In `dsl/desugar_let.awk`, add immediately after the `_ds_infer_type` function:

```awk
# _ds_infer_type_safe: same as _ds_infer_type but returns "" instead of calling
# _ds_error for unknown functions. Used during Pass 1 body scan where error
# output is not yet appropriate.
function _ds_infer_type_safe(expr,    m, _m, arg_type) {
    # Numeric and string literals
    if (expr ~ /^"[0-9]+"$/)  return "NumericStr"
    if (expr ~ /^".*"$/)       return "Str"
    if (expr ~ /^-?[0-9]+$/)   return "Int"
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    if (expr == "true" || expr == "false") return "Bool"
    # Known function call
    if (match(expr, /^((ctx\.)?[a-z][a-zA-Z0-9_]*(\.[a-z][a-zA-Z0-9_]*)*)\(/, m)) {
        if (m[1] in _DS_SIG_RET) return _DS_SIG_RET[m[1]]
        if (match(m[1], /([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)$/, _m)) {
            if ((_m[1] "." _m[2]) in _DS_SIG_RET) return _DS_SIG_RET[_m[1] "." _m[2]]
        }
        # Unknown function: return "" silently (safe variant)
        return ""
    }
    # Variable reference
    if (_DS_in_function && ((_DS_func_name, expr) in _DS_VAR_TYPES))
        return _DS_VAR_TYPES[_DS_func_name, expr]
    return ""
}
```

---

## Task 3: Extend Pass 1 in desugar.awk to infer return types

**Files:**
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Split Pass 1 into 1a (alias/error) and 1b (return type inference)**

In `dsl/desugar.awk`, the current `BEGIN` block has a single pass. Replace the `BEGIN` block with the following (preserving all existing logic, adding Pass 1b):

```awk
BEGIN {
  _ds_init()

  if (ARGC > 1) {
    # Pass 1a: collect user function signatures and type aliases/errors
    _pass1_fname = ""; _DS_pass1_lineno = 0
    while ((getline _pass1_line < ARGV[1]) > 0) {
      _DS_pass1_lineno++
      if (_ds_is_func_def(_pass1_line)) {
        _pass1_fname = _ds_extract_func_name(_pass1_line)
        _pass1_ret   = _ds_extract_return_type(_pass1_line)
        _DS_SIG_RET[_pass1_fname] = (_pass1_ret != "" ? _pass1_ret : "")
        # "" means "not yet known" — will be filled in Pass 1b
        if (match(_pass1_line, /\(([^)]*)\)[[:space:]]*(->.*)?[[:space:]]*\{/, _pass1_m))
          _ds_parse_func_params(_pass1_fname, _pass1_m[1])
      } else if (_pass1_fname != "" && \
          match(_pass1_line, /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/, _pass1_m)) {
        _DS_FUNC_CLASS[_pass1_fname] = _pass1_m[1]
      }
      # Collect user type aliases (type X = ...) for cycle detection
      if (match(_pass1_line, /^[[:space:]]*type[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$/, _pass1_m)) {
        _DS_TYPE_ALIAS[_pass1_m[1]] = _ds_trim(_pass1_m[2])
        delete _pass1_visiting
        _type_check_alias_cycle(_pass1_m[1], _DS_pass1_lineno, _pass1_visiting)
      }
    }
    close(ARGV[1])

    # Pass 1b: infer return types for unannotated functions from return statements
    _pass1_fname = ""; _pass1_brace_depth = 0; _DS_pass1_lineno = 0
    _pass1_infer_ret = ""; _pass1_infer_conflict = 0
    while ((getline _pass1_line < ARGV[1]) > 0) {
      _DS_pass1_lineno++
      if (_ds_is_func_def(_pass1_line)) {
        _pass1_fname = _ds_extract_func_name(_pass1_line)
        _pass1_brace_depth = 1
        _pass1_infer_ret = ""; _pass1_infer_conflict = 0
        continue
      }
      if (_pass1_fname == "") continue
      # Track brace depth (simple counting; strings masked by _ds_split_code_segs in main pass)
      _pass1_opens = gsub(/{/, "{", _pass1_line_tmp = _pass1_line)
      _pass1_closes = gsub(/}/, "}", _pass1_line_tmp)
      _pass1_brace_depth += _pass1_opens - _pass1_closes
      # Extract return expression
      if (match(_pass1_line, /^[[:space:]]*return[[:space:]]+(.+)[[:space:]]*$/, _pass1_m)) {
        _pass1_t = _ds_infer_type_safe(_ds_trim(_pass1_m[1]))
        if (_pass1_t != "") {
          if (_pass1_infer_ret == "") {
            _pass1_infer_ret = _pass1_t
          } else if (_pass1_infer_ret != _pass1_t) {
            _pass1_infer_conflict = 1
          }
        }
      }
      # End of function
      if (_pass1_brace_depth <= 0) {
        # Only set inferred type if: no annotation yet, no conflict, inferred type found
        if (_DS_SIG_RET[_pass1_fname] == "" && !_pass1_infer_conflict && _pass1_infer_ret != "") {
          _DS_SIG_RET[_pass1_fname] = _pass1_infer_ret
        } else if (_DS_SIG_RET[_pass1_fname] == "") {
          _DS_SIG_RET[_pass1_fname] = "Any"
        }
        _pass1_fname = ""; _pass1_brace_depth = 0
        _pass1_infer_ret = ""; _pass1_infer_conflict = 0
      }
    }
    close(ARGV[1])
  }
}
```

- [ ] **Step 2: Remove duplicate alias registration from main pass**

The main pass in `desugar.awk` currently also registers user aliases (around line 64). Check if it does, and if so keep it (for runtime use in the main pass) but verify it won't double-run the cycle check. If the cycle check is now in Pass 1a, the main pass call can be removed or left as a no-op (since `_DS_TYPE_ALIAS[name]` is already set).

```bash
grep -n "_DS_TYPE_ALIAS\[" dsl/desugar.awk
```

If the main pass adds to `_DS_TYPE_ALIAS`, change it to skip cycle check (already done in Pass 1a):

```awk
# main pass: alias already registered in Pass 1a; just ensure it's set
# (no cycle check needed here — already run in Pass 1a)
_DS_TYPE_ALIAS[m[1]] = _ds_trim(m[2])
```

- [ ] **Step 3: Run type inference tests**

```bash
make test-dsl 2>&1 | grep func_return_infer
```

Expected:
- `func_return_infer_str` — PASS
- `func_return_infer_mismatch` — PASS (now `get_count()` inferred as `Int`, type error fires)

- [ ] **Step 4: Full DSL regression**

```bash
make test-dsl 2>&1 | tail -3
```

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add dsl/desugar.awk dsl/desugar_let.awk \
  tests/unit/dsl/func_return_infer_str/ \
  tests/unit/dsl/func_return_infer_mismatch/
git commit -m "feat(types): infer user function return types from return statements

Pass 1 split: 1a collects aliases/error types, 1b scans function bodies.
_ds_infer_type_safe is side-effect-free for use during Pass 1.
Consistent return types across all return statements are registered in
_DS_SIG_RET. Conflicting or unknown types fall back to Any."
```

---

## Task 4: Exhaustiveness check for inferred union results (RED)

**Files:**
- Create: `tests/unit/dsl/when_inferred_result_exhaustive_error/input.awk`
- Create: `tests/unit/dsl/when_inferred_result_exhaustive_error/expected_stderr`

- [ ] **Step 1: Write the test**

`tests/unit/dsl/when_inferred_result_exhaustive_error/input.awk`:
```awk
type DbError = Error
type AuthError = Error

function fetch_user(id: Str) {
  return DbError("not found")
}

function handler() -> Response {
  when fetch_user("1") of
    ok u:
      return ctx.res.json(u)
    ng e<DbError>:
      return ctx.res.status(500)
  end
}
```

(Note: `fetch_user` has no return type annotation but its return type is inferred as `Result<Any, DbError>` from the single `return DbError("not found")` expression. The `ng e<AuthError>` arm is missing — but currently no exhaustiveness error fires without annotation.)

`tests/unit/dsl/when_inferred_result_exhaustive_error/expected_stderr`:
```
when...of missing arm
```

- [ ] **Step 2: Run and verify FAIL**

```bash
make test-dsl 2>&1 | grep when_inferred_result_exhaustive_error
```

Expected: FAIL (no error currently because `fetch_user` has no annotation).

---

## Task 5: Extend exhaustiveness check in desugar_match.awk

**Files:**
- Modify: `dsl/desugar_match.awk`

- [ ] **Step 1: Find where exhaustiveness is checked**

```bash
grep -n "exhaustive\|missing arm\|type_t" dsl/desugar_match.awk | head -20
```

Expected: shows the block around line 155–200 where `type_t` is set from annotation and union arms are checked.

- [ ] **Step 2: Add inference fallback for type_t**

Find the code that sets `type_t` from the match expression's annotation. It currently checks only annotated types. Add a fallback using `_ds_infer_type`:

```awk
    # Try annotation-based type first
    type_t = _DS_func_ret_type  # existing logic — keep as-is
    if (type_t == "" || type_t == "Any") {
        # Fall back to inference from match expression
        type_t = _ds_infer_type(_DS_match_expr)
    }
```

Note: the exact variable names and logic depend on the current code. Check lines 155–165 of `dsl/desugar_match.awk` before editing:

```bash
sed -n '150,175p' dsl/desugar_match.awk
```

Read the output carefully, then make the minimal change to add the inference fallback where `type_t` is determined.

- [ ] **Step 3: Run exhaustiveness test**

```bash
make test-dsl 2>&1 | grep when_inferred_result_exhaustive_error
```

Expected: PASS.

- [ ] **Step 4: Verify existing exhaustiveness tests unchanged**

```bash
make test-dsl 2>&1 | grep when_typed_ng
```

Expected: all `when_typed_ng_*` tests PASS.

- [ ] **Step 5: Full regression**

```bash
make test-dsl 2>&1 | tail -3
```

Expected: 0 failed.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_match.awk \
  tests/unit/dsl/when_inferred_result_exhaustive_error/
git commit -m "feat(match): exhaustiveness checking uses inferred types

when...of now checks union exhaustiveness even without explicit return type
annotation, by falling back to _ds_infer_type on the match expression.
Depends on Phase 3 return type inference."
```

---

## Task 6: Full regression

- [ ] **Step 1: Run all tests**

```bash
make test 2>&1 | tail -10
```

Expected: 0 failed.
