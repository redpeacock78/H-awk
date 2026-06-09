# gawk_ffi.zig 完成 & gawk extension 抽象化層 設計仕様書

- **プロジェクト名**: H-awk
- **サブシステム**: `libs/_common/gawk_ffi.zig`
- **作成日**: 2026-06-09
- **対象バージョン**: H-awk v0.2
- **ステータス**: 設計承認済み
- **前提仕様**: [`2026-06-06-libs-zig-ext-design.md`](2026-06-06-libs-zig-ext-design.md)

## 1. 概要

`libs/_common/gawk_ffi.zig` に `makeDlLoad` comptime 関数を実装し、gawk extension の boilerplate を完全集約する。各 lib の `root.zig` は `@cImport` を持たず、ビジネスロジック関数のみを記述する形にする。

## 2. 変更スコープ

### 変更ファイル

- `libs/_common/gawk_ffi.zig` — @cImport 追加 + `makeDlLoad` 実装 + `Args` 再設計
- `libs/binary/src/root.zig` — @cImport 除去、`usingnamespace ffi.makeDlLoad(...)` に置換
- `libs/binary/build.zig` — ffi モジュールへの include path / link_libc 追加

### 変更しないファイル

- `libs/binary/src/binary.zig` — ファイル I/O ロジックは変更なし
- `libs/binary/tests/binary_test.zig` — テスト変更なし
- `core/*.awk` / `bin/hawk` — awk 層は変更なし

## 3. gawk_ffi.zig 設計

### 3.1 @cImport の移動

`gawk_ffi.zig` が `gawkapi.h` を @cImport する。個々の lib の `root.zig` から @cImport を除去する。

```zig
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stddef.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("gawkapi.h");
});
```

### 3.2 Args の再設計

現在の `Args._argv: [*c]awk_value_t` は gawk の実際の API と一致しない。gawk は `api_get_argument(ext_id, index, type, &val)` をインデックスごとに呼ぶ方式。

変更後: `_argc: c_int` のみ保持。`getString` 等は module-level グローバル `_api` / `_ext_id` 経由で `api_get_argument` を呼ぶ。`_api` / `_ext_id` は `dl_load` 呼出時に初期化。gawk extension はシングルスレッド保証のためグローバルで問題ない。

```zig
var _api: *const c.gawk_api_t = undefined;
var _ext_id: c.awk_ext_id_t = undefined;

pub const Args = struct {
    _argc: c_int,

    pub fn getString(self: Args, i: usize) []const u8 {
        if (i >= @as(usize, @intCast(self._argc))) return "";
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_STRING, &v) == c.awk_false) return "";
        return v.u.s.str[0..v.u.s.len];
    }

    pub fn getInt(self: Args, i: usize) i64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0;
        return @intFromFloat(v.u.d);
    }

    pub fn getDouble(self: Args, i: usize) f64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0.0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0.0;
        return v.u.d;
    }
};
```

### 3.3 makeDlLoad comptime 関数

`makeDlLoad` は comptime で各関数の C-callable adapter を生成し、`export fn dl_load` と `export var plugin_is_GPL_compatible` を持つ型を返す。各 lib は `usingnamespace ffi.makeDlLoad(...)` でこれらを file scope に展開する。

```zig
pub fn makeDlLoad(comptime cfg: DlLoadConfig) type {
    return struct {
        // 関数テーブルは dl_load 終了後も gawk が参照するため static
        var _funcs: [cfg.functions.len]c.awk_ext_func_t = undefined;

        export var plugin_is_GPL_compatible: c_int = 1;

        export fn dl_load(api_p: [*c]const c.gawk_api_t, id: c.awk_ext_id_t) c_int {
            if (api_p == null) return 0;
            _api = api_p.?;
            _ext_id = id;

            if (_api.*.major_version != c.GAWK_API_MAJOR_VERSION) {
                std.debug.print("{s}: gawk API major version mismatch\n", .{cfg.name});
                return 0;
            }

            inline for (cfg.functions, 0..) |fdef, i| {
                _funcs[i] = .{
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
```

### 3.4 Adapter 関数

各 `fn(Args) Result` を gawk C-callable wrapper に変換する内部ヘルパ。

```zig
fn makeAdapter(comptime impl: *const fn (Args) Result) fn (c_int, [*c]c.awk_value_t, [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    return struct {
        fn adapter(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
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

## 4. root.zig 最終形

```zig
// SPDX-License-Identifier: MIT
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

fn binSend(_: ffi.Args) ffi.Result { return .{ .int = 1 }; }

fn binLength(args: ffi.Args) ffi.Result {
    return .{ .int = @intCast(binary.lengthBytes(args.getString(0))) };
}
```

## 5. build.zig 変更

ffi モジュールに gawk の include path と link_libc を追加する。

```zig
const ffi_mod = b.createModule(.{
    .root_source_file = b.path("../_common/gawk_ffi.zig"),
    .link_libc = true,
});
ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });
lib.root_module.addImport("gawk_ffi", ffi_mod);
```

## 6. gawk_ffi.zig から廃止するコード

不要になるもの（@cImport で置換される）:
- `awk_string_t` extern struct 定義
- `awk_value_t` extern struct 定義
- `AWK_*` 定数 / `AwkFalse` / `AwkTrue`
- `Args._argv: [*c]awk_value_t` フィールド

引き続き保持するもの:
- `gawkAllocator()` — 将来の libs/multipart 等で使用予定
- `FuncDef`, `DlLoadConfig`, `Result`, `Args`（再設計版）

## 7. テスト戦略

- `libs/binary/tests/binary_test.zig` — binary.zig は変更なし、テスト変更なし
- `zig build` でビルド成功確認 (libhawk_binary.{so,dylib} 生成)
- `make test-libs` で Zig unit tests 全 pass 確認
- `make test` で e2e テスト (binary 整合性 md5 check) 全 pass 確認

## 8. 受入基準

- `root.zig` に `@cImport` が存在しない
- `make build-libs` が通る
- `make test-libs` が全 pass
- `make test` が全 pass (e2e binary md5 check 含む)
