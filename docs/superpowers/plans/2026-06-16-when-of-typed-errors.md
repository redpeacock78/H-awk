# when...of Typed Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `match...of` with `when...of`, change ADT encoding to support typed error arms (`ng e: TypeName:`), and add `type X = Error` constructor generation.

**Architecture:** Two sequential phases — Phase 1 builds the runtime foundation (new ADT encoding, `when` rename, multi-arm ng state machine, `type X = Error` desugaring) and is verified with `make test-dsl` before Phase 2 (union error type exhaustiveness checking) begins. The DSL desugar pipeline (`dsl/desugar.awk`) is a text preprocessor; ADT functions live in `dsl/adt.awk` as runtime helpers included by `hawk.awk`.

**Tech Stack:** gawk 5.0+, awk `@include`, `make test-dsl` for unit tests (`tests/unit/dsl/run.sh`)

---

## File Map

| File | Change |
|------|--------|
| `dsl/adt.awk` | **New** — ADT runtime functions with new encoding |
| `core/util.awk` | Remove ADT functions (lines 136–141) |
| `hawk.awk` | Add `@include "dsl/adt.awk"` |
| `core/ctx.awk` | Wrap Result-returning helpers with new encoding; add `req.json` |
| `dsl/desugar_state.awk` | Replace single-ng state with multi-arm array state |
| `dsl/desugar_match.awk` | `match→when`, all new arm patterns, typed ng emit chain |
| `dsl/desugar.awk` | Add `type X = Error` detection in non-function path |
| `tests/unit/dsl/match_*/input.awk` | `match` → `when` (6 files) |
| `tests/unit/dsl/match_missing_branch/expected_stderr` | Update error message |
| `tests/unit/dsl/when_ok_nobind/` | **New** test |
| `tests/unit/dsl/when_some_nobind/` | **New** test |
| `tests/unit/dsl/when_default_bind/` | **New** test |
| `tests/unit/dsl/when_typed_ng_single/` | **New** test |
| `tests/unit/dsl/when_typed_ng_multi/` | **New** test |
| `tests/unit/dsl/type_error_decl/` | **New** test |
| `app.awk` | `match` → `when` |

---

## Phase 1

### Task 1: Create `dsl/adt.awk` and migrate from `core/util.awk`

**Files:**
- Create: `dsl/adt.awk`
- Modify: `core/util.awk` (remove lines 136–141)
- Modify: `hawk.awk` (add include)

- [ ] **Step 1: Write failing test (manual)**

  Run the test suite now to capture the baseline (all tests pass):
  ```bash
  make test-dsl
  ```
  Expected: all current tests PASS.

- [ ] **Step 2: Create `dsl/adt.awk`**

  ```awk
  # SPDX-License-Identifier: MIT
  # dsl/adt.awk -- Result/Option ADT runtime functions
  #
  # Result encoding:
  #   ok  = "ok\x1F" value
  #   ng  = "ng\x1F" TypeName  or  "ng\x1F" TypeName "\x1F" msg
  # Option encoding: unchanged (non-empty = some, "" = none)

  function result_ok(v)          { return substr(v, 1, 3) == "ok\x1F" }
  function result_val(v)         { return substr(v, 4) }
  function result_ok_make(val)   { return "ok\x1F" val }
  function result_ng(type, msg)  {
    return "ng\x1F" type (msg != "" ? "\x1F" msg : "")
  }
  function result_err_type(v,  a) { split(substr(v, 4), a, "\x1F"); return a[1] }
  function result_err(v)         { return substr(v, 4) }

  function option_some(v) { return v != "" }
  function option_val(v)  { return v }
  ```

- [ ] **Step 3: Remove ADT functions from `core/util.awk`**

  Delete lines 136–141 (comment + 5 function definitions):
  ```
  # DSL Result/Option ADT runtime (scalar encoding: "" = ng/none, non-empty = ok/some)
  function result_ok(v)   { return v != "" }
  function result_val(v)  { return v }
  function result_err(v)  { return v }
  function option_some(v) { return v != "" }
  function option_val(v)  { return v }
  ```

- [ ] **Step 4: Add `dsl/adt.awk` to `hawk.awk`**

  Add after `@include "core/util.awk"`:
  ```awk
  @include "core/util.awk"
  @include "dsl/adt.awk"
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add dsl/adt.awk core/util.awk hawk.awk
  git commit -m "feat(adt): create dsl/adt.awk with new ok/ng encoding, migrate from core/util.awk"
  ```

---

### Task 2: Update `core/ctx.awk` Result-returning functions

The functions `query`, `param`, `get_header`, `body`, `req_form` currently return raw strings. They must return the new encoded Result. Also add `req.json`.

**Files:**
- Modify: `core/ctx.awk`

- [ ] **Step 1: Update the five existing Result functions**

  Replace:
  ```awk
  function query(key)       { return ctx::req["query:" key] }
  function param(key)       { return ctx::req["params:" key] }
  function get_header(key)  { return ctx::req["header:" awk::to_lower(key)] }
  function body()           { return ctx::req["body"] }
  ...
  function req_form(key)   { return req["form:" key] }
  ```

  With:
  ```awk
  function query(key,       v) { v = ctx::req["query:" key];               return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "missing " key) }
  function param(key,       v) { v = ctx::req["params:" key];              return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "missing " key) }
  function get_header(key,  v) { v = ctx::req["header:" awk::to_lower(key)]; return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "missing " key) }
  function body(            v) { v = ctx::req["body"];                      return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "empty body") }
  function req_form(key,    v) { v = ctx::req["form:" key];                return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "missing " key) }
  ```

- [ ] **Step 2: Add `req_json` function and register it**

  Add after `req_form`:
  ```awk
  function req_json(         v) { v = ctx::req["body"];                    return v != "" ? awk::result_ok_make(v) : awk::result_ng("ParseError", "empty body") }
  ```

  In the `BEGIN` block, add:
  ```awk
  _CTX_ROUTES["req.json"]    = "ctx::req_json";  _CTX_ARITY["req.json"]    = 0
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add core/ctx.awk
  git commit -m "fix(ctx): wrap Result-returning functions with new ADT encoding, add req.json"
  ```

---

### Task 3: Refactor `dsl/desugar_state.awk` for multi-arm ng

Replace single `_DS_match_ng_var` / `_DS_match_has_ng` / `_DS_match_ng_count` / `_DS_match_ng_body` with an array of ng arms.

**Files:**
- Modify: `dsl/desugar_state.awk`

- [ ] **Step 1: Replace the match state block in `_ds_init`**

  Remove these lines from `_ds_init`:
  ```awk
  _DS_match_ok_var   = ""
  _DS_match_ng_var   = ""
  _DS_match_branch   = ""
  _DS_match_has_ng   = 0
  _DS_match_ok_count = 0
  _DS_match_ng_count = 0
  delete _DS_match_ok_body
  delete _DS_match_ng_body
  ```

  Replace with:
  ```awk
  _DS_match_ok_var     = ""
  _DS_match_branch     = ""
  _DS_match_ok_count   = 0
  _DS_match_ng_arms    = 0
  _DS_match_cur_ng_arm = 0
  delete _DS_match_ok_body
  delete _DS_match_ng_body
  delete _DS_match_ng_type
  delete _DS_match_ng_var_name
  delete _DS_match_ng_is_default
  delete _DS_match_ng_body_count
  ```

  Also add to the `_ds_init` `delete` section (for Phase 2):
  ```awk
  delete _DS_ERROR_TYPES
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add dsl/desugar_state.awk
  git commit -m "refactor(desugar): replace single-ng state with multi-arm array for typed ng support"
  ```

---

### Task 4: Rewrite `dsl/desugar_match.awk`

Rename `match→when`, add all new arm patterns, rewrite emit for multi-arm ng.

**Files:**
- Modify: `dsl/desugar_match.awk`

- [ ] **Step 1: Rename `match` → `when` in `_ds_match_starts`**

  Replace:
  ```awk
  return match(line, /^([[:space:]]*)match[[:space:]]+(.+)[[:space:]]+of[[:space:]]*$/, m)
  ```
  With:
  ```awk
  return match(line, /^([[:space:]]*)when[[:space:]]+(.+)[[:space:]]+of[[:space:]]*$/, m)
  ```

- [ ] **Step 2: Replace `_ds_match_collect` arm detection block**

  Replace the entire sequence of `if (match(...))` arm checks with the following (order matters — most-specific patterns first):

  ```awk
  function _ds_match_collect(line, lineno,    m, i) {
    # ok name:
    if (match(line, /^[[:space:]]*ok[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      _DS_match_ok_var = m[1]; _DS_match_branch = "ok"; return ""
    }
    # ok:
    if (line ~ /^[[:space:]]*ok:[[:space:]]*$/) {
      _DS_match_ok_var = ""; _DS_match_branch = "ok"; return ""
    }
    # some name:
    if (match(line, /^[[:space:]]*some[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      _DS_match_ok_var = m[1]; _DS_match_branch = "some"; return ""
    }
    # some:
    if (line ~ /^[[:space:]]*some:[[:space:]]*$/) {
      _DS_match_ok_var = ""; _DS_match_branch = "some"; return ""
    }
    # none:
    if (line ~ /^[[:space:]]*none:[[:space:]]*$/) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = ""; _DS_match_ng_var_name[i] = ""
      _DS_match_ng_is_default[i] = 1; _DS_match_branch = "ng"; return ""
    }
    # ng e: TypeName:  (typed, bind — check before plain ng name:)
    if (match(line, /^[[:space:]]*ng[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = m[2]; _DS_match_ng_var_name[i] = m[1]
      _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
    }
    # ng TypeName:  (typed, no bind)
    if (match(line, /^[[:space:]]*ng[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = m[1]; _DS_match_ng_var_name[i] = ""
      _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
    }
    # ng name:  (untyped, bind)
    if (match(line, /^[[:space:]]*ng[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = ""; _DS_match_ng_var_name[i] = m[1]
      _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
    }
    # ng:  (untyped, no bind)
    if (line ~ /^[[:space:]]*ng:[[:space:]]*$/) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = ""; _DS_match_ng_var_name[i] = ""
      _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
    }
    # default name:  (catch-all, bind)
    if (match(line, /^[[:space:]]*default[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = ""; _DS_match_ng_var_name[i] = m[1]
      _DS_match_ng_is_default[i] = 1; _DS_match_branch = "ng"; return ""
    }
    # default:  (catch-all, no bind)
    if (line ~ /^[[:space:]]*default:[[:space:]]*$/) {
      i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
      _DS_match_ng_type[i] = ""; _DS_match_ng_var_name[i] = ""
      _DS_match_ng_is_default[i] = 1; _DS_match_branch = "ng"; return ""
    }
    # end
    if (line ~ /^[[:space:]]*end[[:space:]]*$/) {
      _DS_in_match = 0; _ds_match_emit(lineno); return ""
    }
    # Body line — buffer under current branch
    if (_DS_match_branch == "ok" || _DS_match_branch == "some") {
      _DS_match_ok_body[++_DS_match_ok_count] = line
    } else {
      i = _DS_match_cur_ng_arm
      _DS_match_ng_body[i, ++_DS_match_ng_body_count[i]] = line
    }
    return ""
  }
  ```

- [ ] **Step 3: Rewrite `_ds_match_emit`**

  Replace the entire `_ds_match_emit` function with:

  ```awk
  function _ds_match_emit(lineno,    tmpvar, type_t, check_fn, val_fn, err_fn, i, j, arm_type, arm_var, arm_default) {
    if (_DS_match_ng_arms == 0) {
      print "dsl error: " _DS_src_file ":" lineno \
        ": when...of missing ng/none/default branch" > "/dev/stderr"
      _DS_had_error = 1
      _ds_match_reset()
      return
    }

    _DS_mc_count++
    tmpvar = "_ds_mc_" _DS_mc_count
    if (_DS_in_function) {
      _DS_let_locals[++_DS_let_count] = tmpvar
      if (_DS_match_ok_var != "") _DS_let_locals[++_DS_let_count] = _DS_match_ok_var
      # Deduplicate: multiple arms may bind to the same var name (e.g., two arms both use "e")
      delete _ds_emit_added_vars
      for (i = 1; i <= _DS_match_ng_arms; i++) {
        if (_DS_match_ng_var_name[i] != "" && !(_DS_match_ng_var_name[i] in _ds_emit_added_vars)) {
          _DS_let_locals[++_DS_let_count] = _DS_match_ng_var_name[i]
          _ds_emit_added_vars[_DS_match_ng_var_name[i]] = 1
        }
      }
    }

    type_t = _ds_infer_type(_DS_match_expr)
    if (type_t ~ /^Option</) {
      check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
    } else {
      check_fn = "result_ok"; val_fn = "result_val"; err_fn = "result_err"
    }

    if (_DS_in_function) {
      if (_DS_match_ok_var != "")
        _DS_VAR_TYPES[_DS_func_name, _DS_match_ok_var] = _ds_inner_type(type_t)
      for (i = 1; i <= _DS_match_ng_arms; i++) {
        if (_DS_match_ng_var_name[i] != "" && type_t ~ /^Result</)
          _DS_VAR_TYPES[_DS_func_name, _DS_match_ng_var_name[i]] = _ds_result_err_type(type_t)
      }
    }

    _DS_body_buf[++_DS_body_count] = _DS_match_indent tmpvar " = " _ds_dot_transform(_DS_match_expr)
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "if (" check_fn "(" tmpvar ")) {"
    if (_DS_match_ok_var != "")
      _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " _DS_match_ok_var " = " val_fn "(" tmpvar ")"
    for (j = 1; j <= _DS_match_ok_count; j++)
      _ds_match_process_body(_DS_match_ok_body[j], lineno)

    for (i = 1; i <= _DS_match_ng_arms; i++) {
      arm_type    = _DS_match_ng_type[i]
      arm_var     = _DS_match_ng_var_name[i]
      arm_default = _DS_match_ng_is_default[i]

      if (arm_type != "" && !arm_default) {
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "} else if (result_err_type(" tmpvar ") == \"" arm_type "\") {"
      } else {
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "} else {"
      }

      if (arm_var != "" && err_fn != "")
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " arm_var " = " err_fn "(" tmpvar ")"

      for (j = 1; j <= _DS_match_ng_body_count[i]; j++)
        _ds_match_process_body(_DS_match_ng_body[i, j], lineno)
    }

    _DS_body_buf[++_DS_body_count] = _DS_match_indent "}"
    _ds_match_reset()
  }
  ```

- [ ] **Step 4: Add `_ds_match_reset` helper (called at end of emit and on error)**

  Add before `_ds_match_emit`:
  ```awk
  function _ds_match_reset() {
    _DS_match_ok_count   = 0
    _DS_match_ok_var     = ""
    _DS_match_branch     = ""
    _DS_match_expr       = ""
    _DS_match_indent     = ""
    _DS_match_ng_arms    = 0
    _DS_match_cur_ng_arm = 0
    delete _DS_match_ok_body
    delete _DS_match_ng_body
    delete _DS_match_ng_type
    delete _DS_match_ng_var_name
    delete _DS_match_ng_is_default
    delete _DS_match_ng_body_count
  }
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add dsl/desugar_match.awk
  git commit -m "feat(dsl): when...of rename, multi-arm typed ng, ok:/some:/default name: arms"
  ```

---

### Task 5: Add `type X = Error` processing to `dsl/desugar.awk`

**Files:**
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Add detection in the non-function path**

  In `_ds_process_line`, after the `_ds_is_func_def` check (around line 74, after the `return` at end of that block), add before the `pipe_result = ...` line:

  ```awk
  # type X = Error → emit constructor function + register error type
  if (match(line, /^([[:space:]]*)type[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*Error[[:space:]]*$/, _ds_type_m)) {
    _DS_ERROR_TYPES[_ds_type_m[2]] = 1
    print _ds_type_m[1] "function " _ds_type_m[2] "(msg) { return result_ng(\"" _ds_type_m[2] "\", msg) }"
    return
  }
  ```

  Note: `_ds_type_m` should be added as a local parameter to `_ds_process_line` (the function signature shows `match_m` — add `_ds_type_m` alongside it).

- [ ] **Step 2: Commit**

  ```bash
  git add dsl/desugar.awk
  git commit -m "feat(dsl): type X = Error generates constructor function via result_ng"
  ```

---

### Task 6: Update existing test fixtures

**Files:**
- Modify: `app.awk`, and all `tests/unit/dsl/match_*/input.awk` (rename `match` → `when`)
- Modify: `tests/unit/dsl/match_missing_branch/expected_stderr`

- [ ] **Step 1: Rename `match` → `when` in all input.awk files**

  ```bash
  sed -i '' 's/^  match /  when /g; s/^match /when /g' \
    tests/unit/dsl/match_result_basic/input.awk \
    tests/unit/dsl/match_result_default/input.awk \
    tests/unit/dsl/match_option_basic/input.awk \
    tests/unit/dsl/match_missing_branch/input.awk \
    tests/unit/dsl/match_arm_array_type_trust_ok/input.awk \
    tests/unit/dsl/match_arm_array_type_error/input.awk \
    app.awk
  ```

  Verify each file now has `when` not `match`:
  ```bash
  grep -l "match.*of" tests/unit/dsl/match_*/input.awk app.awk
  ```
  Expected: no output (none found).

- [ ] **Step 2: Update `match_missing_branch/expected_stderr`**

  The error message changes from `match on Result missing ng or default branch` to `when...of missing ng/none/default branch`.

  ```bash
  echo "when...of missing ng/none/default branch" > tests/unit/dsl/match_missing_branch/expected_stderr
  ```

- [ ] **Step 3: Run DSL tests to verify existing tests pass**

  ```bash
  make test-dsl
  ```
  Expected: all tests PASS.

- [ ] **Step 4: Commit**

  ```bash
  git add tests/unit/dsl/ app.awk
  git commit -m "fix(tests): rename match→when in test fixtures, update error message"
  ```

---

### Task 7: Add new DSL test cases

**Files:**
- Create: 6 new test directories under `tests/unit/dsl/`

- [ ] **Step 1: `when_ok_nobind` — `ok:` without bind variable**

  ```bash
  mkdir tests/unit/dsl/when_ok_nobind
  ```

  `tests/unit/dsl/when_ok_nobind/input.awk`:
  ```awk
  function handler() {
    when ctx.req.json() of
      ok:
        return ctx.res.status(200)
      default:
        return ctx.res.status(400)
    end
  }
  ```

  `tests/unit/dsl/when_ok_nobind/expected.awk`:
  ```awk
  function handler(    _ds_mc_1) {
    _ds_mc_1 = ctx::dispatch("req.json")
    if (result_ok(_ds_mc_1)) {
      return ctx::dispatch("res.status", 200)
    } else {
      return ctx::dispatch("res.status", 400)
    }
  }
  ```

- [ ] **Step 2: `when_some_nobind` — `some:` without bind variable**

  ```bash
  mkdir tests/unit/dsl/when_some_nobind
  ```

  `tests/unit/dsl/when_some_nobind/input.awk`:
  ```awk
  function handler() {
    when find_item(id) of
      some:
        return ctx.res.status(200)
      none:
        return ctx.res.status(404)
    end
  }
  ```

  `tests/unit/dsl/when_some_nobind/expected.awk`:
  ```awk
  function handler(    _ds_mc_1) {
    _ds_mc_1 = find_item(id)
    if (result_ok(_ds_mc_1)) {
      return ctx::dispatch("res.status", 200)
    } else {
      return ctx::dispatch("res.status", 404)
    }
  }
  ```

- [ ] **Step 3: `when_default_bind` — `default name:` catch-all with bind**

  ```bash
  mkdir tests/unit/dsl/when_default_bind
  ```

  `tests/unit/dsl/when_default_bind/input.awk`:
  ```awk
  function handler() {
    when ctx.req.json() of
      ok body:
        return ctx.res.json(body)
      default e:
        return ctx.res.status(500)
    end
  }
  ```

  `tests/unit/dsl/when_default_bind/expected.awk`:
  ```awk
  function handler(    _ds_mc_1, body, e) {
    _ds_mc_1 = ctx::dispatch("req.json")
    if (result_ok(_ds_mc_1)) {
      body = result_val(_ds_mc_1)
      return ctx::dispatch("res.json", body)
    } else {
      e = result_err(_ds_mc_1)
      return ctx::dispatch("res.status", 500)
    }
  }
  ```

- [ ] **Step 4: `when_typed_ng_single` — single typed `ng e: TypeName:` arm**

  ```bash
  mkdir tests/unit/dsl/when_typed_ng_single
  ```

  `tests/unit/dsl/when_typed_ng_single/input.awk`:
  ```awk
  function handler() {
    when ctx.req.json() of
      ok body:
        return ctx.res.json(body)
      ng e: ParseError:
        return ctx.res.status(400)
      default:
        return ctx.res.status(500)
    end
  }
  ```

  `tests/unit/dsl/when_typed_ng_single/expected.awk`:
  ```awk
  function handler(    _ds_mc_1, body, e) {
    _ds_mc_1 = ctx::dispatch("req.json")
    if (result_ok(_ds_mc_1)) {
      body = result_val(_ds_mc_1)
      return ctx::dispatch("res.json", body)
    } else if (result_err_type(_ds_mc_1) == "ParseError") {
      e = result_err(_ds_mc_1)
      return ctx::dispatch("res.status", 400)
    } else {
      return ctx::dispatch("res.status", 500)
    }
  }
  ```

- [ ] **Step 5: `when_typed_ng_multi` — multiple typed ng arms**

  ```bash
  mkdir tests/unit/dsl/when_typed_ng_multi
  ```

  `tests/unit/dsl/when_typed_ng_multi/input.awk`:
  ```awk
  function handler() {
    when ctx.req.json() of
      ok body:
        return ctx.res.json(body)
      ng e: AuthError:
        return ctx.res.status(401)
      ng e: NotFoundError:
        return ctx.res.status(404)
      default:
        return ctx.res.status(500)
    end
  }
  ```

  `tests/unit/dsl/when_typed_ng_multi/expected.awk`:
  ```awk
  function handler(    _ds_mc_1, body, e) {
    _ds_mc_1 = ctx::dispatch("req.json")
    if (result_ok(_ds_mc_1)) {
      body = result_val(_ds_mc_1)
      return ctx::dispatch("res.json", body)
    } else if (result_err_type(_ds_mc_1) == "AuthError") {
      e = result_err(_ds_mc_1)
      return ctx::dispatch("res.status", 401)
    } else if (result_err_type(_ds_mc_1) == "NotFoundError") {
      e = result_err(_ds_mc_1)
      return ctx::dispatch("res.status", 404)
    } else {
      return ctx::dispatch("res.status", 500)
    }
  }
  ```

- [ ] **Step 6: `type_error_decl` — `type X = Error` generates constructor**

  ```bash
  mkdir tests/unit/dsl/type_error_decl
  ```

  `tests/unit/dsl/type_error_decl/input.awk`:
  ```awk
  type AuthError = Error
  type NotFoundError = Error

  function handler() {
    return ctx.res.status(200)
  }
  ```

  `tests/unit/dsl/type_error_decl/expected.awk`:
  ```awk
  function AuthError(msg) { return result_ng("AuthError", msg) }
  function NotFoundError(msg) { return result_ng("NotFoundError", msg) }
  function handler() {
    return ctx::dispatch("res.status", 200)
  }
  ```

- [ ] **Step 7: Run all DSL tests**

  ```bash
  make test-dsl
  ```
  Expected: ALL tests PASS (old + new).

- [ ] **Step 8: Commit**

  ```bash
  git add tests/unit/dsl/when_ok_nobind/ tests/unit/dsl/when_some_nobind/ \
          tests/unit/dsl/when_default_bind/ tests/unit/dsl/when_typed_ng_single/ \
          tests/unit/dsl/when_typed_ng_multi/ tests/unit/dsl/type_error_decl/
  git commit -m "test(dsl): add when...of new arm forms and type X = Error test cases"
  ```

---

### Task 8: Phase 1 verification checkpoint

- [ ] **Step 1: Run full test suite**

  ```bash
  make test
  ```
  Expected: all unit + DSL + e2e tests pass.

- [ ] **Step 2: Smoke test `type X = Error` + `when` by hand**

  ```bash
  echo 'type AuthError = Error
  function f() {
    when ctx.req.json() of
      ok v:
        return ctx.res.json(v)
      ng e: AuthError:
        return ctx.res.status(401)
      default:
        return ctx.res.status(500)
    end
  }' | gawk -f dsl/desugar.awk /dev/stdin
  ```

  Expected output (after stripping `# line` directives):
  ```awk
  function AuthError(msg) { return result_ng("AuthError", msg) }
  function f(    _ds_mc_1, v, e) {
    _ds_mc_1 = ctx::dispatch("req.json")
    if (result_ok(_ds_mc_1)) {
      v = result_val(_ds_mc_1)
      return ctx::dispatch("res.json", v)
    } else if (result_err_type(_ds_mc_1) == "AuthError") {
      e = result_err(_ds_mc_1)
      return ctx::dispatch("res.status", 401)
    } else {
      return ctx::dispatch("res.status", 500)
    }
  }
  ```

  **If all checks pass, Phase 1 is complete. Proceed to Phase 2.**

---

## Phase 2: Union error type exhaustiveness checking

> Start this phase only after Phase 1 `make test` is fully green.

**Goal:** When a function signature declares `Result<T, AuthError | NotFoundError>`, the `when...of` block's typed ng arms are checked against the declared union members for exhaustiveness.

### Task 9: Add union error type parsing to `dsl/type.awk`

**Files:**
- Modify: `dsl/type.awk`

- [ ] **Step 1: Add `_ds_result_err_union` to extract error type members**

  In `dsl/type.awk`, add a function that parses `Result<T, AuthError | NotFoundError>` and returns an array of error types:

  ```awk
  # _ds_result_err_union(type_str, out_arr)
  # For "Result<T, AuthError | NotFoundError>" → out_arr[1]="AuthError", out_arr[2]="NotFoundError"
  # Returns count of members (0 if not a union or not a Result).
  function _ds_result_err_union(type_str, out_arr,    m, err_part, n) {
    if (!match(type_str, /^Result<[^,]+,[[:space:]]*(.+)>$/, m)) return 0
    err_part = m[1]
    n = split(err_part, out_arr, /[[:space:]]*\|[[:space:]]*/)
    return n
  }
  ```

- [ ] **Step 2: Write failing test (manual)**

  ```bash
  echo 'type AuthError = Error
  function f() -> Result<Str, AuthError | NotFoundError> {
    when ctx.req.json() of
      ok v:
        return ctx.res.json(v)
      ng e: AuthError:
        return ctx.res.status(401)
    end
  }' | gawk -f dsl/desugar.awk /dev/stdin 2>&1
  ```
  Expected: error about missing `NotFoundError` arm (or missing default). Currently: no error (Phase 1 only checks ng exists, not exhaustiveness).

- [ ] **Step 3: Commit type.awk change**

  ```bash
  git add dsl/type.awk
  git commit -m "feat(type): add _ds_result_err_union for union error type parsing"
  ```

---

### Task 10: Add exhaustiveness check in `dsl/desugar_match.awk`

**Files:**
- Modify: `dsl/desugar_match.awk`

- [ ] **Step 1: Add exhaustiveness check in `_ds_match_emit`**

  After the existing `_DS_match_ng_arms == 0` error check, add (inside `_ds_match_emit`, after `type_t` is determined):

  ```awk
  # Exhaustiveness check: if return type is Result<T, E1|E2|...>, verify typed arms cover all members
  # OR a default/untyped ng arm is present.
  if (type_t ~ /^Result</ && _DS_match_ng_arms > 0) {
    delete _ds_union_members
    n_union = _ds_result_err_union(type_t, _ds_union_members)
    if (n_union > 1) {
      # Check if any arm is untyped (default/ng:) → exhaustive by definition
      has_catchall = 0
      for (i = 1; i <= _DS_match_ng_arms; i++)
        if (_DS_match_ng_is_default[i] || _DS_match_ng_type[i] == "") { has_catchall = 1; break }
      if (!has_catchall) {
        # Build set of covered types
        delete _ds_covered
        for (i = 1; i <= _DS_match_ng_arms; i++)
          if (_DS_match_ng_type[i] != "") _ds_covered[_DS_match_ng_type[i]] = 1
        for (i = 1; i <= n_union; i++) {
          if (!(_ds_union_members[i] in _ds_covered)) {
            print "dsl error: " _DS_src_file ":" lineno \
              ": when...of missing arm for " _ds_union_members[i] \
              " (add 'ng e: " _ds_union_members[i] ":' or 'default:')" > "/dev/stderr"
            _DS_had_error = 1
          }
        }
        if (_DS_had_error) { _ds_match_reset(); return }
      }
    }
  }
  ```

- [ ] **Step 2: Add exhaustiveness error test case**

  ```bash
  mkdir tests/unit/dsl/when_typed_ng_exhaustive_error
  ```

  `tests/unit/dsl/when_typed_ng_exhaustive_error/input.awk`:
  ```awk
  type AuthError = Error
  type NotFoundError = Error

  function fetch() -> Result<Str, AuthError | NotFoundError> {
    return AuthError("bad")
  }

  function handler() {
    when fetch() of
      ok v:
        return ctx.res.json(v)
      ng e: AuthError:
        return ctx.res.status(401)
    end
  }
  ```

  `tests/unit/dsl/when_typed_ng_exhaustive_error/expected_stderr`:
  ```
  when...of missing arm for NotFoundError
  ```

- [ ] **Step 3: Run DSL tests**

  ```bash
  make test-dsl
  ```
  Expected: all PASS including the new exhaustiveness error test.

- [ ] **Step 4: Commit**

  ```bash
  git add dsl/desugar_match.awk tests/unit/dsl/when_typed_ng_exhaustive_error/
  git commit -m "feat(dsl): exhaustiveness check for union error types in when...of"
  ```

---

### Task 11: Phase 2 verification

- [ ] **Step 1: Run full test suite**

  ```bash
  make test
  ```
  Expected: ALL tests pass.

- [ ] **Step 2: Smoke test exhaustiveness check passes when arms are complete**

  ```bash
  echo 'type AuthError = Error
  type NotFoundError = Error
  function fetch() -> Result<Str, AuthError | NotFoundError> {
    return AuthError("bad")
  }
  function handler() {
    when fetch() of
      ok v:
        return ctx.res.json(v)
      ng e: AuthError:
        return ctx.res.status(401)
      ng e: NotFoundError:
        return ctx.res.status(404)
    end
  }' | gawk -f dsl/desugar.awk /dev/stdin 2>&1
  ```
  Expected: no errors, valid awk output.

  **Phase 2 complete.**
