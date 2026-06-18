# DSL Phase 2: html.fragment Variadic + Pipe LHS

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `safe.html.fragment` to accept more than 3 arguments, and allow complex expressions on the left side of `|>`.

**Architecture:** Two independent changes. `html.fragment` variadic: sentinel `-1` in `_DS_SIG_ARITY`, special-cased in `_ds_typecheck_call`, expanded in `desugar_strings.awk`. Pipe LHS: replace identifier-only backward scan with a balanced-parenthesis scanner.

**Tech Stack:** gawk 5.3.1, existing DSL test harness (`make test-dsl`).

**Prerequisite:** Phase 1 complete (no hard dependency, but run in order).

---

## File Map

- Modify: `dsl/sig.awk` — change `safe.html.fragment` arity to `-1`
- Modify: `dsl/typecheck.awk` — handle arity `-1` and per-arg `HtmlPart` check for `html.fragment`
- Modify: `dsl/desugar_strings.awk` — make `html.fragment` expansion loop-based
- Create: `tests/unit/dsl/safe_fragment_4args/input.awk`
- Create: `tests/unit/dsl/safe_fragment_4args/expected.awk`
- Create: `tests/unit/dsl/safe_fragment_wrong_type/input.awk`
- Create: `tests/unit/dsl/safe_fragment_wrong_type/expected_stderr`
- Modify: `dsl/desugar_pipe.awk` — replace `_ds_pipe_left_start` with balanced scanner
- Create: `tests/unit/dsl/pipe_complex_lhs/input.awk`
- Create: `tests/unit/dsl/pipe_complex_lhs/expected.awk`

---

## Task 1: html.fragment 4-arg test (RED)

**Files:**
- Create: `tests/unit/dsl/safe_fragment_4args/input.awk`
- Create: `tests/unit/dsl/safe_fragment_4args/expected.awk`

- [ ] **Step 1: Write the failing test**

`tests/unit/dsl/safe_fragment_4args/input.awk`:
```awk
function handler() -> Response {
  let a: HtmlEscapedStr = safe.html.escape("<b>")
  let b: HtmlEscapedStr = safe.html.escape("&")
  let c: HtmlEscapedStr = safe.html.escape("<i>")
  let d: HtmlEscapedStr = safe.html.escape("ok")
  return ctx.res.html(safe.html.fragment(a, b, c, d))
}
```

`tests/unit/dsl/safe_fragment_4args/expected.awk`:
```awk
function handler(    a, b, c, d) {
  a = safe::dispatch("html.escape", "<b>")
  b = safe::dispatch("html.escape", "&")
  c = safe::dispatch("html.escape", "<i>")
  d = safe::dispatch("html.escape", "ok")
  return ctx::dispatch("res.html", safe::dispatch("html.fragment", a, b, c, d))
}
```

- [ ] **Step 2: Run and verify FAIL**

```bash
make test-dsl 2>&1 | grep safe_fragment_4args
```

Expected: FAIL (current code errors on 4-arg `html.fragment`).

---

## Task 2: html.fragment wrong-type test (RED)

**Files:**
- Create: `tests/unit/dsl/safe_fragment_wrong_type/input.awk`
- Create: `tests/unit/dsl/safe_fragment_wrong_type/expected_stderr`

- [ ] **Step 1: Write the failing test**

`tests/unit/dsl/safe_fragment_wrong_type/input.awk`:
```awk
function handler() -> Response {
  let raw: Str = "untrusted"
  return ctx.res.html(safe.html.fragment(raw))
}
```

`tests/unit/dsl/safe_fragment_wrong_type/expected_stderr`:
```
safe.html.fragment argument 1 expects HtmlPart
```

- [ ] **Step 2: Run and verify FAIL (wrong error or no error)**

```bash
make test-dsl 2>&1 | grep safe_fragment_wrong_type
```

---

## Task 3: Make html.fragment variadic in sig.awk

**Files:**
- Modify: `dsl/sig.awk`

- [ ] **Step 1: Change arity sentinel**

In `dsl/sig.awk`, find the `safe.html.fragment` block (around line 107). Change:

```awk
    _DS_SIG_RET["safe.html.fragment"]       = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.fragment"]     = 3
    _DS_SIG_ARG["safe.html.fragment", 1]    = "HtmlPart"
    _DS_SIG_ARG["safe.html.fragment", 2]    = "HtmlPart"
    _DS_SIG_ARG["safe.html.fragment", 3]    = "HtmlPart"
    _DS_FUNC_CLASS["safe.html.fragment"]    = "builder"
    _DS_SIG_TRUSTED["safe.html.fragment"]   = 1
```

To:

```awk
    _DS_SIG_RET["safe.html.fragment"]       = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.fragment"]     = -1
    _DS_SIG_ARG["safe.html.fragment", 1]    = "HtmlPart"
    _DS_FUNC_CLASS["safe.html.fragment"]    = "builder"
    _DS_SIG_TRUSTED["safe.html.fragment"]   = 1
```

(Remove the per-index `_DS_SIG_ARG` for indices 2 and 3; keep index 1 as the template type for all args.)

---

## Task 4: Update typecheck.awk for variadic arity

**Files:**
- Modify: `dsl/typecheck.awk`

- [ ] **Step 1: Handle arity -1 in `_ds_typecheck_call`**

In `dsl/typecheck.awk`, find `_ds_typecheck_call`. The arity check looks like:

```awk
    n = _ds_count_args(args_str)
    if (n != _DS_SIG_ARITY[path]) {
        _ds_error(lineno, path " expects " _DS_SIG_ARITY[path] " argument(s), got " n, "")
        return
    }
```

Change to:

```awk
    n = _ds_count_args(args_str)
    if (_DS_SIG_ARITY[path] != -1 && n != _DS_SIG_ARITY[path]) {
        _ds_error(lineno, path " expects " _DS_SIG_ARITY[path] " argument(s), got " n, "")
        return
    }
```

- [ ] **Step 2: Per-arg type check for variadic html.fragment**

In the same function, the per-arg loop uses `_DS_SIG_ARG[path, i]`. For variadic functions where only index 1 is set as the template type, extend the loop:

```awk
    _ds_split_args(args_str, split_args)
    for (i = 1; i <= n; i++) {
        if ((path, i) in _DS_SIG_ARG) {
            expected = _DS_SIG_ARG[path, i]
        } else if ((path, 1) in _DS_SIG_ARG && _DS_SIG_ARITY[path] == -1) {
            expected = _DS_SIG_ARG[path, 1]
        } else {
            continue
        }
        actual = _ds_infer_type(split_args[i])
        # safe.html.fragment: literal string args are trusted static HTML chunks
        if (path == "safe.html.fragment" && actual == "Str" && \
            split_args[i] ~ /^"[^"]*"$/) continue
        if (actual == "" || type::accepts(expected, actual)) continue
        _ds_error(lineno, path " argument " i " expects " expected ", got " actual, \
            "sanitize or unwrap the value to get " expected)
    }
```

- [ ] **Step 3: Run DSL tests — both new tests should PASS**

```bash
make test-dsl 2>&1 | grep -E "safe_fragment"
```

Expected: `safe_fragment_4args` PASS, `safe_fragment_wrong_type` PASS.

- [ ] **Step 4: Full regression**

```bash
make test-dsl 2>&1 | tail -3
```

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add dsl/sig.awk dsl/typecheck.awk \
  tests/unit/dsl/safe_fragment_4args/ \
  tests/unit/dsl/safe_fragment_wrong_type/
git commit -m "feat(safe): make html.fragment variadic (unlimited HtmlPart args)

_DS_SIG_ARITY = -1 as variadic sentinel. Per-arg type check falls back
to index-1 template type for variadic functions. HtmlPart safety preserved."
```

---

## Task 5: Pipe complex LHS test (RED)

**Files:**
- Create: `tests/unit/dsl/pipe_complex_lhs/input.awk`
- Create: `tests/unit/dsl/pipe_complex_lhs/expected.awk`

- [ ] **Step 1: Write the failing test**

`tests/unit/dsl/pipe_complex_lhs/input.awk`:
```awk
function handler() -> Response {
  return get_user(ctx.req.param("id")) |> validate_user()
}
```

`tests/unit/dsl/pipe_complex_lhs/expected.awk`:
```awk
function handler(    __pipe_tmp_1, _ds_p_1) {
  __pipe_tmp_1 = get_user(ctx::dispatch("req.param", "id"))
  _ds_p_1 = validate_user(__pipe_tmp_1)
  return _ds_p_1
}
```

- [ ] **Step 2: Run and verify FAIL**

```bash
make test-dsl 2>&1 | grep pipe_complex_lhs
```

Expected: FAIL (current LHS scanner cannot handle function call on LHS).

---

## Task 6: Implement balanced-paren LHS scanner in desugar_pipe.awk

**Files:**
- Modify: `dsl/desugar_pipe.awk`

- [ ] **Step 1: Add balanced-expression left-scan function**

In `dsl/desugar_pipe.awk`, replace `_ds_pipe_left_start` with:

```awk
# _ds_pipe_left_start_balanced: scan left from pipe_pos to find the start of the LHS expression.
# Handles: identifiers, function calls f(...), nested calls f(g(...)), array subscripts a[i].
# Returns the 1-based start index of the LHS expression in masked.
function _ds_pipe_left_start_balanced(masked, pipe_pos,    i, c, depth) {
    i = pipe_pos - 1
    # Skip trailing spaces
    while (i >= 1 && substr(masked, i, 1) == " ") i--
    # If we land on ) or ], scan backwards for matching opener
    depth = 0
    while (i >= 1) {
        c = substr(masked, i, 1)
        if (c == ")" || c == "]") {
            depth++
            i--
        } else if ((c == "(" || c == "[") && depth > 0) {
            depth--
            i--
            if (depth == 0) {
                # Now scan the identifier/name before the opener
                while (i >= 1 && substr(masked, i, 1) ~ /[a-zA-Z0-9_.]/) i--
                i++
                break
            }
        } else if (depth == 0 && c ~ /[a-zA-Z0-9_.]/) {
            # Simple identifier — scan to its start
            while (i > 1 && substr(masked, i-1, 1) ~ /[a-zA-Z0-9_.]/) i--
            break
        } else {
            i++
            break
        }
    }
    return (i < 1) ? 1 : i
}
```

- [ ] **Step 2: Replace call to old function and add auto-tmp logic**

In `_ds_pipe_transform`, find the line that calls `_ds_pipe_left_start(masked, pipe_pos)` and the lines that use `left_op`. Replace:

```awk
        left_start = _ds_pipe_left_start(masked, pipe_pos)
        left_op    = _ds_trim(substr(line, left_start, pipe_pos - left_start))
```

With:

```awk
        left_start = _ds_pipe_left_start_balanced(masked, pipe_pos)
        left_op    = _ds_trim(substr(line, left_start, pipe_pos - left_start))
        # If LHS is a complex expression (not a plain identifier), auto-assign to tmp
        if (left_op !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
            _DS_pipe_tmp_cnt++
            tmpvar   = "__pipe_tmp_" _DS_pipe_tmp_cnt
            pre_buf[++pb] = indent tmpvar " = " left_op
            left_op = tmpvar
        }
```

Also add `_DS_pipe_tmp_cnt` initialization to `_ds_init()` in `dsl/desugar_state.awk`:

```awk
    _DS_pipe_tmp_cnt = 0
```

- [ ] **Step 3: Run pipe_complex_lhs test**

```bash
make test-dsl 2>&1 | grep pipe_complex_lhs
```

Expected: PASS.

- [ ] **Step 4: Verify existing pipe tests still pass**

```bash
make test-dsl 2>&1 | grep pipe
```

Expected: all pipe tests PASS.

- [ ] **Step 5: Full regression**

```bash
make test-dsl 2>&1 | tail -3
```

Expected: 0 failed.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_pipe.awk dsl/desugar_state.awk \
  tests/unit/dsl/pipe_complex_lhs/
git commit -m "feat(pipe): allow complex expressions on |> LHS

Replace identifier-only backward scan with balanced-paren scanner.
Complex LHS auto-assigned to __pipe_tmp_N. Plain identifiers unchanged."
```

---

## Task 7: Full regression

- [ ] **Step 1: Run all tests**

```bash
make test 2>&1 | tail -10
```

Expected: 0 failed.
