# Typed Dataflow Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pipe (`|>`), match expression, Untrusted\<T\> external-input tracking, Safe\<T\> sink safety, and function classification — all enforced at desugar time with zero runtime overhead.

**Architecture:** New AWK files (`desugar_pipe.awk`, `desugar_match.awk`, `type_dataflow.awk`) added to the existing `dsl/` pipeline. Processing order: `pipe_transform → dot_transform → nullcoalesce → let_transform`. Type info lives in global `_DS_` arrays; gawk output contains no type annotations or `classify:` keywords.

**Tech Stack:** GNU AWK 5.0+, existing `dsl/desugar.awk` pipeline, `dsl/sig.awk` sig registry, `dsl/typecheck.awk` checker, `dsl/type.awk` type utilities.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `dsl/desugar_pipe.awk` | Create | `\|>` transform: left-op extraction, temp var gen |
| `dsl/desugar_match.awk` | Create | `match…of…end` state machine, emit if/else |
| `dsl/type_dataflow.awk` | Create | Untrusted/Safe helpers, `_DS_FUNC_CLASS[]` |
| `dsl/desugar.awk` | Modify | `@include` new files, integrate pipe/match, pass-1 classify scan |
| `dsl/desugar_state.awk` | Modify | Add pipe/match counters, match state, classify reset |
| `dsl/sig.awk` | Modify | Phase 3: ctx.req.* → `Result<Untrusted<T>>`, Phase 4: ctx.res.* → `Safe<T>` |
| `dsl/typecheck.awk` | Modify | Phase 3: sealed-pipe check; Phase 4: sink safety |
| `app.awk` | Modify | Phase 3+: update handlers to use `?=` + pipe for req params |

Test fixtures live under `tests/unit/dsl/<name>/`. Each has `input.awk` + `expected.awk` (success) or `expected_stderr` (error). Run: `make test-dsl` (or `bash tests/unit/dsl/run.sh`).

---

## Phase 1: Pipe Operator (`|>`)

### Task 1: `dsl/desugar_pipe.awk`

**Files:**
- Create: `dsl/desugar_pipe.awk`
- Create: `tests/unit/dsl/pipe_basic/input.awk`
- Create: `tests/unit/dsl/pipe_basic/expected.awk`
- Create: `tests/unit/dsl/pipe_chain/input.awk`
- Create: `tests/unit/dsl/pipe_chain/expected.awk`
- Create: `tests/unit/dsl/pipe_with_args/input.awk`
- Create: `tests/unit/dsl/pipe_with_args/expected.awk`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/pipe_basic/input.awk`:
```awk
function handler() {
  let x = a |> trim()
}
```

`tests/unit/dsl/pipe_basic/expected.awk`:
```awk
function handler(    _ds_p_1, x) {
  _ds_p_1 = trim(a)
  x = _ds_p_1
}
```

`tests/unit/dsl/pipe_chain/input.awk`:
```awk
function handler() {
  let x = a |> trim() |> upper()
}
```

`tests/unit/dsl/pipe_chain/expected.awk`:
```awk
function handler(    _ds_p_1, _ds_p_2, x) {
  _ds_p_1 = trim(a)
  _ds_p_2 = upper(_ds_p_1)
  x = _ds_p_2
}
```

`tests/unit/dsl/pipe_with_args/input.awk`:
```awk
function handler() {
  let x = a |> pad(10, " ")
}
```

`tests/unit/dsl/pipe_with_args/expected.awk`:
```awk
function handler(    _ds_p_1, x) {
  _ds_p_1 = pad(a, 10, " ")
  x = _ds_p_1
}
```

- [ ] **Step 2: Run tests (expect FAIL)**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): pipe"
```

Expected: `FAIL: pipe_basic`, `FAIL: pipe_chain`, `FAIL: pipe_with_args`

- [ ] **Step 3: Implement `dsl/desugar_pipe.awk`**

```awk
# SPDX-License-Identifier: MIT
# dsl/desugar_pipe.awk -- pipe operator (|>) transform
#
# expr |> f()        → _ds_p_N = f(expr);     line gets _ds_p_N
# expr |> f(a, b)    → _ds_p_N = f(expr,a,b); line gets _ds_p_N
# Chains are processed left-to-right iteratively.

# Find the position of the closing ) matching the ( at open_pos in s
function _ds_pipe_find_close(s, open_pos,    i, c, depth) {
    depth = 1; i = open_pos + 1
    while (i <= length(s) && depth > 0) {
        c = substr(s, i, 1)
        if      (c == "(") depth++
        else if (c == ")") depth--
        i++
    }
    return i - 1
}

# Find where the left operand starts (scan left from pipe_pos past one token)
function _ds_pipe_left_start(masked, pipe_pos,    i, c) {
    i = pipe_pos - 1
    while (i >= 1 && substr(masked, i, 1) == " ") i--
    # i now at last char of left token; scan back through identifier/digit chars
    while (i > 1 && substr(masked, i - 1, 1) ~ /[a-zA-Z0-9_]/) i--
    return i
}

# Main transform: find each |> and rewrite iteratively
function _ds_pipe_transform(line, pre_buf,    segs, n, masked, pipe_pos, m,
    left_start, left_op, rhs, fname, open_pos, close_pos, fargs, tmpvar, pb) {
    delete pre_buf
    pb = 0

    n = _ds_split_code_segs(line, segs)
    masked = _ds_nc_mask(segs, n)

    # Find indentation once (stable across iterations)
    _ds_pipe_indent = ""
    if (match(line, /^[[:space:]]*/)) _ds_pipe_indent = substr(line, 1, RLENGTH)

    while (match(masked, /\|>/)) {
        pipe_pos = RSTART  # 1-indexed position of |

        # --- left operand ---
        left_start = _ds_pipe_left_start(masked, pipe_pos)
        left_op    = _ds_trim(substr(line, left_start, pipe_pos - left_start))

        # --- right operand: f(args) ---
        rhs = substr(line, pipe_pos + 2)
        if (!match(rhs, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(/, m))
            return line   # malformed, pass through unchanged

        fname    = m[1]
        open_pos = index(rhs, "(")                        # pos of ( in rhs
        close_pos = _ds_pipe_find_close(rhs, open_pos)   # pos of ) in rhs
        fargs    = _ds_trim(substr(rhs, open_pos + 1, close_pos - open_pos - 1))

        # absolute end of consumed region in line
        rhs_abs_end = (pipe_pos + 2 - 1) + close_pos     # pipe_pos+1 = start of rhs

        # --- temp var ---
        _DS_pipe_count++
        tmpvar = "_ds_p_" _DS_pipe_count
        if (_DS_in_function) _DS_let_locals[++_DS_let_count] = tmpvar

        # --- emit pre-line ---
        if (fargs == "")
            pre_buf[++pb] = _ds_pipe_indent tmpvar " = " fname "(" left_op ")"
        else
            pre_buf[++pb] = _ds_pipe_indent tmpvar " = " fname "(" left_op ", " fargs ")"

        # --- replace "left_op |> fname(fargs)" with tmpvar in line ---
        line = substr(line, 1, left_start - 1) tmpvar substr(line, rhs_abs_end + 1)

        # re-mask for next iteration
        n      = _ds_split_code_segs(line, segs)
        masked = _ds_nc_mask(segs, n)
    }
    return line
}
```

- [ ] **Step 4: Add `_DS_pipe_count` to `dsl/desugar_state.awk`**

```awk
function _ds_init() {
  # ... existing fields ...
  _DS_pipe_count = 0
  # ...
}
```

- [ ] **Step 5: Run tests (expect PASS)**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): pipe"
```

Expected: `PASS: pipe_basic`, `PASS: pipe_chain`, `PASS: pipe_with_args`

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_pipe.awk dsl/desugar_state.awk tests/unit/dsl/pipe_*/
git commit -m "feat(dsl): implement pipe operator |> transform"
```

---

### Task 2: Integrate pipe into `desugar.awk`

**Files:**
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Add `@include` and update `_ds_process_line`**

In `dsl/desugar.awk`, add after existing includes:

```awk
@include "dsl/desugar_pipe.awk"
```

Update `_ds_process_line` to apply pipe transform first. Change the function signature to include `pipe_pre` and add pipe step:

```awk
function _ds_process_line(line, lineno,    transformed, pipe_pre, nc_pre, nc_result, p, dot_transformed, pipe_result) {
  _DS_current_lineno = lineno
  if (!_DS_in_function) {
    if (line ~ /^[[:space:]]*let[[:space:]]/) {
      print "dsl error: " _DS_src_file ":" lineno \
        ": 'let' outside function body" > "/dev/stderr"
      _DS_had_error = 1
      exit 1
    }
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_name    = _ds_extract_func_name(line)
      _DS_func_ret_type = _ds_extract_return_type(line)
      _DS_func_sig     = _ds_strip_func_annotations(line)
      _DS_brace_depth  = _ds_net_braces(line)
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
      delete _DS_let_type_map
      return
    }
    pipe_result = _ds_pipe_transform(line, pipe_pre)
    for (p = 1; p in pipe_pre; p++) print pipe_pre[p]
    nc_result = _ds_nc_transform(_ds_dot_transform(pipe_result), nc_pre)
    for (p = 1; p in nc_pre; p++) print nc_pre[p]
    print nc_result
    return
  }

  # Inside function body
  _DS_brace_depth += _ds_net_braces(line)

  if (_DS_brace_depth <= 0) {
    _DS_in_function = 0
    print _ds_rewrite_sig(_DS_func_sig)
    for (i = 1; i <= _DS_body_count; i++) print _DS_body_buf[i]
    print _ds_dot_transform(line)
    return
  }

  pipe_result = _ds_pipe_transform(line, pipe_pre)
  for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = pipe_pre[p]

  dot_transformed = _ds_dot_transform(pipe_result)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)
  _ds_check_return(dot_transformed, lineno)
  transformed = _ds_let_transform(nc_result, lineno, line)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}
```

- [ ] **Step 2: Run full DSL test suite**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all existing tests still pass + pipe tests pass.

- [ ] **Step 3: Commit**

```bash
git add dsl/desugar.awk
git commit -m "feat(dsl): integrate pipe transform into desugar pipeline"
```

---

## Phase 2: Match Expression

### Task 3: `dsl/desugar_match.awk`

**Files:**
- Create: `dsl/desugar_match.awk`
- Create: `tests/unit/dsl/match_result_basic/input.awk`
- Create: `tests/unit/dsl/match_result_basic/expected.awk`
- Create: `tests/unit/dsl/match_result_default/input.awk`
- Create: `tests/unit/dsl/match_result_default/expected.awk`
- Create: `tests/unit/dsl/match_option_basic/input.awk`
- Create: `tests/unit/dsl/match_option_basic/expected.awk`
- Create: `tests/unit/dsl/match_missing_branch/input.awk`
- Create: `tests/unit/dsl/match_missing_branch/expected_stderr`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/match_result_basic/input.awk`:
```awk
function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng err:
      return ctx.res.status(500)
  end
}
```

`tests/unit/dsl/match_result_basic/expected.awk`:
```awk
function handler(    _ds_mc_1, body, err) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
```

`tests/unit/dsl/match_result_default/input.awk`:
```awk
function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    default:
      return ctx.res.status(500)
  end
}
```

`tests/unit/dsl/match_result_default/expected.awk`:
```awk
function handler(    _ds_mc_1, body) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
```

`tests/unit/dsl/match_option_basic/input.awk`:
```awk
function handler() {
  match find_item(id) of
    some val:
      return ctx.res.json(val)
    none:
      return ctx.res.status(404)
  end
}
```

`tests/unit/dsl/match_option_basic/expected.awk`:
```awk
function handler(    _ds_mc_1, val) {
  _ds_mc_1 = find_item(id)
  if (option_some(_ds_mc_1)) {
    val = option_val(_ds_mc_1)
    return ctx::dispatch("res.json", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

`tests/unit/dsl/match_missing_branch/input.awk`:
```awk
function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.json(body)
  end
}
```

`tests/unit/dsl/match_missing_branch/expected_stderr`:
```
match on Result missing ng or default branch
```

- [ ] **Step 2: Run tests (expect FAIL)**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): match"
```

Expected: all match tests FAIL

- [ ] **Step 3: Implement `dsl/desugar_match.awk`**

```awk
# SPDX-License-Identifier: MIT
# dsl/desugar_match.awk -- match...of...end expression transform
#
# Syntax:
#   match EXPR of
#     ok VAR:       -- Result ok branch (binds VAR to result_val)
#     ng VAR:       -- Result error branch (binds VAR to result_err)
#     some VAR:     -- Option some branch (binds VAR to option_val)
#     none:         -- Option none branch (no binding)
#     default:      -- catch-all (no binding; replaces ng/none)
#   end
#
# Desugars to: tmpvar = EXPR; if (...) { ... } else { ... }

# Returns 1 if the current line starts a match block, 0 otherwise
function _ds_match_starts(line, m) {
    return match(line, /^([[:space:]]*)match[[:space:]]+(.+)[[:space:]]+of[[:space:]]*$/, m)
}

# Process a line while inside a match block.
# Returns "" always (lines are buffered, not emitted here).
# Emits desugared output into _DS_body_buf at end-of-block.
function _ds_match_collect(line, lineno,    m) {
    # Branch headers
    if (match(line, /^[[:space:]]*ok[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ok_var  = m[1]
        _DS_match_branch  = "ok"
        return ""
    }
    if (match(line, /^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ng_var  = m[1]
        _DS_match_branch  = "ng"
        _DS_match_has_ng  = 1
        return ""
    }
    if (match(line, /^[[:space:]]*some[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ok_var  = m[1]
        _DS_match_branch  = "some"
        return ""
    }
    if (line ~ /^[[:space:]]*none:[[:space:]]*$/) {
        _DS_match_branch  = "none"
        _DS_match_has_ng  = 1
        return ""
    }
    if (line ~ /^[[:space:]]*default:[[:space:]]*$/) {
        _DS_match_branch  = "default"
        _DS_match_has_ng  = 1
        return ""
    }
    # End of block
    if (line ~ /^[[:space:]]*end[[:space:]]*$/) {
        _DS_in_match = 0
        _ds_match_emit(lineno)
        return ""
    }
    # Body line — buffer under current branch
    if (_DS_match_branch == "ok" || _DS_match_branch == "some")
        _DS_match_ok_body[++_DS_match_ok_count] = line
    else
        _DS_match_ng_body[++_DS_match_ng_count] = line
    return ""
}

# Emit the desugared if/else into _DS_body_buf.
# Body lines are processed through the full pipeline.
function _ds_match_emit(lineno,    tmpvar, type_t, check_fn, val_fn, err_fn, i,
    pipe_pre, nc_pre, p, dot_r, nc_r, xf) {
    # Exhaustiveness check
    if (!_DS_match_has_ng) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": match on Result missing ng or default branch" > "/dev/stderr"
        _DS_had_error = 1
        return
    }

    # Temp var
    _DS_mc_count++
    tmpvar = "_ds_mc_" _DS_mc_count
    _DS_let_locals[++_DS_let_count] = tmpvar
    if (_DS_match_ok_var != "") _DS_let_locals[++_DS_let_count] = _DS_match_ok_var
    if (_DS_match_ng_var != "") _DS_let_locals[++_DS_let_count] = _DS_match_ng_var

    # Determine Result vs Option from match expression type
    type_t = _ds_infer_type(_DS_match_expr)
    if (type_t ~ /^Option</) {
        check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
    } else {
        check_fn = "result_ok";   val_fn = "result_val"; err_fn = "result_err"
    }

    # tmpvar = expr (dot-transformed)
    _DS_body_buf[++_DS_body_count] = _DS_match_indent tmpvar " = " _ds_dot_transform(_DS_match_expr)

    # if branch
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "if (" check_fn "(" tmpvar ")) {"
    if (_DS_match_ok_var != "")
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " _DS_match_ok_var " = " val_fn "(" tmpvar ")"
    for (i = 1; i <= _DS_match_ok_count; i++)
        _ds_match_process_body(_DS_match_ok_body[i], lineno)

    # else branch
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "} else {"
    if (_DS_match_ng_var != "" && err_fn != "")
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " _DS_match_ng_var " = " err_fn "(" tmpvar ")"
    for (i = 1; i <= _DS_match_ng_count; i++)
        _ds_match_process_body(_DS_match_ng_body[i], lineno)

    _DS_body_buf[++_DS_body_count] = _DS_match_indent "}"
}

# Run a collected body line through the full desugar pipeline.
# Pushes results directly into _DS_body_buf.
function _ds_match_process_body(line, lineno,    pipe_pre, nc_pre, p, dot_r, nc_r, xf) {
    pipe_r = _ds_pipe_transform(line, pipe_pre)
    for (p = 1; p in pipe_pre; p++) _DS_body_buf[++_DS_body_count] = pipe_pre[p]
    dot_r = _ds_dot_transform(pipe_r)
    nc_r  = _ds_nc_transform(dot_r, nc_pre)
    for (p = 1; p in nc_pre; p++) _DS_body_buf[++_DS_body_count] = nc_pre[p]
    _ds_typecheck_plain_call(nc_r)
    _ds_check_return(dot_r, lineno)
    xf = _ds_let_transform(nc_r, lineno, line)
    if (xf != "") _DS_body_buf[++_DS_body_count] = xf
}
```

- [ ] **Step 4: Add match state to `dsl/desugar_state.awk`**

```awk
function _ds_init() {
  # ... existing ...
  _DS_pipe_count   = 0
  _DS_mc_count     = 0
  _DS_in_match     = 0
  _DS_match_expr   = ""
  _DS_match_indent = ""
  _DS_match_ok_var = ""
  _DS_match_ng_var = ""
  _DS_match_branch = ""
  _DS_match_has_ng = 0
  _DS_match_ok_count = 0
  _DS_match_ng_count = 0
  delete _DS_match_ok_body
  delete _DS_match_ng_body
  # ... existing ...
}
```

- [ ] **Step 5: Run tests (expect PASS)**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): match"
```

Expected: all match tests PASS

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_match.awk dsl/desugar_state.awk tests/unit/dsl/match_*/
git commit -m "feat(dsl): implement match...of...end expression"
```

---

### Task 4: Integrate match into `desugar.awk`

**Files:**
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Add `@include` and intercept match lines**

Add to `dsl/desugar.awk`:

```awk
@include "dsl/desugar_match.awk"
```

At the top of the `# Inside function body` section in `_ds_process_line`, add match intercept BEFORE any transforms:

```awk
  # --- match block intercept ---
  if (_DS_in_match) {
    _ds_match_collect(line, lineno)
    return
  }
  if (_ds_match_starts(line, _match_m)) {
    _DS_in_match     = 1
    _DS_match_expr   = _ds_trim(_match_m[2])
    _DS_match_indent = _match_m[1]
    _DS_match_ok_var = ""
    _DS_match_ng_var = ""
    _DS_match_branch = ""
    _DS_match_has_ng = 0
    _DS_match_ok_count = 0
    _DS_match_ng_count = 0
    delete _DS_match_ok_body
    delete _DS_match_ng_body
    return
  }
  # --- end match intercept ---
```

Add `_match_m` to the local variable list of `_ds_process_line`.

- [ ] **Step 2: Run full test suite**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all tests pass

- [ ] **Step 3: Commit**

```bash
git add dsl/desugar.awk
git commit -m "feat(dsl): integrate match expression into desugar pipeline"
```

---

## Phase 3: `classify:` Annotation + `Untrusted<T>`

### Task 5: Classify annotation — parse and strip

**Files:**
- Modify: `dsl/desugar.awk` (Pass 1: collect classify; body: strip classify lines)
- Create: `dsl/type_dataflow.awk`
- Create: `tests/unit/dsl/classify_basic/input.awk`
- Create: `tests/unit/dsl/classify_basic/expected.awk`
- Create: `tests/unit/dsl/classify_strip/input.awk`
- Create: `tests/unit/dsl/classify_strip/expected.awk`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/classify_basic/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  return s
}
```

`tests/unit/dsl/classify_basic/expected.awk`:
```awk
function trim(s) {
  return s
}
```

(The `classify:` line is stripped; `_DS_FUNC_CLASS["trim"] = "transform"` is stored internally.)

`tests/unit/dsl/classify_strip/input.awk`:
```awk
function escape_html(s: Str) -> Str {
  classify: sanitizer
  return s
}
```

`tests/unit/dsl/classify_strip/expected.awk`:
```awk
function escape_html(s) {
  return s
}
```

- [ ] **Step 2: Run tests (expect FAIL)**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): classify"
```

- [ ] **Step 3: Create `dsl/type_dataflow.awk` with `_DS_FUNC_CLASS`**

```awk
# SPDX-License-Identifier: MIT
# dsl/type_dataflow.awk -- Untrusted<T> and Safe<T> type tracking
#
# _DS_FUNC_CLASS[name] = "transform"|"validator"|"sanitizer"|"sink"

function _ds_is_untrusted(t) { return t ~ /^Untrusted</ }
function _ds_is_safe(t)      { return t ~ /^Safe</ }

function _ds_untrusted_inner(t,    m) {
    if (match(t, /^Untrusted<(.+)>$/, m)) return m[1]
    return t
}

function _ds_safe_inner(t,    m) {
    if (match(t, /^Safe<(.+)>$/, m)) return m[1]
    return t
}

# Given function name and input type, compute output type considering classify.
# Returns "" if classification unknown.
function _ds_dataflow_ret(fname, input_type,    cls, ret) {
    cls = _DS_FUNC_CLASS[fname]
    ret = _DS_SIG_RET[fname]
    if (cls == "transform" && _ds_is_untrusted(input_type))
        return "Untrusted<" ret ">"
    return ret
}
```

- [ ] **Step 4: Add classify to Pass 1 in `dsl/desugar.awk`**

Pass 1 already reads every line. Extend the loop to also track classify annotations:

```awk
BEGIN {
  _ds_init()
  if (ARGC > 1) {
    _pass1_fname = ""
    while ((getline _pass1_line < ARGV[1]) > 0) {
      if (_ds_is_func_def(_pass1_line)) {
        _pass1_fname = _ds_extract_func_name(_pass1_line)
        _pass1_ret   = _ds_extract_return_type(_pass1_line)
        _DS_SIG_RET[_pass1_fname] = (_pass1_ret != "" ? _pass1_ret : "Any")
        if (match(_pass1_line, /\(([^)]*)\)[[:space:]]*(->.*)?[[:space:]]*\{/, _pass1_m))
          _ds_parse_func_params(_pass1_fname, _pass1_m[1])
      } else if (_pass1_fname != "" && \
          match(_pass1_line, /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/, _pass1_m)) {
        _DS_FUNC_CLASS[_pass1_fname] = _pass1_m[1]
      }
    }
    close(ARGV[1])
  }
}
```

- [ ] **Step 5: Strip `classify:` lines during body processing**

In `_ds_process_line`, inside the function body section, add BEFORE the match intercept:

```awk
  # Strip classify annotation lines
  if (match(line, /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/)) {
    # already stored in Pass 1; just suppress output
    return
  }
```

- [ ] **Step 6: Add `@include "dsl/type_dataflow.awk"` to `dsl/desugar.awk`**

- [ ] **Step 7: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): classify"
```

Expected: PASS for both classify tests

- [ ] **Step 8: Commit**

```bash
git add dsl/type_dataflow.awk dsl/desugar.awk tests/unit/dsl/classify_*/
git commit -m "feat(dsl): classify annotation — parse, store, strip"
```

---

### Task 6: Update `sig.awk` — ctx.req.* return types

**Files:**
- Modify: `dsl/sig.awk`
- Create: `tests/unit/dsl/untrusted_req_form/input.awk`
- Create: `tests/unit/dsl/untrusted_req_form/expected.awk`
- Create: `tests/unit/dsl/untrusted_unwrap_pipe/input.awk`
- Create: `tests/unit/dsl/untrusted_unwrap_pipe/expected.awk`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/untrusted_req_form/input.awk`:
```awk
function handler() {
  let raw ?= ctx.req.form("title")
}
```

`tests/unit/dsl/untrusted_req_form/expected.awk`:
```awk
function handler(    _ds_tc_1, raw) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
}
```

`tests/unit/dsl/untrusted_unwrap_pipe/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let t = raw |> trim()
}
```

`tests/unit/dsl/untrusted_unwrap_pipe/expected.awk`:
```awk
function trim(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, t) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  t = _ds_p_1
}
```

- [ ] **Step 2: Update `dsl/sig.awk` — ctx.req.* return types**

Replace all `ctx.req.*` return type entries:

```awk
    _DS_SIG_RET["ctx.req.form"]      = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_RET["ctx.req.query"]     = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_RET["ctx.req.param"]     = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_RET["ctx.req.header"]    = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_RET["ctx.req.body"]      = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_RET["ctx.req.json"]      = "Result<Untrusted<Map>, ParseError>"
```

Arity entries remain unchanged (same arg types).

- [ ] **Step 3: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): untrusted"
```

Expected: PASS for untrusted tests

- [ ] **Step 4: Run full suite to check regressions**

```bash
bash tests/unit/dsl/run.sh
```

Note: some existing fixtures using `let raw ?= ctx.req.json()` or similar should still pass since `Result<Untrusted<Map>, ParseError>` still satisfies `_ds_all_nullable`. If `unwrap_union_option_result_ok` fails, update its `expected.awk` to match the new return type in comments — but the desugared output should not change.

- [ ] **Step 5: Commit**

```bash
git add dsl/sig.awk tests/unit/dsl/untrusted_*/
git commit -m "feat(dsl): ctx.req.* return types → Result<Untrusted<T>, ParseError>"
```

---

### Task 7: Sealed-pipe check — Result/Option cannot be piped

**Files:**
- Modify: `dsl/desugar_pipe.awk`
- Create: `tests/unit/dsl/pipe_sealed_error/input.awk`
- Create: `tests/unit/dsl/pipe_sealed_error/expected_stderr`

- [ ] **Step 1: Write failing test**

`tests/unit/dsl/pipe_sealed_error/input.awk`:
```awk
function handler() {
  let x = ctx.req.form("title") |> trim()
}
```

`tests/unit/dsl/pipe_sealed_error/expected_stderr`:
```
pipe input is Result — use ?= or match to unwrap first
```

- [ ] **Step 2: Add sealed-pipe check to `dsl/desugar_pipe.awk`**

In `_ds_pipe_transform`, after computing `left_op`, infer its type and check:

```awk
        # Sealed-pipe check: Result/Option cannot be piped directly
        left_type = _ds_infer_type(left_op)
        if (_ds_is_nullable(left_type)) {
            print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                ": pipe input is " left_type " — use ?= or match to unwrap first" > "/dev/stderr"
            _DS_had_error = 1
            return line
        }
```

(Add `_ds_is_nullable` call — it's defined in `typecheck.awk`, which is already included.)

- [ ] **Step 3: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): pipe_sealed"
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add dsl/desugar_pipe.awk tests/unit/dsl/pipe_sealed_error/
git commit -m "feat(dsl): sealed-pipe check — Result/Option cannot be piped directly"
```

---

### Task 8: Untrusted propagation check

**Files:**
- Modify: `dsl/desugar_pipe.awk`
- Create: `tests/unit/dsl/untrusted_non_transform_error/input.awk`
- Create: `tests/unit/dsl/untrusted_non_transform_error/expected_stderr`
- Create: `tests/unit/dsl/untrusted_transform_ok/input.awk`
- Create: `tests/unit/dsl/untrusted_transform_ok/expected.awk`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/untrusted_non_transform_error/input.awk`:
```awk
function escape_html(s: Str) -> Str {
  classify: sanitizer
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let safe = raw |> escape_html()
}
```

`tests/unit/dsl/untrusted_non_transform_error/expected_stderr`:
```
escape_html does not accept Untrusted input — classify as transform or unwrap first
```

`tests/unit/dsl/untrusted_transform_ok/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  return s
}

function non_empty(s: Str) -> Str {
  classify: validator
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let t   = raw |> trim()
  let v  ?= t   |> non_empty()
}
```

`tests/unit/dsl/untrusted_transform_ok/expected.awk`:
```awk
function trim(s) {
  return s
}

function non_empty(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, t, _ds_tc_2, _ds_p_2, v) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  t = _ds_p_1
  _ds_tc_2 = non_empty(t)
  if (!result_ok(_ds_tc_2)) {
    return ctx::dispatch("res.status", 500)
  }
  v = result_val(_ds_tc_2)
}
```

Note: `non_empty` is `classify: validator` so it desugars to a `?=`-style unwrap only when the DSL user writes `let v ?= t |> non_empty()`. The `|>` just inserts the arg; `?=` handles the Result unwrap.

- [ ] **Step 2: Add Untrusted propagation check to `_ds_pipe_transform`**

After the sealed-pipe check, add:

```awk
        # Untrusted-propagation check: only classify:transform accepts Untrusted input
        if (_ds_is_untrusted(left_type)) {
            cls = _DS_FUNC_CLASS[fname]
            if (cls != "transform") {
                print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                    ": " fname " does not accept Untrusted input — classify as transform or unwrap first" > "/dev/stderr"
                _DS_had_error = 1
                return line
            }
        }
```

- [ ] **Step 3: Track Untrusted propagation through temp vars**

After emitting the pre-line, store the output type of the pipe call so subsequent pipes can check it. Extend `_ds_pipe_transform`:

```awk
        # Store propagated type for this temp var
        if (cls == "transform" && _ds_is_untrusted(left_type))
            _DS_VAR_TYPES[_DS_func_name, tmpvar] = "Untrusted<" _DS_SIG_RET[fname] ">"
        else
            _DS_VAR_TYPES[_DS_func_name, tmpvar] = _DS_SIG_RET[fname]
```

And update `_ds_infer_type` in `desugar_let.awk` to check `_DS_VAR_TYPES` for identifiers:

```awk
    # Known variable type
    if (expr in awk::_DS_VAR_TYPES[awk::_DS_func_name, expr]) ...
```

Actually, the existing `_DS_VAR_TYPES` is keyed by `(func_name, varname)`. Add to `_ds_infer_type`:

```awk
    # Variable with known type (from let declaration or pipe temp var)
    if ((awk::_DS_func_name SUBSEP expr) in awk::_DS_VAR_TYPES)
        return awk::_DS_VAR_TYPES[awk::_DS_func_name, expr]
```

Wait — `_ds_infer_type` is in `desugar_let.awk` which uses the default `awk` namespace. `_DS_VAR_TYPES` is in the same namespace. Add this check to `_ds_infer_type`:

```awk
function _ds_infer_type(expr,    m) {
    # ... existing checks ...
    # Variable with known type
    if ((_DS_func_name SUBSEP expr) in _DS_VAR_TYPES)
        return _DS_VAR_TYPES[_DS_func_name, expr]
    return ""
}
```

Add this check AFTER the literal checks and BEFORE the function-call checks (so variable names shadow function names).

- [ ] **Step 4: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): untrusted"
```

Expected: all untrusted tests PASS

- [ ] **Step 5: Run full suite**

```bash
bash tests/unit/dsl/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_pipe.awk dsl/desugar_let.awk tests/unit/dsl/untrusted_*/
git commit -m "feat(dsl): Untrusted<T> propagation — sealed-pipe + transform-only enforcement"
```

---

## Phase 4: Safe\<T\> + Sink Safety

### Task 9: Update `sig.awk` — ctx.res.* argument types + Safe<T> enforcement

**Files:**
- Modify: `dsl/sig.awk`
- Modify: `dsl/type_dataflow.awk`
- Create: `tests/unit/dsl/safe_sink_ok/input.awk`
- Create: `tests/unit/dsl/safe_sink_ok/expected.awk`
- Create: `tests/unit/dsl/safe_sink_error/input.awk`
- Create: `tests/unit/dsl/safe_sink_error/expected_stderr`

- [ ] **Step 1: Write failing tests**

`tests/unit/dsl/safe_sink_ok/input.awk`:
```awk
function escape_html(s: Str) -> Safe<HtmlStr> {
  classify: sanitizer
  return s
}

function non_empty(s: Str) -> NonEmptyStr {
  classify: validator
  return s
}

function handler() {
  let raw    ?= ctx.req.form("title")
  let valid  ?= raw    |> non_empty()
  let safe    = valid  |> escape_html()
  return ctx.res.html(safe)
}
```

`tests/unit/dsl/safe_sink_ok/expected.awk`:
```awk
function escape_html(s) {
  return s
}

function non_empty(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_tc_2, _ds_p_1, valid, _ds_p_2, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = non_empty(raw)
  _ds_tc_2 = _ds_p_1
  if (!result_ok(_ds_tc_2)) {
    return ctx::dispatch("res.status", 500)
  }
  valid = result_val(_ds_tc_2)
  _ds_p_2 = escape_html(valid)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
```

`tests/unit/dsl/safe_sink_error/input.awk`:
```awk
function non_empty(s: Str) -> NonEmptyStr {
  classify: validator
  return s
}

function handler() {
  let raw   ?= ctx.req.form("title")
  let valid ?= raw |> non_empty()
  return ctx.res.html(valid)
}
```

`tests/unit/dsl/safe_sink_error/expected_stderr`:
```
ctx.res.html argument 1 expects Safe<HtmlStr>, got NonEmptyStr
```

- [ ] **Step 2: Update `dsl/sig.awk` — ctx.res.* arg types**

```awk
    _DS_SIG_ARG["ctx.res.html", 1]   = "Safe<HtmlStr>"
    _DS_SIG_ARG["ctx.res.json", 1]   = "Safe<JsonStr>"
    _DS_SIG_ARG["ctx.res.text", 1]   = "Safe<Str>"
```

Leave `ctx.res.render`, `ctx.res.status`, `ctx.res.header`, `ctx.res.redirect` unchanged.

- [ ] **Step 3: Extend `type::accepts` in `dsl/type.awk` to handle Safe wildcards**

`Safe<HtmlStr>` should accept `Safe<HtmlStr>` (exact match). No structural subtyping needed — explicit classification is the enforcement mechanism.

`type::accepts` already handles exact matches (`if (expected == actual) return 1`). No change needed unless we want `Safe<*>` wildcard. For now, exact match suffices.

- [ ] **Step 4: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "^  (PASS|FAIL): safe"
```

Expected: PASS for both safe tests

- [ ] **Step 5: Run full suite**

```bash
bash tests/unit/dsl/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add dsl/sig.awk dsl/type_dataflow.awk tests/unit/dsl/safe_*/
git commit -m "feat(dsl): Safe<T> sink safety — ctx.res.html/json/text require Safe arg"
```

---

## Phase 5: Migrate `app.awk`

### Task 10: Update `app.awk` for new ctx.req.* types

**Files:**
- Modify: `app.awk`

This is a breaking-change migration. `ctx.req.*` now returns `Result<Untrusted<T>, ParseError>` so all existing uses must be updated.

- [ ] **Step 1: Identify all `ctx.req.*` uses**

```bash
grep -n 'ctx\.req\.' app.awk
```

- [ ] **Step 2: Update each handler**

For `todo_add` (uses `ctx.req.form` and `ctx.req.query`):

```awk
function todo_add() -> Response {
  let raw_title ?= ctx.req.form("title")
  let title: Str = result_val(raw_title)
  let row = []
  if (title == "") {
    let raw_q ?= ctx.req.query("title")
    title = result_val(raw_q)
  }
  if (title == "") {
    ctx.res.status(400)
    return ctx.res.text("title required")
  }
  row["id"]    = systime() "_" int(rand() * 100000)
  row["title"] = title
  append_tsv("data/todos.tsv", row)
  ctx.res.status(201)
  return ctx.res.html(_todo_tr(row["id"], row["title"]))
}
```

Note: `ctx.res.text` and `ctx.res.html` still work here because we're in a transitional state — Phase 4 sink enforcement is only fully checked when passing `Safe<T>` sigs. Adjust as needed based on whether sink enforcement is enabled at this point.

For `todo_delete` (uses `ctx.req.param`):

```awk
function todo_delete() -> Response {
  let raw_id ?= ctx.req.param("id")
  let deleted: Int = delete_tsv("data/todos.tsv", "id", result_val(raw_id))
  if (deleted == 0) {
    ctx.res.status(404)
    return ctx.res.text("not found")
  }
  ctx.res.status(200)
  return ctx.res.html("")
}
```

- [ ] **Step 3: Verify server still starts**

```bash
make lint
```

Expected: no lint errors

- [ ] **Step 4: Run DSL tests**

```bash
bash tests/unit/dsl/run.sh
```

Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add app.awk
git commit -m "fix(app): migrate ctx.req.* to Result<Untrusted<T>> pattern"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|-----------------|------|
| pipe `\|>` operator | Tasks 1–2 |
| match expression + default branch | Tasks 3–4 |
| `classify:` annotation parse + strip | Task 5 |
| ctx.req.* → `Result<Untrusted<T>, ParseError>` | Task 6 |
| sealed-pipe check | Task 7 |
| Untrusted propagation through transform | Task 8 |
| ctx.res.html/json/text → `Safe<T>` | Task 9 |
| app.awk migration | Task 10 |
| `_DS_FUNC_CLASS[]` storage | Task 5 (type_dataflow.awk) |
| `_ds_is_untrusted()`, `_ds_safe_inner()` helpers | Tasks 5, 9 |

**Not in this plan (out of scope per spec):**
- `--dump-types` diagnostic flag (Phase 5 of spec): intentionally deferred — adds `make test-dsl` overhead, can be a follow-up task.
- `BoundedStr<N>` validator constructor tracking: deferred — dependent type mechanics need separate design.

---

Plan complete and saved to `docs/superpowers/plans/2026-06-14-typed-dataflow-semantics.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — Fresh subagent per task, spec + code quality review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch with checkpoints.

Which approach?
