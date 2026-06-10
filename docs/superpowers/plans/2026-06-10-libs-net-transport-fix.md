# libs/net Transport Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three bugs that cause the server to crash when `libs/net` is loaded: missing `log_warn` function, missing inet fallback when Zig event loop poll fails, and a Zig race condition that causes `hawk_net_poll()` to immediately return empty.

**Architecture:** Three independent fixes applied in sequence: (1) AWK utility layer, (2) AWK http layer, (3) Zig event loop. Fix 3 requires a `zig build` and binary redeploy. All three are needed for `libs/net` to work correctly end-to-end.

**Tech Stack:** gawk (AWK), Zig 0.14, make

---

### Task 1: Add `log_warn` to `core/util.awk`

**Files:**
- Modify: `core/util.awk` (after line 83, after `log_error`)

- [ ] **Step 1: Write the failing test**

In `tests/unit/test_util.awk`, add at the end of the file:

```awk
function test_util_log_warn(    captured) {
  # log_warn must exist and write to stderr without crashing
  # We can't capture stderr in gawk unit tests, so just verify it's callable
  log_warn("test warn message")
  TESTS_PASSED++  # if we get here, function exists
}
```

- [ ] **Step 2: Register the test in `tests/unit/run.awk`**

In `tests/unit/run.awk`, after `test_util_to_lower()` (line 13), add:

```awk
  test_util_log_warn()
```

- [ ] **Step 3: Run test to verify it fails**

```bash
make test-unit 2>&1 | head -20
```

Expected: `fatal: function 'log_warn' not defined` or similar failure.

- [ ] **Step 4: Add `log_warn` to `core/util.awk`**

In `core/util.awk`, after the `log_error` function (after line 83):

```awk
function log_warn(msg) {
  printf "[WARN]  %s\n", msg > "/dev/stderr"
  fflush("/dev/stderr")
}
```

Also update the comment block at the top of `core/util.awk` (lines 9-10) to include `log_warn`:

```
# log_info(msg)   stdout 出力
# log_warn(msg)   stderr 出力 (警告)
# log_error(msg)  stderr 出力
```

- [ ] **Step 5: Run test to verify it passes**

```bash
make test-unit 2>&1 | tail -5
```

Expected: `N passed, 0 failed, N skipped` (one more passed than before).

- [ ] **Step 6: Commit**

```bash
git add core/util.awk tests/unit/test_util.awk tests/unit/run.awk
git commit -m "feat(core/util): add log_warn for stderr warning output"
```

---

### Task 2: Fix `_http_serve_zig` poll failure fallback in `core/http.awk`

**Context:** When `hawk_net_poll()` returns `""` (Zig event loop stopped), the current code calls `log_error` and `break`, leaving the server dead. It should fall back to `/inet/tcp/` instead. Also, the existing `log_warn` call on line 126 (bind failure) was the original crash point.

**Files:**
- Modify: `core/http.awk` lines 124-169

- [ ] **Step 1: Verify current broken behavior**

```bash
# Confirm log_warn crash is fixed (from Task 1), then check poll failure path
grep -n "log_warn\|log_error\|event loop" core/http.awk
```

Expected output shows:
- Line 126: `log_warn(...)` — now works after Task 1
- Line ~134: `log_error("libs/net: event loop stopped unexpectedly"); break` — this is what needs fixing

- [ ] **Step 2: Fix the poll failure path**

In `core/http.awk`, find the block at approximately line 131-135:

```awk
    if (poll_result == "") {
      log_error("libs/net: event loop stopped unexpectedly")
      break
    }
```

Replace with:

```awk
    if (poll_result == "") {
      log_warn("libs/net: event loop stopped unexpectedly, falling back to /inet/tcp/")
      _http_serve_inet()
      return
    }
```

- [ ] **Step 3: Run unit tests to verify no regression**

```bash
make test-unit 2>&1 | tail -5
```

Expected: same pass count as after Task 1, 0 failed.

- [ ] **Step 4: Commit**

```bash
git add core/http.awk
git commit -m "fix(core/http): fall back to inet when Zig event loop stops"
```

---

### Task 3: Fix Zig race condition in `libs/net/src/event_loop.zig`

**Context:** `EventLoop.init()` sets `running = std.atomic.Value(bool).init(false)`. The `run()` method (called in a spawned thread) sets `running = true`. But `dequeue()` loops `while (self.running.load(.seq_cst))` — if gawk calls `hawk_net_poll()` → `dequeue()` before the thread's `run()` executes, `running` is still `false` and `dequeue()` returns `null` immediately. Fix: initialize `running = true` in `init()`.

**Note on `stop()`:** `stop()` stores `false` into `running` and writes to the wakeup pipe. This is still correct — `stop()` must be called explicitly to shut down. The thread's `run()` also stores `true` at start, so even after a restart the flag is set correctly.

**Files:**
- Modify: `libs/net/src/event_loop.zig` line 109

- [ ] **Step 1: Check existing Zig tests**

```bash
cd libs/net && zig build test 2>&1 | tail -10
```

Expected: tests pass (or show current state as baseline).

- [ ] **Step 2: Find the exact line to change**

```bash
grep -n "running.*init" libs/net/src/event_loop.zig
```

Expected: `109:            .running = std.atomic.Value(bool).init(false),`

- [ ] **Step 3: Apply the fix**

In `libs/net/src/event_loop.zig`, line 109, change:

```zig
            .running = std.atomic.Value(bool).init(false),
```

to:

```zig
            .running = std.atomic.Value(bool).init(true),
```

- [ ] **Step 4: Build the Zig library**

```bash
cd libs/net && zig build 2>&1
```

Expected: build succeeds with no errors.

- [ ] **Step 5: Run Zig tests**

```bash
cd libs/net && zig build test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Run full unit test suite**

From project root:

```bash
make test-unit 2>&1 | tail -5
```

Expected: all AWK unit tests pass.

- [ ] **Step 7: Smoke test with libs/net**

```bash
# In one terminal:
DEV=1 ./bin/hawk examples/hello/app.awk &
sleep 1
curl -s http://localhost:8080/
kill %1
```

Expected:
- Server logs: `[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, ...]`
- No `[ERROR] libs/net: event loop stopped unexpectedly`
- curl returns a response

- [ ] **Step 8: Commit**

```bash
git add libs/net/src/event_loop.zig
git commit -m "fix(libs/net): initialize running=true to prevent poll race condition"
```

---

### Task 4: Verify end-to-end and run full CI

**Files:** none (verification only)

- [ ] **Step 1: Run full test suite**

```bash
make test 2>&1 | tail -10
```

Expected: all unit + e2e tests pass.

- [ ] **Step 2: Run libs tests**

```bash
make test-libs 2>&1 | tail -10
```

Expected: Zig tests pass for all libs.

- [ ] **Step 3: Verify libs/net in startup log**

```bash
DEV=1 HAWK_NO_SERVE=0 ./bin/hawk examples/hello/app.awk &
sleep 0.5
kill %1 2>/dev/null; wait 2>/dev/null
```

Expected log line contains `[libs: net, ...]`.

- [ ] **Step 4: Verify no regression with HAWK_NO_SERVE**

```bash
make test-unit 2>&1 | tail -3
```

Expected: `N passed, 0 failed, N skipped`
