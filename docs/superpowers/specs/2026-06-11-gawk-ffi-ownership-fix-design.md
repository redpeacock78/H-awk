# gawk_ffi String Ownership Fix Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gawk_ffi.zig` の `arraySet` と `Result.string` return path における `awk_false`/`awk_true` の誤用を修正し、gawk extension API の文字列所有権モデルを型で正しく表現する。

**Architecture:** `gawk_ffi.zig` に `Result.gawk_string` variant を追加してAPIを型安全にする。`arraySet` は `awk_true`（gawkがコピー）に変更。gawkAllocator で確保した返値を持つ関数は `gawk_string` に移行する。

**Tech Stack:** Zig 0.16+, gawk 5.3.1 / API 4.0, `gawkapi.h`

---

## 根本原因

`r_make_string(api, ext_id, ptr, len, duplicate, result)` の `duplicate` フラグ：

- `awk_true` = gawk が `emalloc + memcpy` でコピー。呼び出し側がポインタを所有し続ける
- `awk_false` = gawk がポインタを直接保持（`ALREADY_MALLOCED`）。gawk が `efree()` で解放

現在の `gawk_ffi.zig` はこれを逆に使っている：

1. **`arraySet`**: 呼び出し側所有（静的リテラル・スタック・Zig alloc）の文字列に `awk_false` → gawk が `efree(static_ptr)` → `fatal error: internal error`
2. **`makeAdapter` `.string` arm**: `awk_false` なのにスタック上の配列ポインタを渡す (`sha256Fn`, `hmacSha256Fn`) → use-after-return。静的リテラル (`"1"`, `"0"`) はUBだが偶然落ちていない

---

## ファイル構成

- 変更: `libs/_common/gawk_ffi.zig` — `arraySet` + `Result` enum + `makeAdapter`
- 変更: `libs/binary/src/root.zig` — `binRead` 返値を `gawk_string` に
- 変更: `libs/net/src/root.zig` — `netPoll` 返値を `gawk_string` に
- 変更: `libs/crypto/src/root.zig` — `argon2idFn`, `ecdsaSignFn` 返値を `gawk_string` に

---

## API 変更

### `Result` enum

```zig
pub const Result = union(enum) {
    /// 呼び出し側が所有するスライス（静的リテラル・スタック配列・Zig管理メモリ）。
    /// adapter が awk_true でコピーするので、gawkがefreeしない。
    string: []const u8,

    /// ffi.gawkAllocator() で確保したスライス。
    /// adapter が awk_false で所有権をgawkに移譲。gawkがefreeで解放する。
    gawk_string: []const u8,

    int: i64,
    bool: bool,
    none,
};
```

### `makeAdapter` の変更

```zig
.string =>      |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_true,  result),
.gawk_string => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_false, result),
```

### `arraySet` の変更

```zig
pub fn arraySet(arr: c.awk_array_t, key: []const u8, val: []const u8) void {
    var k: c.awk_value_t = undefined;
    var v: c.awk_value_t = undefined;
    // awk_true: gawk が emalloc+memcpy でコピー。呼び出し側が所有権を保持する
    if (c.r_make_string(_api, _ext_id, key.ptr, key.len, c.awk_true, &k) == null) return;
    if (c.r_make_string(_api, _ext_id, val.ptr, val.len, c.awk_true, &v) == null) return;
    _ = _api.*.api_set_array_element.?(_ext_id, arr, &k, &v);
}
```

---

## 各 root.zig の変更

### `libs/binary/src/root.zig`

```zig
fn binRead(...) ffi.Result {
    const content = binary.readAll(ffi.gawkAllocator(), path, max_bytes) catch return .none;
    return .{ .gawk_string = content };  // gawkAllocator所有 → gawkがefree
}
```

### `libs/net/src/root.zig`

```zig
fn netPoll(...) ffi.Result {
    const loop = _loop orelse return .none;
    const result = loop.dequeue(ffi.gawkAllocator()) orelse return .none;
    return .{ .gawk_string = result };   // gawkAllocator所有 → gawkがefree
}
```

### `libs/crypto/src/root.zig`

```zig
fn argon2idFn(...) ffi.Result {
    ...
    const out = ffi.gawkAllocator().dupe(u8, hash) catch return .{ .string = "" };
    return .{ .gawk_string = out };      // gawkAllocator所有 → gawkがefree
}

fn ecdsaSignFn(...) ffi.Result {
    ...
    const out = ffi.gawkAllocator().dupe(u8, sig) catch return .{ .string = "" };
    return .{ .gawk_string = out };      // gawkAllocator所有 → gawkがefree
}

// sha256Fn, hmacSha256Fn: スタック配列ポインタ → .string のまま
// awk_true で adapter が即コピーするので安全
fn sha256Fn(...) ffi.Result {
    const hex_bytes = crypto.sha256(data);
    return .{ .string = &hex_bytes };    // awk_true でコピー済み → スタック破棄OK
}
```

変更不要（`.string` でok）：
- `multipart/root.zig`: `"1"`, `"0"` 静的リテラル
- `crypto/root.zig`: `sha256Fn`, `hmacSha256Fn` スタック配列（awk_trueで即コピー）
- `crypto/root.zig`: `"1"`, `"0"` 静的リテラル

---

## テスト検証

```bash
# 各lib zig test
make test-libs

# unit tests (multipart parseが通れば修正成功)
make test-unit

# 期待: 0 failed
```

`make test-unit` で `gawk: core/request.awk:71: fatal error: internal error` が消えること。
