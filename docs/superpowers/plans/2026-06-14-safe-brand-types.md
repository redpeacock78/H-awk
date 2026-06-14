# Safe Brand Types + Adjacent String Literal Folding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `HtmlEscapedStr` brand type, `escape_html` trusted sanitizer, Untrusted propagation for transform+validator, brand forgery prevention, and adjacent string literal folding to Hawk DSL — eliminating `make run` type errors.

**Architecture:** 8 source files modified. Brand type kind table in `type_dataflow.awk` drives forgery prevention. `_ds_dataflow_ret` (already implemented) is connected into `desugar_pipe.awk`. `desugar_strings.awk` + `desugar_state.awk` + `desugar.awk` get adjacent-literal folding. `sig.awk` replaces `Safe<HtmlStr>` with `HtmlEscapedStr` brand and registers `escape_html` as built-in trusted sanitizer.

**Tech Stack:** GNU awk (gawk), bash test runner (`tests/unit/dsl/run.sh`). Run all DSL tests with `bash tests/unit/dsl/run.sh`.

---

## File Map

- Modify: `dsl/type_dataflow.awk` — add `_DS_TYPE_KIND` table, `_ds_is_brand`, `_ds_type_kind`, extend `_ds_dataflow_ret` for validator
- Modify: `dsl/sig.awk` — add `HtmlEscapedStr`/`HtmlFragment` kinds, `Safe<HtmlStr>` alias, `escape_html` built-in, update `ctx.res.html`/`ctx.res.text` arg types, add `html_raw` escape hatch
- Modify: `dsl/type.awk` — expand aliases per-member in `normalize`
- Modify: `dsl/desugar_pipe.awk` — connect `_ds_dataflow_ret` (line ~99), allow sanitizer to receive Untrusted
- Modify: `dsl/desugar_let.awk` — brand forgery prevention in `_ds_check_type`
- Modify: `dsl/desugar_strings.awk` — add string fold helpers (`_ds_fold_adjacent_strings_inline`, `_ds_is_pure_string_line`, `_ds_string_literal_content`, `_ds_is_let_equals_no_rhs`)
- Modify: `dsl/desugar_state.awk` — add `_DS_str_fold_*` state vars to `_ds_init`
- Modify: `dsl/desugar.awk` — add fold pre-processing in `_ds_process_line`
- Modify: `tests/unit/dsl/safe_sink_error/expected_stderr` — update for new type names + Untrusted propagation
- Modify: `tests/unit/dsl/untrusted_non_transform_error/input.awk` + `expected_stderr` — repurpose to test no-classify functions
- Create: `tests/unit/dsl/safe_escape_html_ok/` — escape_html OK flow
- Create: `tests/unit/dsl/safe_html_sink_plain_str_error/` — Str → html sink error
- Create: `tests/unit/dsl/safe_html_sink_untrusted_error/` — Untrusted<Str> → html sink error
- Create: `tests/unit/dsl/safe_html_sink_trimmed_untrusted_error/` — trim+Untrusted → html sink error
- Create: `tests/unit/dsl/safe_brand_annotation_forge_error/` — brand annotation forgery error
- Create: `tests/unit/dsl/untrusted_validator_propagates/` — validator keeps Untrusted
- Create: `tests/unit/dsl/untrusted_trim_then_html_error/` — trim then html sink error
- Create: `tests/unit/dsl/untrusted_trim_then_escape_html_ok/` — trim then escape_html then html sink OK
- Create: `tests/unit/dsl/string_adjacent_same_line/` — same-line folding
- Create: `tests/unit/dsl/string_adjacent_multiline/` — multi-line folding
- Create: `tests/unit/dsl/string_adjacent_keeps_escape_sequences/` — escape sequences preserved
- Create: `tests/unit/dsl/string_adjacent_only_literals/` — non-literal not folded
- Modify: `app.awk` — add `escape_html`/`html_raw` to fix `make run` errors

---

## Task 1: Brand type kinds + signature registry

**Files:**
- Modify: `dsl/type_dataflow.awk`
- Modify: `dsl/sig.awk`

- [ ] **Step 1: Write failing test — plain Str to html sink**

Create `tests/unit/dsl/safe_html_sink_plain_str_error/input.awk`:
```awk
function handler() -> Response {
  let html: Str = "<p>Hello</p>"
  return ctx.res.html(html)
}
```

Create `tests/unit/dsl/safe_html_sink_plain_str_error/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Str
```

- [ ] **Step 2: Run to verify it fails**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep safe_html_sink_plain
```
Expected: `FAIL: safe_html_sink_plain_str_error`

- [ ] **Step 3: Add brand kind helpers to type_dataflow.awk**

In `dsl/type_dataflow.awk`, add after the existing `_ds_safe_inner` function:
```awk
function _ds_type_kind(t,    expanded) {
    expanded = (t in awk::_DS_TYPE_ALIAS) ? awk::_DS_TYPE_ALIAS[t] : t
    return awk::_DS_TYPE_KIND[expanded]
}
function _ds_is_brand(t) { return _ds_type_kind(t) == "brand" }
```

- [ ] **Step 4: Update sig.awk**

In `dsl/sig.awk` BEGIN block:

**Add after existing `_DS_TYPE_ALIAS` lines** (after `_DS_TYPE_ALIAS["HandlerName"]`):
```awk
    # Safe<T> backward-compat aliases → brand types
    _DS_TYPE_ALIAS["Safe<HtmlStr>"] = "HtmlEscapedStr"
    _DS_TYPE_ALIAS["Safe<Str>"]     = "Str"

    # Brand type kind table
    _DS_TYPE_KIND["HtmlEscapedStr"]      = "brand"
    _DS_TYPE_KIND["HtmlFragment"]        = "brand"
    _DS_TYPE_KIND["HtmlAttrEscapedStr"]  = "brand"
```

**Change `ctx.res.html` arg** (line 65):
```awk
    _DS_SIG_ARG["ctx.res.html", 1]   = "HtmlEscapedStr|HtmlFragment"
```

**Change `ctx.res.text` arg** (line 61):
```awk
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str|Untrusted<Str>"
```

**Add after the `ctx.res.*` block** (before `ctx.res.render`):
```awk
    # escape_html: built-in trusted sanitizer
    _DS_SIG_RET["escape_html"]       = "HtmlEscapedStr"
    _DS_SIG_ARITY["escape_html"]     = 1
    _DS_SIG_ARG["escape_html", 1]    = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["escape_html"]    = "sanitizer"
    _DS_SIG_TRUSTED["escape_html"]   = 1

    # html_raw: assert-trust escape hatch for pre-built HTML strings
    _DS_SIG_RET["html_raw"]          = "HtmlEscapedStr"
    _DS_SIG_ARITY["html_raw"]        = 1
    _DS_SIG_ARG["html_raw", 1]       = "Str"
    _DS_SIG_TRUSTED["html_raw"]      = 1
```

- [ ] **Step 5: Run test**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep safe_html_sink_plain
```
Expected: `PASS: safe_html_sink_plain_str_error`

- [ ] **Step 6: Verify no existing tests broken**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```
Expected: same pass count as before (or very close — `safe_sink_error` expected_stderr will now mismatch, that's fixed in Task 3).

- [ ] **Step 7: Commit**

```bash
git add dsl/type_dataflow.awk dsl/sig.awk tests/unit/dsl/safe_html_sink_plain_str_error
git commit -m "feat(dsl): add HtmlEscapedStr brand type, escape_html sig, update ctx.res.* types"
```

---

## Task 2: normalize alias expansion

**Files:**
- Modify: `dsl/type.awk`

This ensures `Safe<HtmlStr>` stored in `_DS_SIG_RET` (via user-defined function overriding our built-in) gets expanded to `HtmlEscapedStr` when used as a type, so error messages are clean.

- [ ] **Step 1: Update `normalize` in type.awk**

Find the `normalize` function (line ~72). Change the `n == 1` early-return path AND add alias expansion per-member in the multi-member path:

**Before** (line ~74):
```awk
    if (n == 1) return out[1]
```

**After**:
```awk
    if (n == 1) return expand_alias(out[1])
```

Then after `n = split_union(t, out)` but before deduplication, add alias expansion:

**Before** (line ~76, the deduplicate loop):
```awk
    for (i = 1; i <= n; i++) seen[out[i]] = 1
```

**After**:
```awk
    for (i = 1; i <= n; i++) seen[expand_alias(out[i])] = 1
```

- [ ] **Step 2: Run all tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```
Expected: no regressions (alias expansion is transparent).

- [ ] **Step 3: Commit**

```bash
git add dsl/type.awk
git commit -m "feat(dsl): expand type aliases in normalize for cleaner error messages"
```

---

## Task 3: Untrusted propagation for validator + sanitizer Untrusted acceptance

**Files:**
- Modify: `dsl/type_dataflow.awk`
- Modify: `dsl/desugar_pipe.awk`

**Background:** `_ds_dataflow_ret` already exists in `type_dataflow.awk` but is not connected to the pipe transform. Line ~99 of `desugar_pipe.awk` sets `_DS_VAR_TYPES` directly from `_DS_SIG_RET`, stripping Untrusted. We fix both issues here.

- [ ] **Step 1: Write failing tests**

Create `tests/unit/dsl/untrusted_validator_propagates/input.awk`:
```awk
function non_empty(s: Str) -> Str {
  classify: validator
  return s
}
function handler() {
  let raw ?= ctx.req.form("title")
  let v = raw |> non_empty()
}
```

Create `tests/unit/dsl/untrusted_validator_propagates/expected.awk`:
```awk
function non_empty(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, v) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = non_empty(raw)
  v = _ds_p_1
}
```

Create `tests/unit/dsl/safe_escape_html_ok/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe = raw |> escape_html()
  return ctx.res.html(safe)
}
```

Create `tests/unit/dsl/safe_escape_html_ok/expected.awk`:
```awk
function handler(    _ds_tc_1, raw, _ds_p_1, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = escape_html(raw)
  safe = _ds_p_1
  return ctx::dispatch("res.html", safe)
}
```

Create `tests/unit/dsl/untrusted_trim_then_escape_html_ok/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  return s
}
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let trimmed = raw |> trim()
  let safe = trimmed |> escape_html()
  return ctx.res.html(safe)
}
```

Create `tests/unit/dsl/untrusted_trim_then_escape_html_ok/expected.awk`:
```awk
function trim(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, trimmed, _ds_p_2, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  trimmed = _ds_p_1
  _ds_p_2 = escape_html(trimmed)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
```

Create `tests/unit/dsl/safe_html_sink_untrusted_error/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return ctx.res.html(raw)
}
```

Create `tests/unit/dsl/safe_html_sink_untrusted_error/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Untrusted<Str>
```

Create `tests/unit/dsl/untrusted_trim_then_html_error/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  return s
}
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let trimmed = raw |> trim()
  return ctx.res.html(trimmed)
}
```

Create `tests/unit/dsl/untrusted_trim_then_html_error/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Untrusted<Str>
```

- [ ] **Step 2: Run to verify all new tests fail**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "validator_propagates|escape_html_ok|trim_then"
```
Expected: all FAIL

- [ ] **Step 3: Extend `_ds_dataflow_ret` in type_dataflow.awk**

Find `_ds_dataflow_ret` (currently only handles `transform`). Change to:
```awk
function _ds_dataflow_ret(fname, input_type,    cls, ret) {
    cls = _DS_FUNC_CLASS[fname]
    ret = _DS_SIG_RET[fname]
    if ((cls == "transform" || cls == "validator") && _ds_is_untrusted(input_type))
        return "Untrusted<" ret ">"
    return ret
}
```

- [ ] **Step 4: Connect `_ds_dataflow_ret` in desugar_pipe.awk**

Find line ~99 in `dsl/desugar_pipe.awk`:
```awk
        if (_DS_in_function) {
            _DS_VAR_TYPES[_DS_func_name, tmpvar] = _DS_SIG_RET[fname]
        }
```

Change to:
```awk
        if (_DS_in_function) {
            _DS_VAR_TYPES[_DS_func_name, tmpvar] = _ds_dataflow_ret(fname, left_type)
        }
```

- [ ] **Step 5: Allow sanitizer to receive Untrusted in desugar_pipe.awk**

Find the Untrusted check (around line ~70):
```awk
        if (_ds_is_untrusted(left_type)) {
            cls = _DS_FUNC_CLASS[fname]
            if (cls != "transform" && cls != "validator") {
                print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                    ": " fname " does not accept Untrusted input — classify as transform or unwrap first" > "/dev/stderr"
                _DS_had_error = 1
                return line
            }
        }
```

Change to:
```awk
        if (_ds_is_untrusted(left_type)) {
            cls = _DS_FUNC_CLASS[fname]
            if (cls != "transform" && cls != "validator" && cls != "sanitizer") {
                print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                    ": " fname " does not accept Untrusted input — classify as transform or unwrap first" > "/dev/stderr"
                _DS_had_error = 1
                return line
            }
        }
```

- [ ] **Step 6: Update existing tests affected by validator propagation**

Update `tests/unit/dsl/safe_sink_error/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Untrusted<NonEmptyStr>
```

Update `tests/unit/dsl/untrusted_non_transform_error/input.awk` (repurpose to test no-classify function):
```awk
function process(s: Str) -> Str {
  return s
}
function handler() {
  let raw ?= ctx.req.form("title")
  let result = raw |> process()
}
```

`tests/unit/dsl/untrusted_non_transform_error/expected_stderr` stays as-is:
```
process does not accept Untrusted input — classify as transform or unwrap first
```

- [ ] **Step 7: Run all tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -5
```
Expected: all new tests pass, no regressions.

- [ ] **Step 8: Commit**

```bash
git add dsl/type_dataflow.awk dsl/desugar_pipe.awk \
    tests/unit/dsl/untrusted_validator_propagates \
    tests/unit/dsl/safe_escape_html_ok \
    tests/unit/dsl/untrusted_trim_then_escape_html_ok \
    tests/unit/dsl/safe_html_sink_untrusted_error \
    tests/unit/dsl/untrusted_trim_then_html_error \
    tests/unit/dsl/safe_sink_error/expected_stderr \
    tests/unit/dsl/untrusted_non_transform_error/input.awk
git commit -m "feat(dsl): connect Untrusted propagation for transform+validator, allow sanitizer to receive Untrusted"
```

---

## Task 4: Brand forgery prevention

**Files:**
- Modify: `dsl/desugar_let.awk`

- [ ] **Step 1: Write failing test**

Create `tests/unit/dsl/safe_brand_annotation_forge_error/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe: HtmlEscapedStr = raw
  return ctx.res.html(safe)
}
```

Create `tests/unit/dsl/safe_brand_annotation_forge_error/expected_stderr`:
```
safe/brand type cannot be created by annotation
```

- [ ] **Step 2: Run to verify it fails**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep brand_annotation
```
Expected: `FAIL: safe_brand_annotation_forge_error`

- [ ] **Step 3: Add brand forgery check to `_ds_check_type` in desugar_let.awk**

Find `_ds_check_type` (around line ~42):
```awk
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    if (type::accepts(declared, inferred)) return
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
}
```

Change to:
```awk
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    if (type::accepts(declared, inferred)) return
    if (_ds_is_brand(declared)) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": safe/brand type cannot be created by annotation" > "/dev/stderr"
        print "  " declared " must be constructed by trusted sanitizer" > "/dev/stderr"
        _DS_had_error = 1
        return
    }
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
}
```

- [ ] **Step 4: Run test**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep brand_annotation
```
Expected: `PASS: safe_brand_annotation_forge_error`

- [ ] **Step 5: Run all tests to check for regressions**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```
Expected: no regressions.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_let.awk tests/unit/dsl/safe_brand_annotation_forge_error
git commit -m "feat(dsl): prevent brand type creation by annotation"
```

---

## Task 5: Adjacent string literal folding

**Files:**
- Modify: `dsl/desugar_strings.awk`
- Modify: `dsl/desugar_state.awk`
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/dsl/string_adjacent_same_line/input.awk`:
```awk
function f() -> Str {
  let s = "<foo>" "<bar>"
  return s
}
```

Create `tests/unit/dsl/string_adjacent_same_line/expected.awk`:
```awk
function f(    s) {
  s = "<foobar>"
  return s
}
```

Create `tests/unit/dsl/string_adjacent_multiline/input.awk`:
```awk
function f() -> Str {
  let html =
    "<tr>"
    "<td>Hello</td>"
    "</tr>"
  return html
}
```

Create `tests/unit/dsl/string_adjacent_multiline/expected.awk`:
```awk
function f(    html) {
  html = "<tr><td>Hello</td></tr>"
  return html
}
```

Create `tests/unit/dsl/string_adjacent_keeps_escape_sequences/input.awk`:
```awk
function f() -> Str {
  let s = "<p>line1\n</p>" "<p>line2\t</p>"
  return s
}
```

Create `tests/unit/dsl/string_adjacent_keeps_escape_sequences/expected.awk`:
```awk
function f(    s) {
  s = "<p>line1\n</p><p>line2\t</p>"
  return s
}
```

Create `tests/unit/dsl/string_adjacent_only_literals/input.awk`:
```awk
function f() -> Str {
  let s = "hello"
  return s
}
```

Create `tests/unit/dsl/string_adjacent_only_literals/expected.awk`:
```awk
function f(    s) {
  s = "hello"
  return s
}
```

- [ ] **Step 2: Run to verify tests fail**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep string_adjacent
```
Expected: FAIL for same_line, multiline, escape_sequences (only_literals may accidentally pass).

- [ ] **Step 3: Add state vars to desugar_state.awk**

In `_ds_init()` in `dsl/desugar_state.awk`, add after the existing deletes:
```awk
  _DS_str_fold_active  = 0
  _DS_str_fold_prefix  = ""
  _DS_str_fold_pending = ""
```

- [ ] **Step 4: Add fold helper functions to desugar_strings.awk**

Append to `dsl/desugar_strings.awk`:
```awk
# _ds_fold_adjacent_strings_inline: merge adjacent string literals on same line.
# "foo" "bar" -> "foobar"
function _ds_fold_adjacent_strings_inline(line,    segs, n, i, j) {
  n = _ds_split_code_segs(line, segs)
  i = 1
  while (i <= n) {
    if (segs[i, "safe"] == 0) {
      j = i + 1
      while (j <= n && segs[j, "safe"] == 1 && _ds_trim(segs[j, "text"]) == "" && \
             (j + 1) <= n && segs[j + 1, "safe"] == 0) {
        segs[i, "text"] = substr(segs[i, "text"], 1, length(segs[i, "text"]) - 1) \
                           substr(segs[j + 1, "text"], 2)
        segs[j,     "text"] = ""
        segs[j + 1, "text"] = ""
        segs[j + 1, "safe"] = 1
        j += 2
      }
    }
    i++
  }
  line = ""
  for (i = 1; i <= n; i++) line = line segs[i, "text"]
  return line
}

# _ds_is_pure_string_line: returns 1 if line is only whitespace + exactly one string literal.
function _ds_is_pure_string_line(line,    segs, n, i, sc) {
  n = _ds_split_code_segs(line, segs)
  sc = 0
  for (i = 1; i <= n; i++) {
    if (segs[i, "safe"] == 0) { sc++ }
    else if (_ds_trim(segs[i, "text"]) != "") { return 0 }
  }
  return (sc == 1)
}

# _ds_string_literal_content: extracts inner content of the one string literal on a pure-string line.
function _ds_string_literal_content(line,    segs, n, i, s) {
  n = _ds_split_code_segs(line, segs)
  for (i = 1; i <= n; i++) {
    if (segs[i, "safe"] == 0) {
      s = segs[i, "text"]
      return substr(s, 2, length(s) - 2)
    }
  }
  return ""
}

# _ds_is_let_equals_no_rhs: matches "let varname =" with nothing after "=".
function _ds_is_let_equals_no_rhs(line) {
  return (line ~ /^[[:space:]]*let[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*$/)
}
```

- [ ] **Step 5: Add fold pre-processing to `_ds_process_line` in desugar.awk**

Find the beginning of `_ds_process_line` function body (after `_DS_current_lineno = lineno`). Add fold logic right after, before the `!_DS_in_function` check:

```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p, dot_transformed, pipe_pre, pipe_result, match_m) {
  _DS_current_lineno = lineno

  # Multi-line adjacent string literal accumulation (inside function body only)
  if (_DS_in_function) {
    if (_DS_str_fold_active) {
      if (_ds_is_pure_string_line(line)) {
        _DS_str_fold_pending = _DS_str_fold_pending _ds_string_literal_content(line)
        return
      } else {
        _DS_str_fold_active = 0
        if (_DS_str_fold_pending != "") {
          _ds_process_line(_DS_str_fold_prefix "\"" _DS_str_fold_pending "\"", lineno)
        }
        # fall through to process current line
      }
    }
    if (_ds_is_let_equals_no_rhs(line)) {
      _DS_str_fold_prefix  = line
      _DS_str_fold_pending = ""
      _DS_str_fold_active  = 1
      return
    }
  }

  # Same-line adjacent string literal folding (all lines)
  line = _ds_fold_adjacent_strings_inline(line)

  if (!_DS_in_function) {
  # ... rest of existing code unchanged ...
```

Also add a flush when the function body closes (in the `_DS_brace_depth <= 0` branch):
```awk
  if (_DS_brace_depth <= 0) {
    # Flush any pending string fold
    if (_DS_str_fold_active) {
      _DS_str_fold_active = 0
      if (_DS_str_fold_pending != "") {
        _ds_process_line(_DS_str_fold_prefix "\"" _DS_str_fold_pending "\"", lineno)
      }
    }
    _DS_in_function = 0
    # ... rest of existing close-brace code ...
```

- [ ] **Step 6: Run tests**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep string_adjacent
```
Expected: all 4 tests pass.

- [ ] **Step 7: Run full suite**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```
Expected: no regressions.

- [ ] **Step 8: Commit**

```bash
git add dsl/desugar_strings.awk dsl/desugar_state.awk dsl/desugar.awk \
    tests/unit/dsl/string_adjacent_same_line \
    tests/unit/dsl/string_adjacent_multiline \
    tests/unit/dsl/string_adjacent_keeps_escape_sequences \
    tests/unit/dsl/string_adjacent_only_literals
git commit -m "feat(dsl): adjacent string literal folding — same-line and multi-line"
```

---

## Task 6: app.awk fix

**Files:**
- Modify: `app.awk`

**Background:** After Task 1–4, `make run` still fails for `ctx.res.html(out)` (concatenated Str) and `ctx.res.html("")` (empty Str). `ctx.res.text("...")` errors are resolved by the `Str|Untrusted<Str>` change. Use `html_raw(s: Str)` (registered in Task 1) as an explicit trust assertion for pre-built HTML strings, and `escape_html` for user-provided content in `_todo_tr`.

- [ ] **Step 1: Check which lines still error**

```bash
gawk -f dsl/desugar.awk app.awk 2>&1 | grep "dsl error"
```
Expected (after Tasks 1–4): only `ctx.res.html` lines remain.

- [ ] **Step 2: Fix `_todo_tr` to escape user content and return HtmlEscapedStr**

Find `_todo_tr` function signature. Change:
```awk
function _todo_tr(id: Str, title: Str) -> Str {
```
To:
```awk
function _todo_tr(id: Str, title: Str) -> HtmlEscapedStr {
  classify: sanitizer
```

Inside `_todo_tr`, the `sprintf` call uses `title` directly. Change to use `escape_html(title)` for the title cell. Find the sprintf call and change the format arg for title:
```awk
    title, id)
```
to:
```awk
    escape_html(title), id)
```

- [ ] **Step 3: Fix `ctx.res.html` calls that use concatenated Str**

In `todo_list_html`, change:
```awk
  return ctx.res.html(out)
```
to:
```awk
  return ctx.res.html(html_raw(out))
```

In `todo_add`, change:
```awk
  return ctx.res.html(_todo_tr(row["id"], row["title"]))
```
to (no change needed — `_todo_tr` now returns `HtmlEscapedStr` after Step 2):
```awk
  return ctx.res.html(_todo_tr(row["id"], row["title"]))
```

In `todo_delete`, change:
```awk
  return ctx.res.html("")
```
to:
```awk
  return ctx.res.html(escape_html(""))
```

- [ ] **Step 4: Verify no more dsl errors**

```bash
gawk -f dsl/desugar.awk app.awk 2>&1 | grep "dsl error"
```
Expected: no output (no errors).

- [ ] **Step 5: Run full DSL test suite**

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```
Expected: all pass.

- [ ] **Step 6: Smoke test with make**

```bash
make run &
sleep 2
curl -s http://localhost:8080/ | head -5
kill %1
```
Expected: HTML response from the app, no desugar errors.

- [ ] **Step 7: Commit**

```bash
git add app.awk
git commit -m "fix(app): escape HTML output via escape_html/html_raw — resolves make run type errors"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|-----------------|------|
| HtmlEscapedStr brand type registered | Task 1 |
| escape_html as trusted sanitizer | Task 1 |
| ctx.res.html accepts HtmlEscapedStr\|HtmlFragment | Task 1 |
| ctx.res.text relaxed to Str\|Untrusted<Str> | Task 1 |
| Safe<HtmlStr> alias → HtmlEscapedStr | Task 1 |
| normalize expands aliases | Task 2 |
| transform propagates Untrusted | Task 3 |
| validator propagates Untrusted | Task 3 |
| sanitizer can receive Untrusted | Task 3 |
| Untrusted<Str> → ctx.res.html = error | Task 3 |
| trim → ctx.res.html = error | Task 3 |
| brand annotation forgery = error | Task 4 |
| adjacent string literals same-line | Task 5 |
| adjacent string literals multi-line | Task 5 |
| escape sequences preserved | Task 5 |
| make run errors resolved | Task 6 |

**Placeholder scan:** No TBD/TODO in tasks. All steps have code.

**Type consistency:**
- `_ds_is_brand` defined in Task 1 (type_dataflow.awk), used in Task 4 (desugar_let.awk) — consistent ✓
- `_ds_dataflow_ret` extended in Task 3 (type_dataflow.awk), connected in Task 3 (desugar_pipe.awk) — consistent ✓
- `_DS_str_fold_*` added to `_ds_init` in Task 5 (desugar_state.awk), used in Task 5 (desugar.awk) — consistent ✓
- `html_raw` registered in Task 1 (sig.awk), used in Task 6 (app.awk) — consistent ✓
- Error message `ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment` in Task 3 tests matches the actual sig `"HtmlEscapedStr|HtmlFragment"` set in Task 1 ✓

**Ambiguity note:** Task 5 Step 5 shows the modified `_ds_process_line` header with `# ... rest of existing code unchanged ...`. Implementer must keep ALL existing logic inside the function — only adding the fold pre-processing block at the top and the flush in the close-brace branch.
