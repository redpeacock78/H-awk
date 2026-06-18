# DSL Phase 1: ADT Base64 + Alias Cycle Detection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ADT encoding binary-safe via Base64, and detect circular type aliases at compile time.

**Architecture:** Two independent changes to `dsl/adt.awk` and `dsl/type.awk`. ADT Base64 is a pure runtime change (desugar output unchanged). Alias cycle detection hooks into `dsl/desugar.awk` after each user alias registration.

**Tech Stack:** gawk 5.3.1, AWK arithmetic (no bitwise ops — use integer division and modulo), existing test harness (`make test-dsl`, `make test-unit`).

---

## File Map

- Modify: `dsl/adt.awk` — add `_adt_b64_encode`/`_adt_b64_decode`, update all ADT constructors/accessors
- Modify: `dsl/type.awk` — add `_type_check_alias_cycle(name, lineno, visiting)`
- Modify: `dsl/desugar.awk` — call cycle check after user alias insertion
- Create: `tests/unit/test_adt.awk` — ADT round-trip unit tests
- Modify: `tests/unit/run.awk` — register `test_adt_*` calls
- Create: `tests/unit/dsl/type_alias_cycle_simple/input.awk` — cycle error test
- Create: `tests/unit/dsl/type_alias_cycle_simple/expected_stderr` — expected error
- Create: `tests/unit/dsl/type_alias_cycle_indirect/input.awk` — indirect cycle test
- Create: `tests/unit/dsl/type_alias_cycle_indirect/expected_stderr`

---

## Task 1: ADT round-trip unit test (RED)

Add a failing test that verifies Base64 round-trip for `\x1F`-containing values.

**Files:**
- Create: `tests/unit/test_adt.awk`
- Modify: `tests/unit/run.awk`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_adt.awk`:

```awk
# SPDX-License-Identifier: MIT
function test_adt_result_ok_roundtrip(    r) {
  r = result_ok_make("hello world")
  assert_eq(result_val(r), "hello world", "adt: ok round-trip plain")
}

function test_adt_result_ok_xif_roundtrip(    r) {
  r = result_ok_make("before\x1Fafter")
  assert_eq(result_val(r), "before\x1Fafter", "adt: ok round-trip with \\x1F")
}

function test_adt_result_ng_roundtrip(    r) {
  r = result_ng("AuthError", "bad\x1Fcred")
  assert_eq(result_err_type(r), "AuthError",   "adt: ng type")
  assert_eq(result_err(r),      "bad\x1Fcred", "adt: ng msg round-trip with \\x1F")
}

function test_adt_result_ng_no_msg(    r) {
  r = result_ng("NotFoundError", "")
  assert_eq(result_err_type(r), "NotFoundError", "adt: ng no-msg type")
  assert_eq(result_err(r),      "",              "adt: ng no-msg empty string")
}

function test_adt_option_some_roundtrip(    r) {
  r = option_some_make("val\x1Fwith\x1Fsep")
  assert_true(option_some(r), "adt: some predicate")
  assert_eq(option_val(r), "val\x1Fwith\x1Fsep", "adt: some round-trip with \\x1F")
}

function test_adt_option_none(    r) {
  r = option_none_make()
  assert_true(option_none(r),    "adt: none predicate")
  assert_true(!option_some(r),   "adt: not some")
}
```

- [ ] **Step 2: Register tests in run.awk**

In `tests/unit/run.awk`, add after the last `test_*()` call in the BEGIN block (around line 80):

```awk
  test_adt_result_ok_roundtrip()
  test_adt_result_ok_xif_roundtrip()
  test_adt_result_ng_roundtrip()
  test_adt_result_ng_no_msg()
  test_adt_option_some_roundtrip()
  test_adt_option_none()
```

- [ ] **Step 3: Run and verify tests FAIL**

```bash
make test-unit 2>&1 | tail -20
```

Expected: FAIL on `test_adt_result_ok_xif_roundtrip` and `test_adt_result_ng_roundtrip` (because current implementation does not Base64-encode, so `\x1F`-containing values break extraction).

---

## Task 2: Implement Base64 in adt.awk

**Files:**
- Modify: `dsl/adt.awk`

- [ ] **Step 1: Add Base64 lookup tables to BEGIN block**

Replace the entire `dsl/adt.awk` with:

```awk
# SPDX-License-Identifier: MIT
# dsl/adt.awk -- Result/Option ADT runtime functions
#
# Result encoding (after Base64 fix):
#   ok   = "ok\x1F"  b64(value)
#   ng   = "ng\x1F"  TypeName              (no message)
#         | "ng\x1F" TypeName "\x1F" b64(msg)
# Option encoding:
#   some = "some\x1F" b64(value)
#   none = "none\x1F"

BEGIN {
    _adt_b64_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for (_adt_i = 0; _adt_i < 64; _adt_i++) {
        _adt_c = substr(_adt_b64_alpha, _adt_i + 1, 1)
        _adt_enc[_adt_i] = _adt_c
        _adt_dec[_adt_c] = _adt_i
    }
    for (_adt_i = 0; _adt_i <= 255; _adt_i++)
        _adt_ord[sprintf("%c", _adt_i)] = _adt_i
}

function _adt_b64_encode(s,    i, n, b0, b1, b2, r) {
    n = length(s); r = ""
    if (n == 0) return ""
    for (i = 1; i <= n; i += 3) {
        b0 = _adt_ord[substr(s, i,   1)]
        b1 = (i+1 <= n) ? _adt_ord[substr(s, i+1, 1)] : 0
        b2 = (i+2 <= n) ? _adt_ord[substr(s, i+2, 1)] : 0
        r = r _adt_enc[int(b0/4)] \
              _adt_enc[(b0%4)*16 + int(b1/16)] \
              _adt_enc[(b1%16)*4  + int(b2/64)] \
              _adt_enc[b2%64]
    }
    # Fix padding
    if (n % 3 == 1) { r = substr(r, 1, length(r)-2) "==" }
    if (n % 3 == 2) { r = substr(r, 1, length(r)-1) "="  }
    return r
}

function _adt_b64_decode(s,    i, n, c0, c1, c2, c3, r) {
    n = length(s); r = ""
    if (n == 0) return ""
    for (i = 1; i <= n; i += 4) {
        c0 = _adt_dec[substr(s, i,   1)]
        c1 = _adt_dec[substr(s, i+1, 1)]
        c2 = (substr(s, i+2, 1) == "=") ? 0 : _adt_dec[substr(s, i+2, 1)]
        c3 = (substr(s, i+3, 1) == "=") ? 0 : _adt_dec[substr(s, i+3, 1)]
        r = r sprintf("%c", c0*4 + int(c1/16))
        if (substr(s, i+2, 1) != "=") r = r sprintf("%c", (c1%16)*16 + int(c2/4))
        if (substr(s, i+3, 1) != "=") r = r sprintf("%c", (c2%4)*64  + c3)
    }
    return r
}

function result_ok(v)           { return substr(v, 1, 3) == "ok\x1F" }
function result_val(v)          { return _adt_b64_decode(substr(v, 4)) }
function result_ok_make(val)    { return "ok\x1F" _adt_b64_encode(val) }

function result_ng(type, msg)   {
    return "ng\x1F" type (msg != "" ? "\x1F" _adt_b64_encode(msg) : "")
}
function result_err_type(v,  a) { split(substr(v, 4), a, "\x1F"); return a[1] }
function result_err(v,       a) {
    split(substr(v, 4), a, "\x1F")
    return (length(a) >= 2 && a[2] != "") ? _adt_b64_decode(a[2]) : ""
}

function option_some_make(val)  { return "some\x1F" _adt_b64_encode(val) }
function option_none_make()     { return "none\x1F" }
function option_some(v)         { return substr(v, 1, 5) == "some\x1F" }
function option_none(v)         { return v == "none\x1F" }
function option_val(v)          { return _adt_b64_decode(substr(v, 6)) }
```

- [ ] **Step 2: Run unit tests — should now PASS**

```bash
make test-unit 2>&1 | tail -10
```

Expected: all adt tests PASS.

- [ ] **Step 3: Run DSL tests — must still pass (desugar output unchanged)**

```bash
make test-dsl 2>&1 | tail -5
```

Expected: all DSL tests PASS (desugar.awk does not include adt.awk; the ADT change is runtime-only).

- [ ] **Step 4: Commit**

```bash
git add dsl/adt.awk tests/unit/test_adt.awk tests/unit/run.awk
git commit -m "feat(adt): Base64-encode ADT values for binary safety

result_ok_make/result_ng/option_some_make now b64-encode the value.
result_val/result_err/option_val decode on access.
result_err now returns the decoded message (not TypeName+msg).
Pure AWK implementation; no external dependencies."
```

---

## Task 3: Alias cycle detection (RED)

**Files:**
- Create: `tests/unit/dsl/type_alias_cycle_simple/input.awk`
- Create: `tests/unit/dsl/type_alias_cycle_simple/expected_stderr`
- Create: `tests/unit/dsl/type_alias_cycle_indirect/input.awk`
- Create: `tests/unit/dsl/type_alias_cycle_indirect/expected_stderr`

- [ ] **Step 1: Write simple cycle test**

`tests/unit/dsl/type_alias_cycle_simple/input.awk`:
```awk
type AliasA = AliasB
type AliasB = AliasA

function handler() -> Str {
  return "ok"
}
```

`tests/unit/dsl/type_alias_cycle_simple/expected_stderr`:
```
type alias cycle
```

- [ ] **Step 2: Write indirect cycle test**

`tests/unit/dsl/type_alias_cycle_indirect/input.awk`:
```awk
type MyStr = Error
type WrappedErr = MyStr | Int
type MyStr = WrappedErr

function handler() -> Str {
  return "ok"
}
```

`tests/unit/dsl/type_alias_cycle_indirect/expected_stderr`:
```
type alias cycle
```

- [ ] **Step 3: Run and verify tests FAIL**

```bash
make test-dsl 2>&1 | grep -E "FAIL|type_alias"
```

Expected: FAIL for both new cycle tests (current code has no cycle detection).

---

## Task 4: Implement alias cycle detection in type.awk

**Files:**
- Modify: `dsl/type.awk`

- [ ] **Step 1: Add `_type_check_alias_cycle` function**

Add at the end of `dsl/type.awk` (after the `accepts` function):

```awk
# _type_check_alias_cycle: DFS cycle detector for type aliases.
# Call immediately after adding name to _DS_TYPE_ALIAS.
# visiting[] tracks the current DFS path (gray set); callers pass empty array.
# All locals declared in parameter list per AWK convention.
function _type_check_alias_cycle(name, lineno, visiting,    target, parts, n, i) {
    if (!(name in awk::_DS_TYPE_ALIAS)) return
    if (name in visiting) {
        _ds_error(lineno, "type alias cycle detected: '" name "' expands to itself", \
            "remove the circular type alias")
        return
    }
    visiting[name] = 1
    target = awk::_DS_TYPE_ALIAS[name]
    n = split_union(target, parts)
    if (n == 1) {
        # Also check intersection for completeness
        n = split_intersection(target, parts)
    }
    for (i = 1; i <= n; i++) {
        if (parts[i] in awk::_DS_TYPE_ALIAS)
            _type_check_alias_cycle(parts[i], lineno, visiting)
    }
    delete visiting[name]
}
```

- [ ] **Step 2: Run DSL tests — should still see FAIL on cycle tests (not yet wired)**

```bash
make test-dsl 2>&1 | grep -E "FAIL|type_alias"
```

Expected: same FAILs as before (function exists but not called yet).

---

## Task 5: Wire cycle check into desugar.awk

**Files:**
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Find where user type aliases are registered**

```bash
grep -n "_DS_TYPE_ALIAS\[" dsl/desugar.awk
```

Expected output should show a line like:
```
64:  _DS_TYPE_ALIAS[m[1]] = m[2]
```

Note the exact line number and variable names for the next step.

- [ ] **Step 2: Add cycle check call after alias insertion**

In `dsl/desugar.awk`, find the block that registers user aliases. It looks like:

```awk
_DS_TYPE_ALIAS[m[1]] = m[2]
```

Change it to:

```awk
_DS_TYPE_ALIAS[m[1]] = m[2]
_type_visiting_tmp[0] = 0; delete _type_visiting_tmp
_type_check_alias_cycle(m[1], FNR, _type_visiting_tmp)
```

(The `_type_visiting_tmp` array is created fresh for each check to ensure clean DFS state.)

- [ ] **Step 3: Run DSL tests — cycle tests should PASS**

```bash
make test-dsl 2>&1 | grep -E "PASS|FAIL|type_alias"
```

Expected: both `type_alias_cycle_simple` and `type_alias_cycle_indirect` PASS.

- [ ] **Step 4: Run full DSL test suite to confirm no regressions**

```bash
make test-dsl 2>&1 | tail -5
```

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add dsl/type.awk dsl/desugar.awk \
  tests/unit/dsl/type_alias_cycle_simple/ \
  tests/unit/dsl/type_alias_cycle_indirect/
git commit -m "feat(type): detect circular type aliases at compile time

DFS cycle detection via _type_check_alias_cycle() in type.awk.
Called incrementally in desugar.awk after each user alias insertion.
All DFS locals in parameter list per AWK convention."
```

---

## Task 6: Full regression

- [ ] **Step 1: Run all tests**

```bash
make test 2>&1 | tail -10
```

Expected: 0 failed across unit and DSL tests.
