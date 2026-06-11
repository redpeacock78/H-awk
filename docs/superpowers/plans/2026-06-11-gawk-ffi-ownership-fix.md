# gawk_ffi String Ownership Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `awk_false`/`awk_true` misuse in `gawk_ffi.zig` so gawk stops crashing with `fatal error: internal error` when multipart parsing writes to arrays.

**Architecture:** Two-task sequential fix. Task 1 changes `gawk_ffi.zig` — adds `gawk_string` variant to `Result` enum, fixes `arraySet` to use `awk_true`, and splits `makeAdapter` to route `.string` → `awk_true` and `.gawk_string` → `awk_false`. Task 2 updates the three `root.zig` callers that allocate with `gawkAllocator()` to return `.gawk_string` instead of `.string`. Task 2 cannot compile until Task 1 is committed.

**Tech Stack:** Zig 0.16+, gawk 5.3.1 / API 4.0, `gawkapi.h`

---

## Background: the gawk ownership model

`r_make_string(api, ext_id, ptr, len, duplicate, result)`:
- `awk_true` (`duplicate=1`): gawk calls `emalloc + memcpy`. **Caller retains ownership.** Safe for static literals, stack arrays, and Zig-managed memory.
- `awk_false` (`duplicate=0`): gawk stores the raw pointer directly (`ALREADY_MALLOCED`). **gawk takes ownership** and later calls `efree()`. Only safe when the memory was allocated via `gawkAllocator()`.

Current code has both backwards:
- `arraySet` uses `awk_false` for static/Zig-owned strings → gawk tries to `efree` a static literal → `fatal error: internal error`.
- `makeAdapter` `.string` arm uses `awk_false` → same crash for stack arrays; for `gawkAllocator` memory it would work but leaks if the pointer is freed twice.

## File map

- **Modify:** `libs/_common/gawk_ffi.zig` — `arraySet` + `Result` enum + `makeAdapter`
- **Modify:** `libs/binary/src/root.zig` — `binRead` return value
- **Modify:** `libs/net/src/root.zig` — `netPoll` return value
- **Modify:** `libs/crypto/src/root.zig` — `argon2idFn` + `ecdsaSignFn` return values

---

## Task 1: Fix gawk_ffi.zig (core ownership model)

**Files:**
- Modify: `libs/_common/gawk_ffi.zig:53-70,170-185`

- [ ] **Step 1: Run test-unit to observe current crash**

```bash
make test-unit 2>&1 | tail -10
```

Expected output contains:
```
gawk: core/request.awk:71: fatal error: internal error
```

The crash confirms the bug. This is the "red" state.

- [ ] **Step 2: Fix arraySet — change awk_false → awk_true for both key and val**

Current lines 53-62 of `libs/_common/gawk_ffi.zig`:
```zig
/// Write a string key/value pair into a gawk array.
/// Both key and val must remain valid for the duration of the call;
/// gawk copies them (awk_false = gawk does NOT take ownership of our pointer).
pub fn arraySet(arr: c.awk_array_t, key: []const u8, val: []const u8) void {
    var k: c.awk_value_t = undefined;
    var v: c.awk_value_t = undefined;
    if (c.r_make_string(_api, _ext_id, key.ptr, key.len, c.awk_false, &k) == null) return;
    if (c.r_make_string(_api, _ext_id, val.ptr, val.len, c.awk_false, &v) == null) return;
    _ = _api.*.api_set_array_element.?(_ext_id, arr, &k, &v);
}
```

Replace with:
```zig
/// Write a string key/value pair into a gawk array.
/// gawk copies key and val (awk_true); caller retains ownership of the slices.
pub fn arraySet(arr: c.awk_array_t, key: []const u8, val: []const u8) void {
    var k: c.awk_value_t = undefined;
    var v: c.awk_value_t = undefined;
    if (c.r_make_string(_api, _ext_id, key.ptr, key.len, c.awk_true, &k) == null) return;
    if (c.r_make_string(_api, _ext_id, val.ptr, val.len, c.awk_true, &v) == null) return;
    _ = _api.*.api_set_array_element.?(_ext_id, arr, &k, &v);
}
```

- [ ] **Step 3: Add gawk_string variant to Result enum and fix makeAdapter**

Current lines 64-70 and 170-185 of `libs/_common/gawk_ffi.zig`:
```zig
/// Return value from a gawk extension function.
pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};
```

```zig
fn makeAdapter(comptime impl: *const fn (Args) Result) fn (c_int, [*c]c.awk_value_t, [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    return struct {
        fn adapter(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
            const r = impl(.{ ._argc = nargs });
            return switch (r) {
                .string => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_false, result),
                .int => |n| c.make_number(@floatFromInt(n), result),
                .bool => |b| c.make_number(if (b) 1.0 else 0.0, result),
                .none => {
                    // Return empty string (not 0, which would stringify to "0")
                    return c.r_make_string(_api, _ext_id, "", 0, c.awk_true, result);
                },
            };
        }
    }.adapter;
}
```

Replace both with:
```zig
/// Return value from a gawk extension function.
pub const Result = union(enum) {
    /// Caller-owned slice (static literal, stack array, Zig-managed memory).
    /// adapter uses awk_true so gawk copies; caller retains ownership.
    string: []const u8,
    /// gawkAllocator()-owned slice. adapter uses awk_false to transfer ownership to gawk.
    /// gawk will call efree() on it; do NOT free it yourself after returning.
    gawk_string: []const u8,
    int: i64,
    bool: bool,
    none,
};
```

```zig
fn makeAdapter(comptime impl: *const fn (Args) Result) fn (c_int, [*c]c.awk_value_t, [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    return struct {
        fn adapter(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
            const r = impl(.{ ._argc = nargs });
            return switch (r) {
                .string      => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_true,  result),
                .gawk_string => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_false, result),
                .int  => |n| c.make_number(@floatFromInt(n), result),
                .bool => |b| c.make_number(if (b) 1.0 else 0.0, result),
                .none => {
                    return c.r_make_string(_api, _ext_id, "", 0, c.awk_true, result);
                },
            };
        }
    }.adapter;
}
```

- [ ] **Step 4: Build libs to verify gawk_ffi.zig compiles**

```bash
make build-libs 2>&1
```

Expected: all libs build without errors. Any error here is a typo in Step 2 or 3.

- [ ] **Step 5: Commit**

```bash
git add libs/_common/gawk_ffi.zig
git commit -m "fix(gawk_ffi): correct awk_true/false ownership — arraySet+Result+makeAdapter"
```

---

## Task 2: Fix root.zig callers — return gawk_string for gawkAllocator memory

**Files:**
- Modify: `libs/binary/src/root.zig:28`
- Modify: `libs/net/src/root.zig:49`
- Modify: `libs/crypto/src/root.zig:52,87`

Prerequisite: Task 1 committed. The `gawk_string` variant must exist in `Result` before these files will compile.

- [ ] **Step 1: Fix libs/binary/src/root.zig — binRead**

Current line 28:
```zig
    return .{ .string = content };
```

`content` is allocated by `ffi.gawkAllocator()` (line 27). With `.string` and the new `awk_true` in makeAdapter, gawk would copy the data but the original gawkAllocator allocation would never be freed — memory leak. Use `.gawk_string` so gawk takes ownership and calls `efree()`.

Replace with:
```zig
    return .{ .gawk_string = content };
```

- [ ] **Step 2: Fix libs/net/src/root.zig — netPoll**

Current line 49:
```zig
    return .{ .string = result };
```

`result` is allocated by `ffi.gawkAllocator()` (line 48 `loop.dequeue(ffi.gawkAllocator())`). Same leak as binRead. Replace with:
```zig
    return .{ .gawk_string = result };
```

- [ ] **Step 3: Fix libs/crypto/src/root.zig — argon2idFn**

Current line 52:
```zig
    return .{ .string = out };
```

`out` is allocated by `ffi.gawkAllocator().dupe(u8, hash)` (line 51). Replace with:
```zig
    return .{ .gawk_string = out };
```

- [ ] **Step 4: Fix libs/crypto/src/root.zig — ecdsaSignFn**

Current line 87:
```zig
    return .{ .string = out };
```

`out` is allocated by `ffi.gawkAllocator().dupe(u8, sig)` (line 86). Replace with:
```zig
    return .{ .gawk_string = out };
```

Note: `sha256Fn`, `hmacSha256Fn`, `argon2idVerifyFn`, `ecdsaVerifyFn` are **not changed**. They return static literals (`"1"`, `"0"`) or stack-local arrays — all caller-owned, all correctly `.string`.

- [ ] **Step 5: Build all libs**

```bash
make build-libs 2>&1
```

Expected: 0 errors. If compile errors appear, check that the variant name is exactly `gawk_string` (not `gawkString`).

- [ ] **Step 6: Run full test suite**

```bash
make test-unit 2>&1 | tail -5
```

Expected output (no crash line, TESTS_FAILED = 0):
```
N passed, 0 failed, M skipped
```

The `gawk: core/request.awk:71: fatal error: internal error` line must not appear.

- [ ] **Step 7: Run lib tests**

```bash
make test-libs 2>&1
```

Expected: all lib test suites pass.

- [ ] **Step 8: Commit**

```bash
git add libs/binary/src/root.zig libs/net/src/root.zig libs/crypto/src/root.zig
git commit -m "fix(libs): return gawk_string for gawkAllocator-owned slices (binary/net/crypto)"
```
