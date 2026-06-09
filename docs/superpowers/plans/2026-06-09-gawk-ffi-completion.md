# gawk_ffi.zig 完成 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gawk_ffi.zig` に `@cImport(gawkapi.h)` と `makeDlLoad` comptime 関数を実装し、`root.zig` から `@cImport` を除去して gawk extension の boilerplate を完全集約する。

**Architecture:** `gawk_ffi.zig` が gawkapi.h を @cImport し、`makeDlLoad(comptime cfg)` を comptime 実装する。各 lib は `usingnamespace ffi.makeDlLoad(...)` 一行で `dl_load` と `plugin_is_GPL_compatible` を export する。`Args` は `_api`/`_ext_id` module-level グローバル経由で `api_get_argument` を呼ぶ calls-on-demand 方式に再設計する。

**Tech Stack:** Zig 0.16, gawk 5.x extension API (gawkapi.h)

---

## File Structure

| ファイル | 操作 | 内容 |
|----------|------|------|
| `libs/binary/build.zig` | Modify | ffi_mod 作成 + gawk_include 追加 + root_mod.addImport |
| `libs/_common/gawk_ffi.zig` | Rewrite | @cImport, Args 再設計, makeAdapter, makeDlLoad 実装 |
| `libs/binary/src/root.zig` | Rewrite | @cImport 除去、usingnamespace + ffi.Args/Result に移行 |
| `libs/binary/tests/binary_test.zig` | No change | binary.zig のみテスト、root.zig 変更の影響なし |

---

## Task 1: ベースライン確認

> **Difficulty: LOW** (推奨モデル: haiku)

**Files:**
- Read: `libs/binary/` (確認のみ)

- [ ] **Step 1: 既存テストが pass することを確認**

```bash
cd /path/to/hawk/libs/binary && zig build test
```

Expected output:
```
All 7 tests passed.
```

テスト名の確認 (7件):
- `read text file`
- `read binary bytes (null bytes)`
- `read missing file returns error`
- `read file exceeding max_bytes`
- `lengthBytes ascii`
- `lengthBytes multibyte`
- `lengthBytes empty`

- [ ] **Step 2: ビルドも通ることを確認**

```bash
cd /path/to/hawk/libs/binary && zig build
```

Expected: `zig-out/lib/libhawk_binary.{so,dylib}` が生成される

---

## Task 2: build.zig — ffi モジュールの追加

> **Difficulty: LOW** (推奨モデル: haiku)

**Files:**
- Modify: `libs/binary/build.zig`

`gawk_ffi.zig` が `@cImport(gawkapi.h)` を持つため、ffi_mod にも gawk_include path を設定する必要がある。

- [ ] **Step 1: build.zig を更新**

`libs/binary/build.zig` の `b.installArtifact(lib);` の直前 (現在 line 35) に以下を追加する:

```zig
    // gawk_ffi module: @cImport(gawkapi.h) を持つため include path が必要
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
        .link_libc = true,
    });
    if (gawk_include.len > 0) {
        ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });
    }
    root_mod.addImport("gawk_ffi", ffi_mod);
```

変更後の `build.zig` 全体:

```zig
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "hawk_binary",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
    });

    // gawkapi.h include path auto-detection
    const gawk_include = b.option(
        []const u8,
        "gawk-include",
        "Path to gawkapi.h directory",
    ) orelse findGawkInclude(b) orelse "";

    if (gawk_include.len > 0) {
        lib.root_module.addIncludePath(.{ .cwd_relative = gawk_include });
    } else {
        @panic("gawkapi.h not found. Set -Dgawk-include=/path/to/gawk/include or GAWK_INCLUDE_PATH");
    }

    // gawk_ffi module: @cImport(gawkapi.h) を持つため include path が必要
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
        .link_libc = true,
    });
    if (gawk_include.len > 0) {
        ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });
    }
    root_mod.addImport("gawk_ffi", ffi_mod);

    b.installArtifact(lib);

    // Zig unit tests (binary.zig only, no gawk needed)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/binary_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const src_mod = b.createModule(.{
        .root_source_file = b.path("src/binary.zig"),
    });
    test_mod.addImport("binary", src_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn findGawkInclude(_: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{
        "/usr/local/include",
        "/opt/homebrew/include/gawk",
        "/usr/local/include/gawk",
        "/usr/include/gawk",
    };
    for (candidates) |p| {
        return p;
    }
    return null;
}
```

- [ ] **Step 2: テストがまだ pass することを確認 (build.zig 変更のみ)**

```bash
cd /path/to/hawk/libs/binary && zig build test
```

Expected: 全 7 テスト pass。root.zig はまだ古い @cImport を使っているが、zig build test は binary.zig のみをテストするので pass する。

---

## Task 3: gawk_ffi.zig の完全書き換え

> **Difficulty: HIGH** (推奨モデル: sonnet または opus)

**Files:**
- Rewrite: `libs/_common/gawk_ffi.zig`

`gawk_ffi.zig` を以下の構成で書き換える。重要な設計ポイント:
- `_api` / `_ext_id` はモジュールレベルグローバル (gawk extension はシングルスレッド保証)
- `Args` は `_argc` のみ保持し、`getString` 等が `api_get_argument` を呼ぶ
- `makeDlLoad` は comptime struct を返し、その中に `export fn dl_load` と `export var plugin_is_GPL_compatible` を持つ
- `_funcs` を struct 内 `var` にすることで static storage として gawk が参照し続けられる
- `makeAdapter` は comptime 引数の `impl` を C-callable に変換する

- [ ] **Step 1: gawk_ffi.zig を書き換え**

`libs/_common/gawk_ffi.zig` を以下の内容で完全置換する:

```zig
// SPDX-License-Identifier: MIT
// libs/_common/gawk_ffi.zig -- gawk extension C ABI wrapper
//
// @cImport(gawkapi.h) を集約し、各 lib の root.zig から @cImport を不要にする。
// makeDlLoad(comptime cfg) で dl_load + plugin_is_GPL_compatible を生成する。
//
// 使用例 (root.zig):
//   const ffi = @import("gawk_ffi");
//   usingnamespace ffi.makeDlLoad(.{
//       .name = "hawk_foo",
//       .functions = &.{
//           .{ .name = "foo_func", .impl = &fooImpl, .args = 1 },
//       },
//   });
//   fn fooImpl(args: ffi.Args) ffi.Result { ... }

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stddef.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("gawkapi.h");
});

// ---------------------------------------------------------------------------
// Module-level gawk state
// gawk extension はシングルスレッドで動作する (gawk の保証)。
// dl_load が呼ばれた時点でセットされ、以降の全関数呼出で参照する。
// ---------------------------------------------------------------------------

var _api: *const c.gawk_api_t = undefined;
var _ext_id: c.awk_ext_id_t = undefined;

// ---------------------------------------------------------------------------
// Public API types
// ---------------------------------------------------------------------------

/// gawk extension 関数に渡される引数リスト。
/// getString / getInt / getDouble で各引数を取得する。
pub const Args = struct {
    _argc: c_int,

    /// i 番目の引数を文字列として取得。型不一致またはインデックス範囲外は "" を返す。
    pub fn getString(self: Args, i: usize) []const u8 {
        if (i >= @as(usize, @intCast(self._argc))) return "";
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_STRING, &v) == c.awk_false) return "";
        return v.u.s.str[0..v.u.s.len];
    }

    /// i 番目の引数を i64 として取得。型不一致またはインデックス範囲外は 0 を返す。
    pub fn getInt(self: Args, i: usize) i64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0;
        return @intFromFloat(v.u.d);
    }

    /// i 番目の引数を f64 として取得。型不一致またはインデックス範囲外は 0.0 を返す。
    pub fn getDouble(self: Args, i: usize) f64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0.0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0.0;
        return v.u.d;
    }
};

/// gawk extension 関数の戻り値。
pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};

/// 1 つの gawk extension 関数の定義。
pub const FuncDef = struct {
    name: []const u8,
    impl: *const fn (Args) Result,
    args: usize,
};

/// makeDlLoad に渡す設定。
pub const DlLoadConfig = struct {
    name: []const u8,
    api_major: u32 = 4,
    api_minor: u32 = 0,
    functions: []const FuncDef,
};

// ---------------------------------------------------------------------------
// gawk_malloc-based allocator
// 将来の libs/multipart 等で使用予定。dl_load 呼出後にのみ使用可。
// ---------------------------------------------------------------------------

pub fn gawkAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &gawk_allocator_vtable,
    };
}

const gawk_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = gawkAlloc,
    .resize = gawkResize,
    .free = gawkFreeSlice,
};

fn gawkAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr = _api.*.api_malloc.?(_ext_id, n) orelse return null;
    return @ptrCast(ptr);
}

fn gawkResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn gawkFreeSlice(_: *anyopaque, slice: []u8, _: std.mem.Alignment, _: usize) void {
    _api.*.api_free.?(_ext_id, slice.ptr);
}

// ---------------------------------------------------------------------------
// makeDlLoad: comptime gawk extension generator
//
// 返り値の型を usingnamespace で展開することで、dl_load と
// plugin_is_GPL_compatible を呼出側ファイルの export シンボルとして登録する。
// ---------------------------------------------------------------------------

pub fn makeDlLoad(comptime cfg: DlLoadConfig) type {
    return struct {
        // 関数テーブルは dl_load 完了後も gawk が参照するため static storage に置く
        var _funcs: [cfg.functions.len]c.awk_ext_func_t = undefined;

        export var plugin_is_GPL_compatible: c_int = 1;

        export fn dl_load(api_p: [*c]const c.gawk_api_t, id: c.awk_ext_id_t) c_int {
            if (api_p == null) return 0;
            _api = api_p.?;
            _ext_id = id;

            if (_api.*.major_version != c.GAWK_API_MAJOR_VERSION) {
                std.debug.print("{s}: gawk API major version mismatch (expected {d}, got {d})\n", .{
                    cfg.name,
                    c.GAWK_API_MAJOR_VERSION,
                    _api.*.major_version,
                });
                return 0;
            }

            inline for (cfg.functions, 0..) |fdef, i| {
                _funcs[i] = .{
                    // Zig string literal は null 終端保証済み
                    .name = @as([*c]const u8, @ptrCast(fdef.name.ptr)),
                    .function = makeAdapter(fdef.impl),
                    .max_expected_args = @intCast(fdef.args),
                    .min_required_args = @intCast(fdef.args),
                    .suppress_lint = c.awk_false,
                    .data = null,
                };
                _ = _api.*.api_add_ext_func.?(_ext_id, "", &_funcs[i]);
            }
            return 1;
        }
    };
}

// ---------------------------------------------------------------------------
// makeAdapter: fn(Args) Result を gawk C-callable に変換する
// ---------------------------------------------------------------------------

fn makeAdapter(
    comptime impl: *const fn (Args) Result,
) fn (c_int, [*c]c.awk_value_t, [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    return struct {
        fn adapter(
            nargs: c_int,
            result: [*c]c.awk_value_t,
            _: [*c]c.awk_ext_func_t,
        ) callconv(.c) [*c]c.awk_value_t {
            const r = impl(.{ ._argc = nargs });
            return switch (r) {
                .string => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_true, result),
                .int    => |n| c.make_number(@floatFromInt(n), result),
                .bool   => |b| c.make_number(if (b) 1.0 else 0.0, result),
                .none   =>     c.make_number(0.0, result),
            };
        }
    }.adapter;
}
```

- [ ] **Step 2: テストが pass し続けることを確認**

```bash
cd /path/to/hawk/libs/binary && zig build test
```

Expected: 全 7 テスト pass。テストは `binary.zig` のみをテストするため、root.zig / gawk_ffi.zig の変更の影響を受けない。

---

## Task 4: root.zig の移行

> **Difficulty: MEDIUM** (推奨モデル: sonnet)

**Files:**
- Rewrite: `libs/binary/src/root.zig`

`@cImport` / 手動 `dl_load` / 手動関数テーブルを除去し、`ffi.makeDlLoad` ベースに移行する。

- [ ] **Step 1: root.zig を書き換え**

`libs/binary/src/root.zig` を以下の内容で完全置換する:

```zig
// SPDX-License-Identifier: MIT
// libs/binary/src/root.zig -- gawk extension entry point for binary I/O
//
// usingnamespace ffi.makeDlLoad(...) で dl_load + plugin_is_GPL_compatible を export する。
// 各関数は ffi.Args / ffi.Result を使ったシンプルな Zig 実装になる。

const std = @import("std");
const ffi = @import("gawk_ffi");
const binary = @import("binary.zig");

usingnamespace ffi.makeDlLoad(.{
    .name = "hawk_binary",
    .functions = &.{
        .{ .name = "hawk_bin_read",   .impl = &binRead,   .args = 1 },
        .{ .name = "hawk_bin_send",   .impl = &binSend,   .args = 2 },
        .{ .name = "hawk_bin_length", .impl = &binLength, .args = 1 },
    },
});

// hawk_bin_read(path) → binary content (string) or "" on error
fn binRead(args: ffi.Args) ffi.Result {
    const path = args.getString(0);
    const max_bytes: usize = blk: {
        const env = std.c.getenv("HAWK_MAX_BODY_SIZE");
        if (env == null) break :blk 1048576;
        const s = std.mem.span(env.?);
        break :blk std.fmt.parseInt(usize, s, 10) catch 1048576;
    };
    const content = binary.readAll(std.heap.c_allocator, path, max_bytes) catch return .none;
    defer std.heap.c_allocator.free(content);
    return .{ .string = content };
}

// hawk_bin_send(sock_name, content) → 1
// v0.2 stub: gawk coprocess socket は extension API からアクセス不可。
// 実際の binary 送信は core/http.awk が printf |& sock で行う。
fn binSend(_: ffi.Args) ffi.Result {
    return .{ .int = 1 };
}

// hawk_bin_length(str) → byte count
fn binLength(args: ffi.Args) ffi.Result {
    return .{ .int = @intCast(binary.lengthBytes(args.getString(0))) };
}
```

- [ ] **Step 2: ビルドが通ることを確認**

```bash
cd /path/to/hawk/libs/binary && zig build
```

Expected:
- `zig-out/lib/libhawk_binary.{so,dylib}` が生成される
- `@cImport` 関連のエラーなし
- `export fn dl_load` 重複エラーなし

もしエラーが出た場合の対処:
- `error: duplicate export 'dl_load'`: root.zig にまだ `export fn dl_load` が残っている → 確認して削除
- `error: use of undeclared identifier 'c'`: root.zig に古い `@cImport` の名残がある → 削除
- `error: no field named 'api_get_argument'`: gawkapi.h のバージョン問題 → gawk_include パスを確認

- [ ] **Step 3: unit テストが pass することを確認**

```bash
cd /path/to/hawk/libs/binary && zig build test
```

Expected: 全 7 テスト pass

- [ ] **Step 4: root.zig に @cImport が残っていないことを確認**

```bash
grep -n "@cImport\|cInclude\|cDefine" /path/to/hawk/libs/binary/src/root.zig
```

Expected: 何も出力されない (grep の exit code 1)

---

## Task 5: フル検証とコミット

> **Difficulty: LOW** (推奨モデル: haiku)

**Files:**
- 変更なし (検証のみ)

- [ ] **Step 1: make build-libs で shared library がビルドできることを確認**

```bash
cd /path/to/hawk && make build-libs
```

Expected:
```
Building libs/binary/
```
(エラーなし、`libs/binary/zig-out/lib/libhawk_binary.{so,dylib}` が存在する)

- [ ] **Step 2: make test-libs で Zig unit tests が pass することを確認**

```bash
cd /path/to/hawk && make test-libs
```

Expected:
```
Testing libs/binary/
All 7 tests passed.
```

- [ ] **Step 3: make test でフル e2e テストが pass することを確認**

```bash
cd /path/to/hawk && make test
```

Expected: unit + e2e (binary md5 整合性 check 含む) 全 pass

- [ ] **Step 4: コミット**

```bash
git add libs/_common/gawk_ffi.zig libs/binary/src/root.zig libs/binary/build.zig
git commit -m "feat(libs): complete gawk_ffi abstraction - makeDlLoad comptime + @cImport consolidation

gawk_ffi.zig に @cImport(gawkapi.h) と makeDlLoad comptime 関数を実装。
root.zig から @cImport と手動 dl_load を除去し、usingnamespace ffi.makeDlLoad(...)
一行で全 boilerplate を生成する形に移行。Args も api_get_argument calls-on-demand
方式に再設計。次の libs 追加時は root.zig が純粋な実装関数のみになる。

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage チェック:**

| spec 要件 | カバータスク |
|-----------|-------------|
| @cImport を gawk_ffi.zig に移動 | Task 3 |
| Args 再設計 (_argv → api_get_argument) | Task 3 |
| makeDlLoad comptime 実装 | Task 3 |
| usingnamespace パターン (root.zig) | Task 4 |
| build.zig ffi_mod + include path | Task 2 |
| root.zig から @cImport 除去 | Task 4 |
| make build-libs / test-libs / test pass | Task 5 |
| gawkAllocator 保持 | Task 3 |

**受入基準との照合:**
- `root.zig` に `@cImport` が存在しない → Task 4 Step 4 で grep 確認
- `make build-libs` が通る → Task 5 Step 1
- `make test-libs` 全 pass → Task 5 Step 2
- `make test` 全 pass → Task 5 Step 3
