# when...of syntax + type system extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ng e: TypeName:` with `ng e<TypeName>:` in when...of syntax, and extend `type` declarations to support Union/Intersection types with alias registration and validator generation.

**Architecture:** Two independent changes. (1) `dsl/desugar_match.awk`: swap two regex patterns for `ng` typed arms — no logic change, only parsing. (2) `dsl/desugar.awk` + `dsl/type.awk`: generalize `type X = ...` to handle non-Error types, and extend `type::accepts()` / `type::normalize()` to handle `&` (intersection).

**Tech Stack:** gawk (GNU AWK), bash test runner (`tests/unit/dsl/run.sh`), `make test-dsl`

---

## File Map

| File | Change |
|------|--------|
| `dsl/desugar_match.awk` | Replace 2 regex patterns for typed `ng` arms; update header comment |
| `dsl/type.awk` | Add `split_intersection()`; update `normalize()` and `accepts()` for `&` |
| `dsl/desugar.awk` | Generalize `type X = ...` regex; emit alias + validator for non-Error types |
| `tests/unit/dsl/when_typed_ng_single/input.awk` | Update to new `<>` syntax |
| `tests/unit/dsl/when_typed_ng_multi/input.awk` | Update to new `<>` syntax |
| `tests/unit/dsl/when_typed_ng_exhaustive_error/input.awk` | Update to new `<>` syntax |
| `tests/unit/dsl/type_union_decl/` | New test fixture |
| `tests/unit/dsl/type_intersection_decl/` | New test fixture |

---

### Task 1: Update when...of test fixtures to new `<>` syntax

**Files:**
- Modify: `tests/unit/dsl/when_typed_ng_single/input.awk`
- Modify: `tests/unit/dsl/when_typed_ng_multi/input.awk`
- Modify: `tests/unit/dsl/when_typed_ng_exhaustive_error/input.awk`

- [ ] **Step 1: Update `when_typed_ng_single/input.awk`**

Replace content with:
```awk
function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng e<AuthError>:
      return ctx.res.status(401)
    default:
      return ctx.res.status(500)
  end
}
```

- [ ] **Step 2: Update `when_typed_ng_multi/input.awk`**

Replace content with:
```awk
function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng e<AuthError>:
      return ctx.res.status(401)
    ng e<NotFoundError>:
      return ctx.res.status(404)
    default:
      return ctx.res.status(500)
  end
}
```

- [ ] **Step 3: Update `when_typed_ng_exhaustive_error/input.awk`**

Replace content with:
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
    ng e<AuthError>:
      return ctx.res.status(401)
  end
}
```

- [ ] **Step 4: Run tests and verify failures**

```bash
make test-dsl 2>&1 | grep -E "FAIL|PASS" | grep -E "when_typed"
```

Expected: `when_typed_ng_single`, `when_typed_ng_multi`, `when_typed_ng_exhaustive_error` すべて FAIL（まだパーサー未変更）

- [ ] **Step 5: Commit**

```bash
git add tests/unit/dsl/when_typed_ng_single/input.awk \
        tests/unit/dsl/when_typed_ng_multi/input.awk \
        tests/unit/dsl/when_typed_ng_exhaustive_error/input.awk
git commit -m "test(dsl): update when...of ng typed arms to <Type> syntax (failing)"
```

---

### Task 2: Update `desugar_match.awk` parser for new `<>` syntax

**Files:**
- Modify: `dsl/desugar_match.awk`

- [ ] **Step 1: Update header comment**

In `dsl/desugar_match.awk`, replace the syntax comment block (lines 3–17):
```awk
# Syntax:
#   when EXPR of
#     ok VAR:           -- Result ok branch (binds VAR to result_val)
#     ok:               -- Result ok branch (no binding)
#     some VAR:         -- Option some branch (binds VAR to option_val)
#     some:             -- Option some branch (no binding)
#     ng VAR<TypeName>: -- typed ng, bind VAR to result_err, match by type
#     ng <TypeName>:    -- typed ng, no bind, match by type
#     ng VAR:           -- untyped ng, bind VAR to result_err
#     ng:               -- untyped ng, no bind
#     none:             -- Option none branch (catch-all for option)
#     default VAR:      -- catch-all, bind VAR to result_err
#     default:          -- catch-all, no binding
#   end
```

- [ ] **Step 2: Replace typed ng bind regex**

In `_ds_match_collect()`, find:
```awk
  # ng e: TypeName:  (typed ng, bind — check BEFORE plain "ng name:")
  if (match(line, /^[[:space:]]*ng[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
    _DS_match_ng_type[i] = m[2]; _DS_match_ng_var_name[i] = m[1]
    _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
  }
```

Replace with:
```awk
  # ng VAR<TypeName>:  (typed ng, bind — check BEFORE plain "ng name:")
  if (match(line, /^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)<([^>]+)>[[:space:]]*:[[:space:]]*$/, m)) {
    i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
    _DS_match_ng_type[i] = m[2]; _DS_match_ng_var_name[i] = m[1]
    _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
  }
```

- [ ] **Step 3: Replace typed ng no-bind regex**

Find:
```awk
  # ng TypeName:  (typed ng, no bind)
  if (match(line, /^[[:space:]]*ng[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
    _DS_match_ng_type[i] = m[1]; _DS_match_ng_var_name[i] = ""
    _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
  }
```

Replace with:
```awk
  # ng <TypeName>:  (typed ng, no bind)
  if (match(line, /^[[:space:]]*ng[[:space:]]*<([^>]+)>[[:space:]]*:[[:space:]]*$/, m)) {
    i = ++_DS_match_ng_arms; _DS_match_cur_ng_arm = i
    _DS_match_ng_type[i] = m[1]; _DS_match_ng_var_name[i] = ""
    _DS_match_ng_is_default[i] = 0; _DS_match_branch = "ng"; return ""
  }
```

- [ ] **Step 4: Run tests and verify passing**

```bash
make test-dsl 2>&1 | grep -E "FAIL|when_typed"
```

Expected: `when_typed_ng_single` PASS, `when_typed_ng_multi` PASS, `when_typed_ng_exhaustive_error` PASS, no FAIL lines.

- [ ] **Step 5: Run full test suite**

```bash
make test-dsl
```

Expected: all PASS, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar_match.awk
git commit -m "feat(dsl): replace ng e: Type: syntax with ng e<Type>: using angle brackets"
```

---

### Task 3: Add intersection support to `type.awk`

**Files:**
- Modify: `dsl/type.awk`

- [ ] **Step 1: Add `split_intersection()` function**

In `dsl/type.awk`, after `split_union()` (around line 50), add:
```awk
# type::split_intersection -- split at top-level & only (respects <...> depth)
# stores results in out[], returns count
function split_intersection(t, out,    i, c, depth, cur, n) {
    n = 0; depth = 0; cur = ""
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if      (c == "<") depth++
        else if (c == ">") depth--
        else if (c == "&" && depth == 0) {
            out[++n] = _ds_trim_type(cur)
            cur = ""
            continue
        }
        cur = cur c
    }
    if (length(_ds_trim_type(cur)) > 0) out[++n] = _ds_trim_type(cur)
    return n
}
```

- [ ] **Step 2: Update `normalize()` to handle `&`**

Find `normalize()` in `dsl/type.awk`. Replace the function with:
```awk
# type::normalize -- sort members, deduplicate, join with | or & (no spaces)
function normalize(t,    out, n, i, j, sorted, seen, result, tmp, sep) {
    # try | (union) first
    n = split_union(t, out)
    sep = "|"
    if (n == 1) {
        # try & (intersection)
        n = split_intersection(t, out)
        sep = "&"
    }
    if (n == 1) return expand_alias(out[1])
    # deduplicate
    for (i = 1; i <= n; i++) seen[expand_alias(out[i])] = 1
    n = 0
    for (i in seen) sorted[++n] = i
    # bubble sort (small n)
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[i] > sorted[j]) { tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp }
    result = sorted[1]
    for (i = 2; i <= n; i++) result = result sep sorted[i]
    return result
}
```

- [ ] **Step 3: Update `accepts()` to handle intersection**

Find `accepts()` in `dsl/type.awk`. Add local vars `einter` and `ei_n`, and insert intersection check after the alias expansion block:

Current signature:
```awk
function accepts(expected, actual,    eparts, apart, en, an, i, j) {
```

Replace with:
```awk
function accepts(expected, actual,    eparts, apart, en, an, i, j, einter, ei_n) {
    if (expected == actual)  return 1
    if (expected == "Any")   return 1
    if (actual   == "Any")   return 1
    if (actual   == "")      return 1

    # aliases must not be circular (table is hardcoded in sig.awk)
    if (expected in awk::_DS_TYPE_ALIAS) return accepts(awk::_DS_TYPE_ALIAS[expected], actual)
    if (actual   in awk::_DS_TYPE_ALIAS) return accepts(expected, awk::_DS_TYPE_ALIAS[actual])

    # intersection in expected: actual must satisfy ALL members
    ei_n = split_intersection(expected, einter)
    if (ei_n > 1) {
        for (i = 1; i <= ei_n; i++)
            if (!accepts(einter[i], actual)) return 0
        return 1
    }

    en = split_union(expected, eparts)
    an = split_union(actual,   apart)

    if (en > 1 && an == 1) {
        # expected is union: any member accepts actual => OK
        for (i = 1; i <= en; i++)
            if (accepts(eparts[i], actual)) return 1
        return 0
    }

    if (an > 1) {
        # actual is union: ALL members must be accepted by expected
        for (j = 1; j <= an; j++)
            if (!accepts(expected, apart[j])) return 0
        return 1
    }

    return 0
}
```

- [ ] **Step 4: Run tests (type.awk changes are exercised indirectly)**

```bash
make test-dsl
```

Expected: all PASS, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add dsl/type.awk
git commit -m "feat(dsl): add intersection type support to type::accepts and type::normalize"
```

---

### Task 4: Extend `desugar.awk` for non-Error type declarations

**Files:**
- Create: `tests/unit/dsl/type_union_decl/input.awk`
- Create: `tests/unit/dsl/type_union_decl/expected.awk`
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: Create test fixture for Union type declaration**

Create `tests/unit/dsl/type_union_decl/input.awk`:
```awk
type Status = Int | Str
```

Create `tests/unit/dsl/type_union_decl/expected.awk`:
```awk
function Status(val) { if (type::accepts("Int|Str", val)) return val; return result_ng("TypeError:Status", "expected Int|Str, got " val) }
```

- [ ] **Step 2: Run test and verify it fails**

```bash
make test-dsl 2>&1 | grep type_union_decl
```

Expected: `FAIL: type_union_decl`

- [ ] **Step 3: Generalize `type X = ...` regex in `dsl/desugar.awk`**

Find in `dsl/desugar.awk`:
```awk
    # type X = Error → emit constructor + register error type
    if (match(line, /^([[:space:]]*)type[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*Error[[:space:]]*$/, _ds_type_m)) {
      _DS_ERROR_TYPES[_ds_type_m[2]] = 1
      print _ds_type_m[1] "function " _ds_type_m[2] "(msg) { return result_ng(\"" _ds_type_m[2] "\", msg) }"
      return
    }
```

Replace with:
```awk
    # type X = <expr> → Error constructor, or alias + validator
    if (match(line, /^([[:space:]]*)type[[:space:]]+([A-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, _ds_type_m)) {
      if (_ds_trim(_ds_type_m[3]) == "Error") {
        _DS_ERROR_TYPES[_ds_type_m[2]] = 1
        print _ds_type_m[1] "function " _ds_type_m[2] "(msg) { return result_ng(\"" _ds_type_m[2] "\", msg) }"
      } else {
        _ds_type_expr = type::normalize(_ds_trim(_ds_type_m[3]))
        _DS_TYPE_ALIAS[_ds_type_m[2]] = _ds_type_expr
        print _ds_type_m[1] "function " _ds_type_m[2] "(val) { if (type::accepts(\"" _ds_type_expr "\", val)) return val; return result_ng(\"TypeError:" _ds_type_m[2] "\", \"expected " _ds_type_expr ", got \" val) }"
      }
      return
    }
```

Note: `_ds_type_expr` must be declared as a local variable. Find `_ds_process_line` signature:
```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p, dot_transformed, pipe_pre, pipe_result, match_m, _ds_type_m) {
```
Add `_ds_type_expr` to the local vars list:
```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p, dot_transformed, pipe_pre, pipe_result, match_m, _ds_type_m, _ds_type_expr) {
```

- [ ] **Step 4: Run test and verify it passes**

```bash
make test-dsl 2>&1 | grep type_union_decl
```

Expected: `PASS: type_union_decl`

- [ ] **Step 5: Run full suite**

```bash
make test-dsl
```

Expected: all PASS, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add dsl/desugar.awk \
        tests/unit/dsl/type_union_decl/input.awk \
        tests/unit/dsl/type_union_decl/expected.awk
git commit -m "feat(dsl): extend type declarations to support Union/Intersection type aliases with validator generation"
```

---

### Task 5: Add test for Intersection type declaration

**Files:**
- Create: `tests/unit/dsl/type_intersection_decl/input.awk`
- Create: `tests/unit/dsl/type_intersection_decl/expected.awk`

- [ ] **Step 1: Create test fixture**

Create `tests/unit/dsl/type_intersection_decl/input.awk`:
```awk
type Both = Int & Str
```

Create `tests/unit/dsl/type_intersection_decl/expected.awk`:
```awk
function Both(val) { if (type::accepts("Int&Str", val)) return val; return result_ng("TypeError:Both", "expected Int&Str, got " val) }
```

- [ ] **Step 2: Run test and verify it passes**

```bash
make test-dsl 2>&1 | grep type_intersection_decl
```

Expected: `PASS: type_intersection_decl`

- [ ] **Step 3: Run full suite**

```bash
make test-dsl
```

Expected: all PASS, 0 failed.

- [ ] **Step 4: Commit**

```bash
git add tests/unit/dsl/type_intersection_decl/input.awk \
        tests/unit/dsl/type_intersection_decl/expected.awk
git commit -m "test(dsl): add intersection type declaration fixture"
```
