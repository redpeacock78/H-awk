# safe.* Namespace + String Interpolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace top-level `escape_html`/`html_raw` with `safe.*` namespace, add `#{...}` string interpolation with Untrusted propagation and HTML-fragment context checking.

**Architecture:** Desugar pipeline extended in three places: (1) `desugar_strings.awk` gets a new `_ds_expand_interp` pass that rewrites `#{...}` before pipe/dot transforms run; (2) `desugar_pipe.awk` regex extended to allow dot-notation on the RHS of `|>`, with `desugar.awk` applying `_ds_dot_transform` to pipe pre-buffer lines; (3) `desugar_dot.awk` / `typecheck.awk` handle `safe.html.fragment` arg literal-Str special case. A new `core/safe.awk` AWK namespace provides the runtime functions.

**Tech Stack:** gawk (GNU AWK), existing `hawk_dispatch::call` mechanism, DSL desugar pipeline in `dsl/*.awk`.

---

## File Map

| File | Change |
|---|---|
| `core/safe.awk` | **Create** — `safe::` runtime namespace |
| `hawk.awk` | **Modify** — add `@include "core/safe.awk"` |
| `dsl/sig.awk` | **Modify** — remove `escape_html`/`html_raw`; add `safe.*`, `HtmlPart` alias |
| `dsl/desugar_pipe.awk` | **Modify** — allow dot-notation in pipe RHS regex |
| `dsl/desugar.awk` | **Modify** — apply `_ds_dot_transform` to pipe pre-buffer lines |
| `dsl/desugar_strings.awk` | **Modify** — add `_ds_parse_interp`, `_ds_expand_interp` |
| `dsl/typecheck.awk` | **Modify** — `safe.html.fragment` literal-Str special case |
| `app.awk` | **Modify** — migrate to `safe.*` |
| `tests/unit/dsl/safe_escape_html_ok/` | **Modify** — update to use `safe.html.escape` |
| `tests/unit/dsl/untrusted_trim_then_escape_html_ok/` | **Modify** — update to use `safe.html.escape` |
| `tests/unit/dsl/safe_*/` (new) | **Create** — safe namespace tests |
| `tests/unit/dsl/string_interpolation_*/` (new) | **Create** — interpolation tests |
| `tests/unit/dsl/safe_fragment_*/` (new) | **Create** — fragment interpolation tests |
| `README.md` | **Modify** — update Safe HTML + classify sections |

---

### Task 1: Create `core/safe.awk` runtime namespace

**Files:**
- Create: `core/safe.awk`

- [ ] **Step 1: Create the file**

```awk
# SPDX-License-Identifier: MIT
# core/safe.awk -- safe:: namespace: HTML sanitizers and trusted escape hatches

@namespace "safe"

BEGIN {
    _SAFE_ROUTES["html.escape"]   = "safe::html_escape"
    _SAFE_ROUTES["html.raw"]      = "safe::html_raw"
    _SAFE_ROUTES["html.fragment"] = "safe::html_fragment"
    _SAFE_ROUTES["attr.escape"]   = "safe::attr_escape"
    _SAFE_ARITY["html.escape"]    = 1
    _SAFE_ARITY["html.raw"]       = 1
    _SAFE_ARITY["html.fragment"]  = 3
    _SAFE_ARITY["attr.escape"]    = 1
}

function html_escape(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    gsub(/'/, "\\&#39;", s)
    return s
}

function attr_escape(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    gsub(/'/, "\\&#39;", s)
    return s
}

function html_raw(s) {
    return s
}

function html_fragment(a, b, c) {
    return a b c
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("safe", _SAFE_ROUTES, _SAFE_ARITY, path, a1, a2, a3)
}

@namespace "awk"
```

- [ ] **Step 2: Add include to `hawk.awk`**

In `hawk.awk`, after `@include "dsl/type.awk"` add:

```awk
@include "core/safe.awk"
```

- [ ] **Step 3: Smoke-test the runtime loads**

```bash
HAWK_NO_SERVE=1 gawk -f hawk.awk -e 'BEGIN { print safe::dispatch("html.escape", "<b>ok</b>") }' 2>&1
```

Expected output: `&lt;b&gt;ok&lt;/b&gt;`

- [ ] **Step 4: Commit**

```bash
git add core/safe.awk hawk.awk
git commit -m "feat(runtime): add safe:: namespace (html_escape, html_raw, html_fragment, attr_escape)"
```

---

### Task 2: Update `dsl/sig.awk` — remove old functions, add `safe.*`

**Files:**
- Modify: `dsl/sig.awk`

- [ ] **Step 1: Remove `escape_html` and `html_raw` entries**

In `dsl/sig.awk`, delete these lines:

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

- [ ] **Step 2: Add `HtmlPart` alias and `safe.*` signatures**

After the existing type alias block (after `_DS_TYPE_KIND["HtmlAttrEscapedStr"] = "brand"`), add:

```awk
    _DS_TYPE_ALIAS["HtmlPart"] = "HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr"

    # safe.html.escape: sanitizer — Untrusted<Str> | Str → HtmlEscapedStr
    _DS_SIG_RET["safe.html.escape"]         = "HtmlEscapedStr"
    _DS_SIG_ARITY["safe.html.escape"]       = 1
    _DS_SIG_ARG["safe.html.escape", 1]      = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["safe.html.escape"]      = "sanitizer"
    _DS_SIG_TRUSTED["safe.html.escape"]     = 1

    # safe.attr.escape: sanitizer — Untrusted<Str> | Str → HtmlAttrEscapedStr
    _DS_SIG_RET["safe.attr.escape"]         = "HtmlAttrEscapedStr"
    _DS_SIG_ARITY["safe.attr.escape"]       = 1
    _DS_SIG_ARG["safe.attr.escape", 1]      = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["safe.attr.escape"]      = "sanitizer"
    _DS_SIG_TRUSTED["safe.attr.escape"]     = 1

    # safe.html.raw: trust assertion — Str → HtmlFragment (does not escape)
    _DS_SIG_RET["safe.html.raw"]            = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.raw"]          = 1
    _DS_SIG_ARG["safe.html.raw", 1]         = "Str"
    _DS_FUNC_CLASS["safe.html.raw"]         = "trusted"
    _DS_SIG_TRUSTED["safe.html.raw"]        = 1

    # safe.html.fragment: builder — up to 3 HtmlPart args → HtmlFragment
    _DS_SIG_RET["safe.html.fragment"]       = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.fragment"]     = 3
    _DS_SIG_ARG["safe.html.fragment", 1]    = "HtmlPart"
    _DS_SIG_ARG["safe.html.fragment", 2]    = "HtmlPart"
    _DS_SIG_ARG["safe.html.fragment", 3]    = "HtmlPart"
    _DS_FUNC_CLASS["safe.html.fragment"]    = "builder"
    _DS_SIG_TRUSTED["safe.html.fragment"]   = 1
```

- [ ] **Step 3: Run DSL tests to see expected failures**

```bash
make test-dsl 2>&1 | grep -E "FAIL|PASS" | head -20
```

Expected: `safe_escape_html_ok` and `untrusted_trim_then_escape_html_ok` FAIL (they still use `escape_html`). Tests that expect `escape_html` to be unknown will now PASS.

- [ ] **Step 4: Commit**

```bash
git add dsl/sig.awk
git commit -m "feat(dsl): remove escape_html/html_raw; add safe.* signatures and HtmlPart alias"
```

---

### Task 3: Fix pipe desugar — support dot-notation RHS

**Background:** `_ds_pipe_transform` in `dsl/desugar_pipe.awk` currently only matches simple identifiers (no dots) on the right side of `|>`. `raw |> safe.html.escape()` fails to parse. Two fixes needed: (1) regex to allow dots in fname, (2) `desugar.awk` must apply `_ds_dot_transform` to pipe pre-buffer lines.

**Files:**
- Modify: `dsl/desugar_pipe.awk`
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Update the pipe RHS regex in `desugar_pipe.awk`**

Find the line (around line 73):
```awk
        if (!match(rhs, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(/, m))
```

Replace with:
```awk
        if (!match(rhs, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*)[[:space:]]*\(/, m))
```

After this line, `fname = m[1]` captures the full dotted name (e.g. `"safe.html.escape"`).

- [ ] **Step 2: Fix Untrusted check to use dotted fname**

The existing code at line ~83 already does `cls = _DS_FUNC_CLASS[fname]`. With `fname = "safe.html.escape"` and `_DS_FUNC_CLASS["safe.html.escape"] = "sanitizer"` set in sig.awk, this works without change. No modification needed here.

- [ ] **Step 3: Fix `_ds_dataflow_ret` call for dotted fname**

The existing code at line ~95:
```awk
        _DS_VAR_TYPES[_DS_func_name, tmpvar] = _ds_dataflow_ret(fname, left_type)
```

`_ds_dataflow_ret("safe.html.escape", "Untrusted<Str>")` uses `_DS_SIG_RET["safe.html.escape"]` = `"HtmlEscapedStr"` and `_DS_FUNC_CLASS["safe.html.escape"]` = `"sanitizer"`. Since cls is "sanitizer" (not transform/validator), it returns `ret` = `"HtmlEscapedStr"`. Correct — no change needed.

- [ ] **Step 4: Apply `_ds_dot_transform` to pipe pre-buffer in `desugar.awk`**

Find the three places in `desugar.awk` where `pipe_pre` lines are emitted/stored. Replace each with a dot-transformed version:

**Outside function (lines ~75-76):**
```awk
# Before:
for (p = 1; p in pipe_pre; p++) print pipe_pre[p]
# After:
for (p = 1; p in pipe_pre; p++) print _ds_dot_transform(pipe_pre[p])
```

**Inside `_ds_process_line` body (lines ~141-142):**
```awk
# Before:
for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = pipe_pre[p]
# After:
for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = _ds_dot_transform(pipe_pre[p])
```

**Inside `_ds_flush_string_fold` (lines ~171-172):**
```awk
# Before:
for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = pipe_pre[p]
# After:
for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = _ds_dot_transform(pipe_pre[p])
```

- [ ] **Step 5: Write a failing test first**

Create `tests/unit/dsl/safe_namespace_escape_ok/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe = raw |> safe.html.escape()
  return ctx.res.html(safe)
}
```

Create `tests/unit/dsl/safe_namespace_escape_ok/expected.awk`:
```awk
function handler(    _ds_tc_1, raw, _ds_p_1, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  safe = _ds_p_1
  return ctx::dispatch("res.html", safe)
}
```

- [ ] **Step 6: Run test to confirm it fails before fix**

```bash
make test-dsl 2>&1 | grep safe_namespace_escape_ok
```

Expected: `FAIL: safe_namespace_escape_ok`

- [ ] **Step 7: Apply the fixes from Steps 1 and 4, then run test**

```bash
make test-dsl 2>&1 | grep safe_namespace_escape_ok
```

Expected: `PASS: safe_namespace_escape_ok`

- [ ] **Step 8: Run full DSL test suite**

```bash
make test-dsl 2>&1 | grep FAIL
```

Expected: Only `untrusted_trim_then_escape_html_ok` and `safe_escape_html_ok` fail (they still use old `escape_html`).

- [ ] **Step 9: Commit**

```bash
git add dsl/desugar_pipe.awk dsl/desugar.awk tests/unit/dsl/safe_namespace_escape_ok/
git commit -m "fix(dsl): support dot-notation function in pipe RHS; apply dot transform to pipe pre-buf"
```

---

### Task 4: Update existing tests that use `escape_html`

**Files:**
- Modify: `tests/unit/dsl/safe_escape_html_ok/input.awk`
- Modify: `tests/unit/dsl/safe_escape_html_ok/expected.awk`
- Modify: `tests/unit/dsl/untrusted_trim_then_escape_html_ok/input.awk`
- Modify: `tests/unit/dsl/untrusted_trim_then_escape_html_ok/expected.awk`

- [ ] **Step 1: Update `safe_escape_html_ok` input**

Replace `tests/unit/dsl/safe_escape_html_ok/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe = raw |> safe.html.escape()
  return ctx.res.html(safe)
}
```

- [ ] **Step 2: Update `safe_escape_html_ok` expected output**

Replace `tests/unit/dsl/safe_escape_html_ok/expected.awk`:
```awk
function handler(    _ds_tc_1, raw, _ds_p_1, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  safe = _ds_p_1
  return ctx::dispatch("res.html", safe)
}
```

- [ ] **Step 3: Update `untrusted_trim_then_escape_html_ok` input**

Replace `tests/unit/dsl/untrusted_trim_then_escape_html_ok/input.awk`:
```awk
function trim(s: Str) -> Str {
  classify: transform
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let trimmed = raw |> trim()
  let safe = trimmed |> safe.html.escape()
  return ctx.res.html(safe)
}
```

- [ ] **Step 4: Update `untrusted_trim_then_escape_html_ok` expected output**

Replace `tests/unit/dsl/untrusted_trim_then_escape_html_ok/expected.awk`:
```awk
function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
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
  _ds_p_2 = safe::dispatch("html.escape", trimmed)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
```

- [ ] **Step 5: Run and confirm both PASS**

```bash
make test-dsl 2>&1 | grep -E "safe_escape_html_ok|untrusted_trim_then_escape_html_ok"
```

Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/unit/dsl/safe_escape_html_ok/ tests/unit/dsl/untrusted_trim_then_escape_html_ok/
git commit -m "test(dsl): migrate escape_html tests to safe.html.escape"
```

---

### Task 5: Add `safe.*` error tests

**Files:**
- Create: `tests/unit/dsl/safe_namespace_old_escape_unknown_error/`
- Create: `tests/unit/dsl/safe_namespace_old_raw_unknown_error/`
- Create: `tests/unit/dsl/safe_namespace_raw_ok/`
- Create: `tests/unit/dsl/safe_namespace_attr_escape_ok/`
- Create: `tests/unit/dsl/safe_namespace_html_sink_untrusted_error/`

- [ ] **Step 1: `safe_namespace_old_escape_unknown_error`**

Create `tests/unit/dsl/safe_namespace_old_escape_unknown_error/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return ctx.res.html(escape_html(raw))
}
```

Create `tests/unit/dsl/safe_namespace_old_escape_unknown_error/expected_stderr`:
```
unknown function escape_html
```

Create `tests/unit/dsl/safe_namespace_old_escape_unknown_error/expected_exit`:
```
1
```

- [ ] **Step 2: `safe_namespace_old_raw_unknown_error`**

Create `tests/unit/dsl/safe_namespace_old_raw_unknown_error/input.awk`:
```awk
function handler() -> Response {
  let out: Str = "<p>Hello</p>"
  return ctx.res.html(html_raw(out))
}
```

Create `tests/unit/dsl/safe_namespace_old_raw_unknown_error/expected_stderr`:
```
unknown function html_raw
```

Create `tests/unit/dsl/safe_namespace_old_raw_unknown_error/expected_exit`:
```
1
```

- [ ] **Step 3: `safe_namespace_raw_ok`**

Create `tests/unit/dsl/safe_namespace_raw_ok/input.awk`:
```awk
function handler() -> Response {
  let out: Str = "<p>Hello</p>"
  let frag = out |> safe.html.raw()
  return ctx.res.html(frag)
}
```

Create `tests/unit/dsl/safe_namespace_raw_ok/expected.awk`:
```awk
function handler(    out, _ds_p_1, frag) {
  out = "<p>Hello</p>"
  _ds_p_1 = safe::dispatch("html.raw", out)
  frag = _ds_p_1
  return ctx::dispatch("res.html", frag)
}
```

- [ ] **Step 4: `safe_namespace_attr_escape_ok`**

Create `tests/unit/dsl/safe_namespace_attr_escape_ok/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.param("id")
  let attr = raw |> safe.attr.escape()
  return ctx.res.html(attr)
}
```

Create `tests/unit/dsl/safe_namespace_attr_escape_ok/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got HtmlAttrEscapedStr
```

Create `tests/unit/dsl/safe_namespace_attr_escape_ok/expected_exit`:
```
1
```

(Note: `HtmlAttrEscapedStr` is not accepted by `ctx.res.html` — it's for attribute context only.)

- [ ] **Step 5: `safe_namespace_html_sink_untrusted_error`**

Create `tests/unit/dsl/safe_namespace_html_sink_untrusted_error/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return ctx.res.html(raw)
}
```

Create `tests/unit/dsl/safe_namespace_html_sink_untrusted_error/expected_stderr`:
```
ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Untrusted<Str>
```

Create `tests/unit/dsl/safe_namespace_html_sink_untrusted_error/expected_exit`:
```
1
```

- [ ] **Step 6: Run all new tests**

```bash
make test-dsl 2>&1 | grep -E "safe_namespace"
```

Expected: all 5 new tests PASS. (The old_escape and old_raw tests: check that DSL test runner checks `expected_exit` file. If not implemented, verify the run.sh script handles this case — if it already checks exit code via the `expected_exit` file pattern, these work as-is.)

- [ ] **Step 7: Check DSL test runner handles `expected_exit` files**

```bash
cat tests/unit/dsl/run.sh
```

Verify the runner reads `expected_exit` for each test dir. If not, add that logic:
```bash
expected_exit=0
if [ -f "${dir}expected_exit" ]; then
    expected_exit=$(tr -d '[:space:]' < "${dir}expected_exit")
fi
```

- [ ] **Step 8: Commit**

```bash
git add tests/unit/dsl/safe_namespace_old_escape_unknown_error/ \
        tests/unit/dsl/safe_namespace_old_raw_unknown_error/ \
        tests/unit/dsl/safe_namespace_raw_ok/ \
        tests/unit/dsl/safe_namespace_attr_escape_ok/ \
        tests/unit/dsl/safe_namespace_html_sink_untrusted_error/
git commit -m "test(dsl): add safe namespace error and ok tests"
```

---

### Task 6: Implement string interpolation in `dsl/desugar_strings.awk`

**Background:** Add two functions: `_ds_parse_interp` (splits a string's content into literal/expression alternating parts) and `_ds_expand_interp` (rewrites a line's string literals that contain `#{...}`). The function handles two contexts: `"normal"` (produces `sprintf(...)`) and `"html.fragment"` (splits the containing `safe.html.fragment` arg into multiple positional args).

**Files:**
- Modify: `dsl/desugar_strings.awk`

- [ ] **Step 1: Add `_ds_parse_interp` — splits string content at `#{...}` boundaries**

Add after `_ds_fold_adjacent_strings_inline` in `dsl/desugar_strings.awk`:

```awk
# _ds_parse_interp: split string content (without outer quotes) at #{...} boundaries.
# Fills parts[1], parts[2], ... alternating: literal, expr, literal, expr, literal
# Odd indices = literal text, even indices = expression text.
# Returns total count (always odd: at least 1 literal part).
function _ds_parse_interp(content, parts,    i, c, n, cur, depth) {
    n = 0; cur = ""; depth = 0
    for (i = 1; i <= length(content); i++) {
        c = substr(content, i, 1)
        if (depth == 0) {
            if (c == "#" && i < length(content) && substr(content, i+1, 1) == "{") {
                parts[++n] = cur; cur = ""
                depth = 1; i++  # skip "{"
            } else if (c == "\\" && i < length(content)) {
                cur = cur c substr(content, ++i, 1)  # pass escape sequence through
            } else {
                cur = cur c
            }
        } else {
            if      (c == "{") { depth++; cur = cur c }
            else if (c == "}") {
                depth--
                if (depth == 0) { parts[++n] = cur; cur = "" }
                else              cur = cur c
            } else { cur = cur c }
        }
    }
    parts[++n] = cur  # trailing literal (may be empty)
    return n
}

# _ds_interp_expr_type: infer the type of an interpolation expression.
# For pipe chains, traces the return type of the rightmost function.
function _ds_interp_expr_type(expr,    m, fname) {
    # Rightmost pipe call: "expr |> fname()" — return type of fname
    if (match(expr, /\|>[[:space:]]*([a-zA-Z_][a-zA-Z0-9_.]*)[[:space:]]*\([^)]*\)[[:space:]]*$/, m)) {
        fname = m[1]
        if (fname in _DS_SIG_RET) return _DS_SIG_RET[fname]
    }
    return _ds_infer_type(_ds_trim(expr))
}

# _ds_expand_interp: rewrite string interpolation #{...} in one line.
# context: "normal" → sprintf; "html.fragment" is handled by _ds_expand_fragment_interp.
# Returns the rewritten line (or original if no #{} found).
function _ds_expand_interp(line, lineno,    segs, n, i, content, parts, np, j, \
                                             fmt, args, expr_type, result, any_untrusted, \
                                             pfx, new_line) {
    n = _ds_split_code_segs(line, segs)
    new_line = ""
    for (i = 1; i <= n; i++) {
        if (segs[i, "safe"] == 0 && segs[i, "text"] ~ /^"/ && segs[i, "text"] ~ /#{/) {
            # String literal containing #{...}
            content = _ds_string_literal_content(segs[i, "text"])
            np = _ds_parse_interp(content, parts)
            # np is always odd: lit, [expr, lit, ...]
            if (np == 1) {
                # No interpolation found (only a literal part — shouldn't happen given ~ /#{/)
                new_line = new_line segs[i, "text"]
            } else {
                # Build sprintf call
                fmt = ""; args = ""; any_untrusted = 0
                for (j = 1; j <= np; j++) {
                    if (j % 2 == 1) {
                        # Literal part: escape any % for sprintf
                        pfx = parts[j]; gsub(/%/, "%%", pfx)
                        fmt = fmt pfx
                    } else {
                        # Expression part
                        expr_type = _ds_interp_expr_type(parts[j])
                        if (_ds_is_nullable(expr_type)) {
                            print "dsl error: " _DS_src_file ":" lineno \
                                ": cannot interpolate sealed " expr_type \
                                "; use ?= or match first" > "/dev/stderr"
                            _DS_had_error = 1
                        }
                        if (_ds_is_untrusted(expr_type)) any_untrusted = 1
                        fmt = fmt "%s"
                        args = args ", " _ds_trim(parts[j])
                    }
                }
                result = "sprintf(\"" fmt "\"" args ")"
                new_line = new_line result
                # Track untrusted propagation for variable assignment context
                _DS_last_interp_untrusted = any_untrusted
            }
            # Clear parts array for next string
            delete parts
        } else {
            new_line = new_line segs[i, "text"]
        }
    }
    return new_line
}

# _ds_expand_fragment_interp: expand #{...} in safe.html.fragment string arg.
# Rewrites: safe.html.fragment("a#{expr}b") → safe.html.fragment("a", expr, "b")
# Type-checks each expr against HtmlPart.
# Returns the rewritten line, or original if no interpolation found.
function _ds_expand_fragment_interp(line, lineno,    m, prefix, str_arg, content, \
                                                      parts, np, j, new_args, expr_type) {
    # Match: safe.html.fragment("...") where the string contains #{
    if (!match(line, /safe\.html\.fragment\("([^"]*)"\)/, m)) return line
    if (index(m[0], "#{") == 0) return line  # no interpolation in this call

    str_arg = m[0]
    content = m[1]
    np = _ds_parse_interp(content, parts)
    if (np == 1) return line  # no #{} found

    new_args = ""
    for (j = 1; j <= np; j++) {
        if (j > 1) new_args = new_args ", "
        if (j % 2 == 1) {
            # Literal part
            if (parts[j] != "") new_args = new_args "\"" parts[j] "\""
            else if (np > 1 && j < np) {} # skip empty literal between exprs — omit from args
            # Note: skip truly empty literals to avoid empty-string args
        } else {
            # Expression part — type check
            expr_type = _ds_interp_expr_type(_ds_trim(parts[j]))
            if (!type::accepts("HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr", expr_type) &&
                expr_type != "") {
                print "dsl error: " _DS_src_file ":" lineno \
                    ": safe.html.fragment interpolation expects HtmlPart, got " expr_type \
                    > "/dev/stderr"
                if (_ds_is_untrusted(expr_type))
                    print "  help: use safe.html.escape()" > "/dev/stderr"
                _DS_had_error = 1
            }
            new_args = new_args _ds_trim(parts[j])
        }
    }
    delete parts

    # Rebuild line with expanded args
    prefix = substr(line, 1, index(line, str_arg) - 1)
    return prefix "safe.html.fragment(" new_args ")" \
           substr(line, index(line, str_arg) + length(str_arg))
}
```

Note: `_DS_last_interp_untrusted` is a global used to propagate Untrusted type to the enclosing let binding. This is handled in Task 7.

- [ ] **Step 2: Verify the file parses without gawk errors**

```bash
gawk -f dsl/desugar.awk /dev/null 2>&1
```

Expected: no syntax errors from gawk itself.

- [ ] **Step 3: Commit**

```bash
git add dsl/desugar_strings.awk
git commit -m "feat(dsl): add _ds_parse_interp and _ds_expand_interp for string interpolation"
```

---

### Task 7: Hook interpolation into the desugar pipeline in `dsl/desugar.awk`

**Background:** Interpolation expansion must run after adjacent-string fold but before pipe/dot transforms. Fragment interpolation (`safe.html.fragment`) needs its own pre-pass. Untrusted propagation from `#{raw}` must be tracked via `_DS_last_interp_untrusted` and applied when a let binding stores the result.

**Files:**
- Modify: `dsl/desugar.awk`
- Modify: `dsl/desugar_let.awk` (Untrusted propagation for sprintf results)

- [ ] **Step 1: Add interpolation calls to `_ds_process_line` body section**

In `_ds_process_line`, just after the same-line adjacent string fold call:

```awk
  # Same-line adjacent string literal folding
  line = _ds_fold_adjacent_strings_inline(line)
```

Add immediately after:

```awk
  # Fragment interpolation: expand #{...} inside safe.html.fragment("...") arg
  if (line ~ /safe\.html\.fragment\(/) {
    _DS_last_interp_untrusted = 0
    line = _ds_expand_fragment_interp(line, lineno)
  }
  # Normal string interpolation: expand #{...} in remaining strings → sprintf(...)
  if (line ~ /#{/) {
    _DS_last_interp_untrusted = 0
    line = _ds_expand_interp(line, lineno)
  }
```

- [ ] **Step 2: Add the same to `_ds_flush_string_fold`**

In `_ds_flush_string_fold`, just after `synthetic_line = _ds_fold_adjacent_strings_inline(synthetic_line)`:

```awk
  if (synthetic_line ~ /safe\.html\.fragment\(/) {
    _DS_last_interp_untrusted = 0
    synthetic_line = _ds_expand_fragment_interp(synthetic_line, fold_lineno)
  }
  if (synthetic_line ~ /#{/) {
    _DS_last_interp_untrusted = 0
    synthetic_line = _ds_expand_interp(synthetic_line, fold_lineno)
  }
```

- [ ] **Step 3: Propagate Untrusted type for sprintf interpolation results in `desugar_let.awk`**

When `_ds_expand_interp` produces a `sprintf(...)` that involved Untrusted expressions, the let variable type should be `Untrusted<Str>` not `Str`.

In `dsl/desugar_let.awk`, inside `_ds_let_transform` where it calls `_ds_infer_type(rhs)`, add a special case for sprintf results after interpolation:

Find the section that assigns `_DS_VAR_TYPES` for a let binding (around line 170-176). After inferring the type, override if `_DS_last_interp_untrusted` is set:

```awk
# After: _DS_VAR_TYPES[_DS_func_name, varname] = inferred
# Add:
if (_DS_last_interp_untrusted && inferred == "Str") {
    _DS_VAR_TYPES[_DS_func_name, varname] = "Untrusted<Str>"
    _DS_last_interp_untrusted = 0
}
```

Note: `_DS_last_interp_untrusted` is reset after each interpolation call in `_ds_process_line`.

- [ ] **Step 4: Initialize `_DS_last_interp_untrusted` in `_ds_init`**

Find `_ds_init` in `dsl/desugar_state.awk`:

```awk
function _ds_init() {
    ...
```

Add: `_DS_last_interp_untrusted = 0`

- [ ] **Step 5: Commit skeleton (even before tests pass)**

```bash
git add dsl/desugar.awk dsl/desugar_let.awk dsl/desugar_state.awk
git commit -m "feat(dsl): hook string interpolation into desugar pipeline"
```

---

### Task 8: Add `safe.html.fragment` literal-Str special case in `dsl/typecheck.awk`

**Background:** `safe.html.fragment("<p>", safe::dispatch("html.escape", t), "</p>")` — the literal `"<p>"` has inferred type `"Str"`. But `HtmlPart` alias doesn't include `Str`. We allow literal strings as a special case for this function only.

**Files:**
- Modify: `dsl/typecheck.awk`

- [ ] **Step 1: Add literal-Str exception in `_ds_typecheck_call`**

In `_ds_typecheck_call`, inside the per-argument loop, before (or instead of) the error print for `safe.html.fragment`, add:

```awk
        # safe.html.fragment: literal string args are trusted static HTML chunks
        if (path == "safe.html.fragment" && actual == "Str" && \
            split_args[i] ~ /^"[^"]*"$/) {
            continue  # literal string: allowed
        }
```

Insert this right after `actual = _ds_infer_type(split_args[i])` and before `if (actual == "" || type::accepts(expected, actual)) continue`.

Full modified block:

```awk
        actual = _ds_infer_type(split_args[i])
        # safe.html.fragment: literal string args are trusted static HTML chunks
        if (path == "safe.html.fragment" && actual == "Str" && \
            split_args[i] ~ /^"[^"]*"$/) {
            continue
        }
        if (actual == "" || type::accepts(expected, actual)) continue
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " argument " i " expects " expected ", got " actual > "/dev/stderr"
        _DS_had_error = 1
```

- [ ] **Step 2: Commit**

```bash
git add dsl/typecheck.awk
git commit -m "fix(dsl): allow literal Str args in safe.html.fragment type check"
```

---

### Task 9: Write interpolation tests

**Files:**
- Create: `tests/unit/dsl/string_interpolation_basic/`
- Create: `tests/unit/dsl/string_interpolation_multiple/`
- Create: `tests/unit/dsl/string_interpolation_untrusted_propagates/`
- Create: `tests/unit/dsl/string_interpolation_result_error/`
- Create: `tests/unit/dsl/safe_fragment_interpolation_escape_ok/`
- Create: `tests/unit/dsl/safe_fragment_interpolation_raw_untrusted_error/`

- [ ] **Step 1: `string_interpolation_basic`**

`tests/unit/dsl/string_interpolation_basic/input.awk`:
```awk
function handler() -> Response {
  let name: Str = "hawk"
  let msg = "hello #{name}!"
  return ctx.res.text(msg)
}
```

`tests/unit/dsl/string_interpolation_basic/expected.awk`:
```awk
function handler(    name, msg) {
  name = "hawk"
  msg = sprintf("%s%s%s", "hello ", name, "!")
  return ctx::dispatch("res.text", msg)
}
```

- [ ] **Step 2: `string_interpolation_multiple`**

`tests/unit/dsl/string_interpolation_multiple/input.awk`:
```awk
function handler() -> Response {
  let id: Str = "42"
  let title: Str = "Buy milk"
  let msg = "todo #{id}: #{title}"
  return ctx.res.text(msg)
}
```

`tests/unit/dsl/string_interpolation_multiple/expected.awk`:
```awk
function handler(    id, title, msg) {
  id = "42"
  title = "Buy milk"
  msg = sprintf("%s%s%s%s%s", "todo ", id, ": ", title, "")
  return ctx::dispatch("res.text", msg)
}
```

- [ ] **Step 3: `string_interpolation_untrusted_propagates`**

`tests/unit/dsl/string_interpolation_untrusted_propagates/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let msg = "title: #{raw}"
  return ctx.res.text(msg)
}
```

`tests/unit/dsl/string_interpolation_untrusted_propagates/expected.awk`:
```awk
function handler(    _ds_tc_1, raw, msg) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  msg = sprintf("%s%s%s", "title: ", raw, "")
  return ctx::dispatch("res.text", msg)
}
```

(Note: `ctx.res.text` accepts `Str|Untrusted<Str>`, so msg: Untrusted<Str> is valid here.)

- [ ] **Step 4: `string_interpolation_result_error`**

`tests/unit/dsl/string_interpolation_result_error/input.awk`:
```awk
function handler() -> Response {
  let title = ctx.req.form("title")
  return ctx.res.text("title: #{title}")
}
```

`tests/unit/dsl/string_interpolation_result_error/expected_stderr`:
```
cannot interpolate sealed Result<Untrusted<Str>, ParseError>; use ?= or match first
```

`tests/unit/dsl/string_interpolation_result_error/expected_exit`:
```
1
```

- [ ] **Step 5: `safe_fragment_interpolation_escape_ok`**

`tests/unit/dsl/safe_fragment_interpolation_escape_ok/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let frag = safe.html.fragment("<p>#{raw |> safe.html.escape()}</p>")
  return ctx.res.html(frag)
}
```

`tests/unit/dsl/safe_fragment_interpolation_escape_ok/expected.awk`:
```awk
function handler(    _ds_tc_1, raw, _ds_p_1, frag) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  frag = safe::dispatch("html.fragment", "<p>", _ds_p_1, "</p>")
  return ctx::dispatch("res.html", frag)
}
```

- [ ] **Step 6: `safe_fragment_interpolation_raw_untrusted_error`**

`tests/unit/dsl/safe_fragment_interpolation_raw_untrusted_error/input.awk`:
```awk
function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return safe.html.fragment("<p>#{raw}</p>") |> ctx.res.html()
}
```

`tests/unit/dsl/safe_fragment_interpolation_raw_untrusted_error/expected_stderr`:
```
safe.html.fragment interpolation expects HtmlPart, got Untrusted<Str>
```

`tests/unit/dsl/safe_fragment_interpolation_raw_untrusted_error/expected_exit`:
```
1
```

- [ ] **Step 7: Run all new tests**

```bash
make test-dsl 2>&1 | grep -E "string_interpolation|safe_fragment"
```

Expected: all 6 tests PASS.

- [ ] **Step 8: Run full suite to check no regressions**

```bash
make test-dsl 2>&1 | grep FAIL
```

Expected: no failures.

- [ ] **Step 9: Commit**

```bash
git add tests/unit/dsl/string_interpolation_basic/ \
        tests/unit/dsl/string_interpolation_multiple/ \
        tests/unit/dsl/string_interpolation_untrusted_propagates/ \
        tests/unit/dsl/string_interpolation_result_error/ \
        tests/unit/dsl/safe_fragment_interpolation_escape_ok/ \
        tests/unit/dsl/safe_fragment_interpolation_raw_untrusted_error/
git commit -m "test(dsl): add string interpolation and safe.html.fragment interpolation tests"
```

---

### Task 10: Migrate `app.awk` to `safe.*` namespace

**Files:**
- Modify: `app.awk`

- [ ] **Step 1: Replace `html_raw` calls**

In `app.awk`:

```awk
# Before (todo_list_html):
return ctx.res.html(html_raw(out))

# After:
return ctx.res.html(safe.html.raw(out))
```

```awk
# Before (todo_add, two occurrences):
return ctx.res.html(html_raw(_todo_tr(row["id"], row["title"])))
return ctx.res.html(html_raw(""))

# After:
return ctx.res.html(safe.html.raw(_todo_tr(row["id"], row["title"])))
return ctx.res.html(safe.html.raw(""))
```

- [ ] **Step 2: Replace `escape_html` calls in `_todo_tr`**

The function `_todo_tr` currently:
```awk
function _todo_tr(id: Str, title: Str) -> Str {
  return sprintf( \
    "...",
    escape_html(title), escape_html(id))
}
```

Change to use `safe.html.escape` and `safe.attr.escape`, and update return type to `HtmlFragment` (wrapping the sprintf result in `safe.html.raw`):

```awk
function _todo_tr(id: Str, title: Str) -> HtmlFragment {
  return safe.html.raw(sprintf( \
    "<tr class=\"group border-b border-zinc-800/60 last:border-0\">" \
      "<td class=\"py-3 pr-4 text-sm text-zinc-200\">%s</td>" \
      "<td class=\"py-3 text-right\">" \
        "<button" \
          " hx-delete=\"/todos/%s\"" \
          " hx-target=\"closest tr\"" \
          " hx-swap=\"outerHTML\"" \
          " class=\"text-zinc-600 hover:text-red-400 text-base leading-none" \
            " opacity-0 group-hover:opacity-100 transition-all duration-150 cursor-pointer\"" \
        ">&#x2715;</button>" \
      "</td>" \
    "</tr>", \
    safe.html.escape(title), safe.attr.escape(id)))
}
```

Also update calls to `ctx.res.html(html_raw(_todo_tr(...)))` — since `_todo_tr` now returns `HtmlFragment`, the `safe.html.raw` wrapper on the call site is no longer needed:

```awk
# todo_list_html:
return ctx.res.html(safe.html.raw(out))   # out is still Str concatenation of _todo_tr() results

# todo_add:
return ctx.res.html(_todo_tr(row["id"], row["title"]))   # direct, since _todo_tr returns HtmlFragment
```

Wait — `out` in `todo_list_html` accumulates `_todo_tr(...)` results as Str concatenation. Since `_todo_tr` now returns `HtmlFragment` (which at runtime is a plain Str), this still works at runtime. But type-wise, `out` is declared as `Str`. We need to change the accumulation approach.

Simplest: keep `out: Str` as a runtime container, wrap at the end:

```awk
function todo_list_html() -> Response {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let out: Str = ""
  let i: Int
  for (i = 1; i <= n; i++) {
    out = out _todo_tr(rows[i, "id"], rows[i, "title"])
  }
  return ctx.res.html(safe.html.raw(out))
}
```

`_todo_tr` still returns `HtmlFragment`. Assigning to `out: Str` loses the brand — that's why `safe.html.raw(out)` is still needed at the end. This pattern is acceptable per the spec's `safe.html.raw` as an escape hatch for pre-built trusted HTML.

- [ ] **Step 3: Desugar app.awk and verify no errors**

```bash
gawk -f dsl/desugar.awk app.awk 2>&1
```

Expected: no `dsl error:` lines, clean AWK output.

- [ ] **Step 4: Run full test suite**

```bash
make test 2>&1 | tail -20
```

Expected: all tests pass, including e2e.

- [ ] **Step 5: Commit**

```bash
git add app.awk
git commit -m "feat(app): migrate escape_html/html_raw to safe.html.escape/safe.html.raw/safe.attr.escape"
```

---

### Task 11: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update Safe HTML output section**

Find the existing `### Safe HTML output` section (or similar) and replace with:

```markdown
### Safe HTML output

Hawk does not allow raw strings to be sent directly to HTML sinks.

```hawk
let title ?= ctx.req.form("title")
return title |> ctx.res.html()   # error: got Untrusted<Str>
```

Use `safe.html.escape()` to produce `HtmlEscapedStr`:

```hawk
let title ?= ctx.req.form("title")
let safe = title |> safe.html.escape()
return ctx.res.html(safe)
```

For trusted pre-built HTML, use `safe.html.raw()` explicitly:

```hawk
return ctx.res.html(safe.html.raw("<p>Hello</p>"))
```

`safe.html.raw()` does **not** escape its argument. Use only for strings you already trust.

For attribute values, use `safe.attr.escape()`:

```hawk
let id ?= ctx.req.param("id")
let attr_id = id |> safe.attr.escape()
```
```

- [ ] **Step 2: Update `classify:` documentation**

Find the section describing `transform`, `validator`, etc. and update:

```markdown
| classify    | Description |
|---|---|
| `transform` | Accepts `Untrusted<T>` input; propagates `Untrusted` to output. Example: `trim(Untrusted<Str>) -> Untrusted<Str>` |
| `validator` | Checks a predicate; returns `Result<Untrusted<Refined<T>>, E>`. Does not remove `Untrusted`. |
| `sanitizer` | Converts a value into a Safe / Brand type. Example: `safe.html.escape(Untrusted<Str>) -> HtmlEscapedStr` |
| `trusted`   | Asserts a value is already safe. Example: `safe.html.raw(Str) -> HtmlFragment` |
| `builder`   | Builds a Safe / Brand value from safe parts. Example: `safe.html.fragment(...) -> HtmlFragment` |
| `sink`      | Consumes Safe / Brand values. Example: `ctx.res.html(HtmlEscapedStr \| HtmlFragment) -> Response` |
```

- [ ] **Step 3: Add string interpolation section**

```markdown
### String interpolation

Use `#{...}` inside double-quoted strings:

```hawk
let name: Str = "hawk"
let msg = "hello #{name}!"   # msg: Str
```

Interpolating an `Untrusted<Str>` value propagates `Untrusted` to the result:

```hawk
let raw ?= ctx.req.form("title")
let msg = "title: #{raw}"    # msg: Untrusted<Str>
return ctx.res.text(msg)     # ok: ctx.res.text accepts Untrusted<Str>
```

`Result` and `Option` values cannot be interpolated directly — unwrap them first with `?=` or `match`.

For HTML construction, use `safe.html.fragment` with explicit `safe.html.escape`:

```hawk
let raw ?= ctx.req.form("title")
return safe.html.fragment("<p>#{raw |> safe.html.escape()}</p>")
  |> ctx.res.html()
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update Safe HTML and classify sections for safe.* namespace and interpolation"
```

---

### Task 12: Final verification

- [ ] **Step 1: Run full test suite**

```bash
make test 2>&1
```

Expected: all tests pass (unit, dsl, e2e).

- [ ] **Step 2: Verify acceptance conditions**

```bash
# 1. escape_html is unknown
echo 'function f() { return escape_html("x") }' | gawk -f dsl/desugar.awk /dev/stdin 2>&1 | grep "unknown function escape_html"

# 2. html_raw is unknown
echo 'function f() { return html_raw("x") }' | gawk -f dsl/desugar.awk /dev/stdin 2>&1 | grep "unknown function html_raw"

# 3-5. safe.* sig check
make test-dsl 2>&1 | grep -E "safe_namespace_(escape|raw|attr)"

# 8. interpolation desugar
echo 'function f() { let n: Str = "x"; let m = "hi #{n}" }' | gawk -f dsl/desugar.awk /dev/stdin 2>&1 | grep sprintf

# All tests
make test-dsl 2>&1 | grep -c PASS
```

- [ ] **Step 3: Grep for any remaining `escape_html` or `html_raw` in DSL-facing code**

```bash
grep -rn "escape_html\|html_raw" app.awk dsl/ tests/unit/dsl/ | grep -v "old_escape\|old_raw\|expected_stderr"
```

Expected: no matches.

- [ ] **Step 4: Final commit if any stray fixes needed**

```bash
make test 2>&1 | tail -5
```

---

## Self-Review Notes

- Task 3 Step 2: `_DS_FUNC_CLASS[fname]` with dotted fname works because sig.awk sets `_DS_FUNC_CLASS["safe.html.escape"] = "sanitizer"`. ✓
- Task 6: `_ds_expand_fragment_interp` regex `safe\.html\.fragment\("([^"]*)"\)` doesn't handle escaped quotes inside the string. Spec examples don't use escaped quotes in fragment args, so acceptable for now.
- Task 9 Step 5 expected output: The pipe `raw |> safe.html.escape()` inside `#{...}` is desugared by `_ds_expand_fragment_interp` to `safe.html.fragment("<p>", raw |> safe.html.escape(), "</p>")`, then pipe transform lifts it to `_ds_p_1 = safe::dispatch("html.escape", raw)`. The fragment call becomes `safe::dispatch("html.fragment", "<p>", _ds_p_1, "</p>")`. Check exact temp var numbering against actual output if test fails.
- Task 10: `_todo_tr` returns `HtmlFragment` but is concatenated into `out: Str`. At runtime, AWK doesn't enforce types, so `out = out _todo_tr(...)` works. The final `safe.html.raw(out)` re-asserts trust. This is the acceptable escape-hatch pattern documented in the spec.
