# H-awk libs/binary (Zig native extension) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** gawk extension として `hawk_bin_read` / `hawk_bin_send` / `hawk_bin_length` を Zig で実装し、H-awk から binary-safe なファイル I/O を可能にする。

**Architecture:** `libs/_common/gawk_ffi.zig` で gawk extension C ABI を Zig wrap し、`libs/binary/` がそれを利用して 3 関数を export する。`core/static.awk` と `core/http.awk` はすでに `LIBS_LOADED["binary"]` 分岐を実装済みで、libs ビルド後にそのまま動作する。

**Tech Stack:** Zig 0.16.0, gawk 5.0+ extension API (gawkapi.h), POSIX sh, GNU make

**Reference spec:** `docs/superpowers/specs/2026-06-06-libs-zig-ext-design.md`

---

## 前提確認

- `core/libs.awk` … 実装済み (`LIBS_LOADED["binary"]` フラグ集約)
- `bin/hawk` … libs glob + `-l`/`-v` フラグ生成 実装済み
- `core/static.awk` … `LIBS_LOADED["binary"]` 分岐 実装済み
- `core/http.awk` … `res["_binary_path"]` binary 送信分岐 実装済み
- `tests/unit/test_libs.awk` … skip 機構付きテスト 実装済み
- `libs/` ディレクトリ … 空 (本計画で作成)

## 共通事項

### Zig バージョン

Zig 0.16.0 を前提とする。`zig version` で確認すること。

**Zig 0.16 の主要 build.zig API 変更点 (0.14 → 0.16):**
- `b.addSharedLibrary(.{ .version = ... })` → `version` フィールド形式変更なし
- `b.path(...)` は継続
- `addIncludePath(.{ .cwd_relative = ... })` → `.{ .path = ... }` に変更の可能性あり
- `std.mem.Allocator.VTable` の `remap` フィールド追加 (0.14 以降)
- `std.fs.cwd().writeFile(.{ .sub_path = ..., .data = ... })` → 0.13+ で使用可能
- 実装者は `zig build 2>&1` のエラーを見て都度修正すること

### awk local 変数規約

```awk
function foo(arg1, arg2,    local1, local2) { ... }
```

### コミット規約

Conventional Commits、件名 ≤50 文字、命令形、末尾ピリオドなし。

### ブランチ戦略

各タスクは `task-LZ-N-<short-name>` ブランチで作業し、完了時に master へ ff-merge。

### Subagent モデル選択

| タスク | 推奨モデル | 理由 |
|--------|-----------|------|
| Task 1 (scaffold) | haiku   | ディレクトリ作成・Makefile 追記の定型作業 |
| Task 2 (gawk_ffi.zig) | **opus** | C ABI Zig wrap、comptime 関数テーブル生成 — 最難 |
| Task 3 (binary.zig) | sonnet  | file I/O + bounded read |
| Task 4 (root.zig) | sonnet  | dl_load エントリ、ffi 呼出 |
| Task 5 (build.zig) | haiku   | 定型ビルド設定 |
| Task 6 (test_libs) | sonnet  | Zig 単体テスト + awk 統合確認 |
| Task 7 (e2e binary) | sonnet  | E2E md5 整合テスト |
| Task 8 (受入確認) | haiku   | make ci 実行 + 結果確認 |

---

## Task 1: ディレクトリスキャフォルド

**Files:**
- Create: `libs/_common/.gitkeep`
- Create: `libs/binary/src/.gitkeep`
- Create: `libs/binary/tests/.gitkeep`
- Modify: `Makefile` (build-libs / fetch-libs / test-libs / libs-clean / ci-full ターゲット更新確認)
- Modify: `.gitignore` (libs zig-out エントリ確認)

- [ ] **Step 1: ブランチ作成**

```bash
cd /Users/redpeacock78/git/hawk
git checkout master
git checkout -b task-LZ-1-scaffold
```

- [ ] **Step 2: ディレクトリ作成**

```bash
mkdir -p libs/_common libs/binary/src libs/binary/tests
touch libs/_common/.gitkeep libs/binary/src/.gitkeep libs/binary/tests/.gitkeep
```

- [ ] **Step 3: .gitignore 確認**

```bash
grep "libs/\*/zig-out" .gitignore || echo "libs/*/zig-out/" >> .gitignore
grep "libs/\*/zig-cache" .gitignore || echo "libs/*/zig-cache/" >> .gitignore
grep "libs/\*/\.zig-cache" .gitignore || echo "libs/*/.zig-cache/" >> .gitignore
```

- [ ] **Step 4: Makefile の libs ターゲット確認**

```bash
grep "build-libs\|fetch-libs\|test-libs\|libs-clean\|ci-full" Makefile
```

以下のターゲットが全て存在することを確認。なければ追加:

```makefile
build-libs: ## libs/* を全ビルド (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  [ -f "$${d}build.zig" ] || continue; \
	  echo "Building $$d"; \
	  (cd "$$d" && zig build -Doptimize=ReleaseSafe); \
	done

fetch-libs: ## GitHub Release から precompiled 取得 (Zig 不要)
	./scripts/fetch-libs.sh

test-libs: ## libs/*/zig build test (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  [ -f "$${d}build.zig" ] || continue; \
	  echo "Testing $$d"; \
	  (cd "$$d" && zig build test); \
	done

libs-clean: ## libs ビルド成果削除
	@for d in libs/*/; do rm -rf "$${d}zig-out" "$${d}zig-cache" "$${d}.zig-cache"; done

ci-full: lint test test-libs ## lint + 全テスト + libs (Zig 必要)
```

- [ ] **Step 5: make lint + make ci 動作確認 (libs なしで全 pass)**

```bash
make ci
```

期待: `103 passed, 0 failed, 3 skipped` (unit) + `11 passed` (e2e)

- [ ] **Step 6: コミット**

```bash
git add libs/ Makefile .gitignore
git commit -m "chore(libs): scaffold _common + binary dirs, verify Makefile targets"
```

- [ ] **Step 7: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-1-scaffold
```

---

## Task 2: libs/_common/gawk_ffi.zig

gawk extension C ABI を Zig comptime で wrap する共通基盤。各 libs の boilerplate を集約する。

**Files:**
- Create: `libs/_common/gawk_ffi.zig`

**重要: gawk extension API について**

gawk 5.0+ の extension API (`gawkapi.h`) の主要型:

```c
// awk_value_t: gawk の値型
typedef struct awk_value {
    awk_valtype_t val_type;      // AWK_STRING, AWK_NUMBER, AWK_UNDEFINED など
    union {
        awk_string_t s;          // {str, len}
        double d;
        // ...
    } u;
} awk_value_t;

// dl_load: extension エントリポイント
// gawk が dlopen 後に呼ぶ。api_p が gawk API へのポインタ
typedef int (*dl_load_func)(gawk_api_t *api_p, awk_ext_id_t id,
                            const char *name, awk_value_t *result,
                            size_t nargs, awk_value_t args[],
                            const char **extra_args, size_t nextra);
```

実際の gawk extension (C 言語例):
```c
static awk_value_t * my_func(int nargs, awk_value_t *result, ...) {
    awk_value_t arg;
    if (!get_argument(0, AWK_STRING, &arg)) {
        // error
    }
    const char *s = arg.str_value.str;
    make_string_malloc(result_str, len, result);
    return result;
}

static awk_ext_func_t funcs[] = {
    { "my_func", my_func, 1, 1, awk_false, NULL },
};

dl_load_func(gawk_api_t *api_p, ...) {
    api = api_p;
    for (int i = 0; i < sizeof(funcs)/sizeof(funcs[0]); i++)
        make_builtin(name, &funcs[i]);
    return 1;
}
```

Zig から C を呼ぶには `@cImport` または extern 宣言で gawkapi.h を読む。ただし macOS/Linux ともに gawk の include パスは異なる (`/usr/include/gawk` or `/opt/homebrew/include/gawk`)。

**実装方針 (spec §5.1 準拠):**

```zig
// libs/_common/gawk_ffi.zig
//
// gawk extension API の Zig ラッパ
// 各 libs の root.zig は:
//   const ffi = @import("../../_common/gawk_ffi.zig");
//   export const dl_load = ffi.makeDlLoad(cfg);
// とするだけで gawk に登録できる

pub const Args = struct { ... };
pub const Result = union(enum) { string: []const u8, int: i64, none };
pub const FuncDef = struct {
    name: []const u8,
    impl: *const fn (Args) Result,
    args: usize,
};
pub const DlLoadConfig = struct {
    name: []const u8,
    api_major: u32 = 4,
    api_minor: u32 = 0,
    functions: []const FuncDef,
};
pub fn makeDlLoad(comptime cfg: DlLoadConfig) type { ... }
pub fn gawkAllocator() std.mem.Allocator { ... }
```

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-2-gawk-ffi
```

- [ ] **Step 2: gawk extension API の include パス確認**

```bash
find /usr /opt/homebrew /usr/local -name "gawkapi.h" 2>/dev/null | head -5
```

得られたパスを記録する。存在しない場合は gawk ソースから `gawkapi.h` を確認:
```bash
gawk --version
```

- [ ] **Step 3: `libs/_common/gawk_ffi.zig` 作成**

ファイル内容:

```zig
// SPDX-License-Identifier: MIT
// libs/_common/gawk_ffi.zig -- gawk extension C ABI の Zig ラッパ
//
// gawk 5.0+ extension API (gawkapi.h) の主要部分を Zig の型システムで wrap する。
// 各 libs は ffi.makeDlLoad(.{...}) を export const dl_load に代入するだけで
// gawk extension として動作する。
//
// 使用例:
//   const ffi = @import("../../_common/gawk_ffi.zig");
//   export const dl_load = ffi.makeDlLoad(.{
//       .name = "hawk_binary",
//       .functions = &.{
//           .{ .name = "hawk_bin_read", .impl = binRead, .args = 1 },
//       },
//   });

const std = @import("std");

// ---------------------------------------------------------------------------
// gawk C ABI の extern 宣言 (gawkapi.h 相当の最小セット)
// ---------------------------------------------------------------------------

const AWK_UNDEFINED: c_int = 0;
const AWK_NUMBER: c_int = 1;
const AWK_STRING: c_int = 2;
const AWK_REGEX: c_int = 3;
const AWK_STRNUM: c_int = 4;
const AWK_ARRAY: c_int = 5;
const AWK_SCALAR: c_int = 6;
const AWK_VALUE_COOKIE: c_int = 7;
const AWK_BOOL: c_int = 8;

const AwnkFalse: c_int = 0;
const AwkTrue: c_int = 1;

const awk_string_t = extern struct {
    str: [*c]u8,
    len: usize,
};

const awk_value_t = extern struct {
    val_type: c_int,
    // union は最大 8 bytes: double か string_t
    u: extern union {
        d: f64,
        s: awk_string_t,
    },
};

// gawk API 関数テーブル (実際の gawkapi.h は 100+ エントリだが、必要なもののみ)
const GawkApiStruct = extern struct {
    major_version: c_int,
    minor_version: c_int,
    // ... 多数の関数ポインタ、オフセットを合わせるためにパディングで対処
    // 実際の実装では gawkapi.h を @cImport する

    // 簡略化: 呼び出しに使うものだけ定義
    // オフセットは gawk 5.x の実際の構造体レイアウトに依存
    // → 実装者は gawkapi.h を @cImport して正確なレイアウトを使うこと
};

// gawk が malloc/free に使う関数群 (extension から呼ぶ)
extern fn gawk_malloc(size: usize) ?*anyopaque;
extern fn gawk_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn gawk_free(ptr: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// 公開 API
// ---------------------------------------------------------------------------

/// gawk extension 関数の引数リスト
pub const Args = struct {
    // gawk が渡す argv 相当。実装は makeDlLoad が生成するクロージャ内で設定
    _argv: [*c]awk_value_t,
    _argc: c_int,

    /// i 番目の引数を []const u8 として取得
    pub fn getString(self: Args, i: usize) []const u8 {
        if (i >= @as(usize, @intCast(self._argc))) return "";
        const v = self._argv[i];
        if (v.val_type != AWK_STRING and v.val_type != AWK_STRNUM) return "";
        return v.u.s.str[0..v.u.s.len];
    }

    /// i 番目の引数を i64 として取得
    pub fn getInt(self: Args, i: usize) i64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0;
        const v = self._argv[i];
        if (v.val_type != AWK_NUMBER) return 0;
        return @intFromFloat(v.u.d);
    }

    /// i 番目の引数を f64 として取得
    pub fn getDouble(self: Args, i: usize) f64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0.0;
        const v = self._argv[i];
        if (v.val_type != AWK_NUMBER) return 0.0;
        return v.u.d;
    }
};

/// gawk extension 関数の戻り値
pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};

/// gawk extension 関数定義
pub const FuncDef = struct {
    name: []const u8,
    impl: *const fn (Args) Result,
    args: usize,
};

/// makeDlLoad に渡す設定
pub const DlLoadConfig = struct {
    name: []const u8,
    api_major: u32 = 4,
    api_minor: u32 = 0,
    functions: []const FuncDef,
};

/// gawk_malloc ベースの Allocator
pub fn gawkAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &gawk_allocator_vtable,
    };
}

const gawk_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = gawkAlloc,
    .resize = gawkResize,
    .remap = gawkRemap,
    .free = gawkFreeSlice,
};

fn gawkAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr = gawk_malloc(n) orelse return null;
    return @ptrCast(ptr);
}

fn gawkResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    _ = buf;
    _ = new_len;
    return false; // gawk_realloc は安全に使いにくいため resize は不サポート
}

fn gawkRemap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const new_ptr = gawk_realloc(buf.ptr, new_len) orelse return null;
    return @ptrCast(new_ptr);
}

fn gawkFreeSlice(_: *anyopaque, slice: []u8, _: std.mem.Alignment, _: usize) void {
    gawk_free(slice.ptr);
}

// ---------------------------------------------------------------------------
// makeDlLoad: comptime で dl_load 関数を生成
// ---------------------------------------------------------------------------
//
// gawk が dlopen 後に呼ぶエントリポイント。
// 実装上の注意:
//   gawkapi.h の実際の型は @cImport で取り込むのが確実だが、
//   gawk のインクルードパスは環境依存 (build.zig で addIncludePath を使う)。
//   本ファイルでは抽象 API のみ定義し、実際の C ABI 呼出は root.zig 側の
//   @cImport + make_builtin() で行う構成も可。
//
// 推奨実装パターン (root.zig 側):
//   @cImport でgawkapi.hをインポートし、dl_load_func シグネチャに合わせた
//   export fn を定義して、各関数を make_builtin で登録する。
//   gawk_ffi.zig は Args/Result/FuncDef の共通型と gawkAllocator を提供する
//   ユーティリティライブラリとして使う。
//
// この設計により root.zig が @cImport の詳細を担い、
// gawk_ffi.zig はビルド環境に依存しない純粋な Zig コードとなる。

pub const ExtensionEntry = struct {
    // root.zig が自分で dl_load を定義する場合はこの型は不要。
    // comptime makeDlLoad が root.zig の export fn を返す場合に使う。
    // 詳細は Task 4 (root.zig) で実装する。
    config: DlLoadConfig,
};

pub fn makeDlLoad(comptime cfg: DlLoadConfig) ExtensionEntry {
    return .{ .config = cfg };
}
```

**重要:** gawk extension の実際の C ABI 呼び出し (`make_builtin`, `get_argument`, `make_string_malloc` 等) は gawkapi.h の `@cImport` が必要。`build.zig` の `addIncludePath` でパスを渡す。Step 2 で見つけた gawkapi.h のパスを使うこと。

- [ ] **Step 4: `libs/_common/build_helper.zig` 作成**

```zig
// SPDX-License-Identifier: MIT
// libs/_common/build_helper.zig -- 各 libs の build.zig 共通ヘルパ

const std = @import("std");

pub const ExtensionConfig = struct {
    name: []const u8,
    source_root: []const u8,
    test_root: ?[]const u8 = null,
};

/// 共有ライブラリ (.so / .dylib) + テストターゲットを登録
pub fn makeExtension(b: *std.Build, cfg: ExtensionConfig) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const target = b.standardTargetOptions(.{});

    const lib = b.addSharedLibrary(.{
        .name = cfg.name,
        .root_source_file = b.path(cfg.source_root),
        .target = target,
        .optimize = optimize,
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
    });

    // gawk include パス (環境変数 GAWK_INCLUDE_PATH で上書き可)
    const gawk_include = std.process.getEnvVarOwned(b.allocator, "GAWK_INCLUDE_PATH") catch blk: {
        // デフォルト候補を試す
        const candidates = [_][]const u8{
            "/opt/homebrew/include/gawk",
            "/usr/local/include/gawk",
            "/usr/include/gawk",
        };
        for (candidates) |p| {
            std.fs.accessAbsolute(p, .{}) catch continue;
            break :blk b.allocator.dupe(u8, p) catch p;
        }
        break :blk @as([]const u8, "");
    };
    if (gawk_include.len > 0) {
        lib.addIncludePath(.{ .cwd_relative = gawk_include });
    }

    // _common を module として追加
    const common_mod = b.addModule("gawk_ffi", .{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
    });
    lib.root_module.addImport("gawk_ffi", common_mod);

    b.installArtifact(lib);

    // テスト
    if (cfg.test_root) |tr| {
        const tests = b.addTest(.{
            .root_source_file = b.path(tr),
            .target = target,
            .optimize = optimize,
        });
        tests.root_module.addImport("gawk_ffi", common_mod);
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);
    }
}
```

- [ ] **Step 5: コミット**

```bash
git add libs/_common/
git commit -m "feat(libs): add gawk_ffi.zig + build_helper.zig common infrastructure"
```

- [ ] **Step 6: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-2-gawk-ffi
```

---

## Task 3: libs/binary/src/binary.zig

binary-safe file I/O の実装本体。gawk 無依存の純粋 Zig モジュール。

**Files:**
- Create: `libs/binary/src/binary.zig`

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-3-binary-impl
```

- [ ] **Step 2: `libs/binary/src/binary.zig` 作成**

```zig
// SPDX-License-Identifier: MIT
// libs/binary/src/binary.zig -- binary-safe file I/O 実装
//
// gawk とは独立した純粋 Zig モジュール。root.zig から呼ばれる。

const std = @import("std");

/// ファイルを binary-safe に読込む。
/// 戻り値は allocator が所有するスライス。呼出元が free する責務を持つ。
/// 失敗時は error を返す (呼出元が空文字列に変換)。
pub fn readAll(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    if (size > max_bytes) {
        std.log.warn("hawk_bin_read: file size {d} exceeds max {d}: {s}", .{ size, max_bytes, path });
        return error.FileTooLarge;
    }

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    const n = try file.readAll(buf);
    if (n != size) {
        allocator.free(buf);
        return error.ReadIncomplete;
    }

    return buf;
}

/// バイト長を返す (length() の代替: gawk の length() は文字数カウント)
pub fn lengthBytes(s: []const u8) usize {
    return s.len;
}
```

- [ ] **Step 3: コミット**

```bash
git add libs/binary/src/binary.zig
git commit -m "feat(libs/binary): implement binary-safe readAll + lengthBytes"
```

- [ ] **Step 4: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-3-binary-impl
```

---

## Task 4: libs/binary/src/root.zig

gawk extension エントリポイント。`dl_load` を export し、3 関数を gawk に登録する。

**Files:**
- Create: `libs/binary/src/root.zig`

**gawk extension C API 重要メモ:**

gawkapi.h を `@cImport` して使う。主要な C 関数:
- `get_argument(idx, type, result)` → 引数取得
- `make_string_malloc(str, len, result)` → 文字列戻り値 (gawk が free する)
- `make_number(d, result)` → 数値戻り値
- `make_builtin(name, funcdef)` → 関数登録
- `api->api_major_version` → バージョン確認

`awk_ext_func_t` 構造体:
```c
typedef struct awk_ext_func {
    const char *name;
    awk_value_t *(*function)(int nargs, awk_value_t *result, struct awk_ext_func *finfo);
    size_t max_expected_args;
    size_t min_required_args;
    awk_bool_t suppress_lint;
    void *extra_data;
} awk_ext_func_t;
```

`dl_load_func` シグネチャ:
```c
int dl_load(const gawk_api_t *api_p, awk_ext_id_t ext_id);
```

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-4-root-entry
```

- [ ] **Step 2: gawkapi.h のパス確認**

```bash
find /opt/homebrew /usr/local /usr -name "gawkapi.h" 2>/dev/null
```

以降のコードの `addIncludePath` でこのパスを使う。

- [ ] **Step 3: `libs/binary/src/root.zig` 作成**

```zig
// SPDX-License-Identifier: MIT
// libs/binary/src/root.zig -- gawk extension エントリポイント
//
// gawk が dlopen 後に dl_load を呼ぶ。
// hawk_bin_read / hawk_bin_send / hawk_bin_length を gawk に登録する。

const std = @import("std");
const binary = @import("binary.zig");

// gawk C API を取り込む (gawkapi.h)
// build.zig の addIncludePath で gawk ヘッダのパスを渡すこと
const c = @cImport({
    @cDefine("GAWK", "1");
    @cInclude("gawkapi.h");
});

// gawk API ポインタ (dl_load で設定)
var api: *const c.gawk_api_t = undefined;
var ext_id: c.awk_ext_id_t = undefined;

// ---------------------------------------------------------------------------
// hawk_bin_read(path) → string
//   ファイルを binary-safe に読込み、gawk 文字列として返す。
//   失敗時は空文字列。
// ---------------------------------------------------------------------------
fn binRead(nargs: c_int, result: *c.awk_value_t, _: *c.awk_ext_func_t) callconv(.C) *c.awk_value_t {
    _ = nargs;
    var path_val: c.awk_value_t = undefined;
    if (api.*.get_argument.?(ext_id, 0, c.AWK_STRING, &path_val) == 0) {
        _ = api.*.make_string_malloc.?(ext_id, "", 0, result);
        return result;
    }
    const path = path_val.u.s.str[0..path_val.u.s.len];

    const max_bytes_env = std.process.getEnvVarOwned(std.heap.c_allocator, "HAWK_MAX_BODY_SIZE") catch "";
    defer if (max_bytes_env.len > 0) std.heap.c_allocator.free(max_bytes_env);
    const max_bytes: usize = if (max_bytes_env.len > 0)
        std.fmt.parseInt(usize, max_bytes_env, 10) catch 1048576
    else
        1048576;

    const allocator = std.heap.c_allocator;
    const content = binary.readAll(allocator, path, max_bytes) catch |err| {
        std.log.warn("hawk_bin_read error {s}: {s}", .{ @errorName(err), path });
        _ = api.*.make_string_malloc.?(ext_id, "", 0, result);
        return result;
    };
    defer allocator.free(content);

    _ = api.*.make_string_malloc.?(ext_id, content.ptr, content.len, result);
    return result;
}

// ---------------------------------------------------------------------------
// hawk_bin_send(sock_name, content) → number (1=ok, 0=fail)
//   gawk の coprocess socket に binary content を書き込む。
//   gawk の printf "%s" ... |& sock と同等だが binary-safe。
//
//   現 MVP 実装: gawk の内部 socket API は extension から直接アクセス不可。
//   代替: /proc/self/fd または pipe 経由で書き込む。
//   → v0.2 では hawk_bin_send は常に 1 を返す stub とし、
//     実際の socket 書き込みは http.awk 側の printf で行う。
//     (gawk は \0 含む文字列を printf "%s" |& sock で送出できる)
// ---------------------------------------------------------------------------
fn binSend(nargs: c_int, result: *c.awk_value_t, _: *c.awk_ext_func_t) callconv(.C) *c.awk_value_t {
    _ = nargs;
    // stub: 常に 1 (success) を返す
    _ = api.*.make_number.?(ext_id, 1.0, result);
    return result;
}

// ---------------------------------------------------------------------------
// hawk_bin_length(content) → number (byte count)
// ---------------------------------------------------------------------------
fn binLength(nargs: c_int, result: *c.awk_value_t, _: *c.awk_ext_func_t) callconv(.C) *c.awk_value_t {
    _ = nargs;
    var content_val: c.awk_value_t = undefined;
    if (api.*.get_argument.?(ext_id, 0, c.AWK_STRING, &content_val) == 0) {
        _ = api.*.make_number.?(ext_id, 0.0, result);
        return result;
    }
    const len = binary.lengthBytes(content_val.u.s.str[0..content_val.u.s.len]);
    _ = api.*.make_number.?(ext_id, @as(f64, @floatFromInt(len)), result);
    return result;
}

// ---------------------------------------------------------------------------
// gawk extension 関数テーブル
// ---------------------------------------------------------------------------
const funcs = [_]c.awk_ext_func_t{
    .{
        .name = "hawk_bin_read",
        .function = binRead,
        .max_expected_args = 1,
        .min_required_args = 1,
        .suppress_lint = c.awk_false,
        .extra_data = null,
    },
    .{
        .name = "hawk_bin_send",
        .function = binSend,
        .max_expected_args = 2,
        .min_required_args = 2,
        .suppress_lint = c.awk_false,
        .extra_data = null,
    },
    .{
        .name = "hawk_bin_length",
        .function = binLength,
        .max_expected_args = 1,
        .min_required_args = 1,
        .suppress_lint = c.awk_false,
        .extra_data = null,
    },
};

// ---------------------------------------------------------------------------
// dl_load: gawk extension エントリポイント
// ---------------------------------------------------------------------------
export fn dl_load(api_p: *const c.gawk_api_t, id: c.awk_ext_id_t) c_int {
    api = api_p;
    ext_id = id;

    // API バージョン確認
    if (api.*.major_version != c.GAWK_API_MAJOR_VERSION) {
        // バージョン不一致: stderr に警告して続行 (クラッシュより良い)
        _ = std.io.getStdErr().write(
            "hawk_binary: gawk API version mismatch\n",
        ) catch {};
        return 0;
    }

    for (&funcs) |*f| {
        _ = api.*.make_builtin.?(id, "hawk_binary", @constCast(f));
    }
    return 1;
}
```

**注意事項:**
- `hawk_bin_send` は v0.2 では stub。gawk の `/inet/tcp` coprocess socket への直接書き込みは extension API から非対応のため、`http.awk` 側の `printf "%s", content |& sock` で対応。
- `std.heap.c_allocator` を使用 (gawk プロセス内では libc が利用可能)。

- [ ] **Step 4: コミット**

```bash
git add libs/binary/src/root.zig
git commit -m "feat(libs/binary): implement dl_load entry with hawk_bin_read/send/length"
```

- [ ] **Step 5: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-4-root-entry
```

---

## Task 5: libs/binary/build.zig

ビルド設定。gawkapi.h のインクルードパス自動検出。

**Files:**
- Create: `libs/binary/build.zig`

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-5-build-zig
```

- [ ] **Step 2: `libs/binary/build.zig` 作成**

```zig
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // 共有ライブラリ: libhawk_binary.{so,dylib}
    const lib = b.addSharedLibrary(.{
        .name = "hawk_binary",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
    });

    // gawkapi.h のインクルードパスを自動検出
    // 環境変数 GAWK_INCLUDE_PATH で明示指定も可
    const gawk_include = b.option(
        []const u8,
        "gawk-include",
        "Path to gawkapi.h directory",
    ) orelse findGawkInclude(b) orelse "";

    if (gawk_include.len > 0) {
        lib.addIncludePath(.{ .cwd_relative = gawk_include });
    } else {
        @panic("gawkapi.h not found. Set -Dgawk-include=/path/to/gawk/include or GAWK_INCLUDE_PATH");
    }

    // _common モジュール
    const ffi_mod = b.addModule("gawk_ffi", .{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
    });
    lib.root_module.addImport("gawk_ffi", ffi_mod);

    // libc リンク (gawk 内の malloc を使うため)
    lib.linkLibC();

    b.installArtifact(lib);

    // Zig 単体テスト (binary.zig のテスト、gawk 不要)
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("tests/binary_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn findGawkInclude(b: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/include/gawk",
        "/usr/local/include/gawk",
        "/usr/include/gawk",
        "/opt/homebrew/Cellar/gawk",  // homebrew 詳細パス (ワイルドカード不可→上でカバー)
    };
    for (candidates) |p| {
        const check = b.pathJoin(&.{ p, "gawkapi.h" });
        std.fs.accessAbsolute(check, .{}) catch continue;
        return p;
    }
    // GAWK_INCLUDE_PATH 環境変数
    return std.process.getEnvVarOwned(b.allocator, "GAWK_INCLUDE_PATH") catch null;
}
```

- [ ] **Step 3: ビルドテスト**

```bash
cd libs/binary
zig build 2>&1
```

期待: `libs/binary/zig-out/lib/libhawk_binary.{so,dylib}` が生成される。
エラーが出た場合、gawkapi.h のパスを `-Dgawk-include=<path>` で指定して再試行:
```bash
zig build -Dgawk-include=/opt/homebrew/include/gawk
```

- [ ] **Step 4: コミット**

```bash
cd /Users/redpeacock78/git/hawk
git add libs/binary/build.zig
git commit -m "feat(libs/binary): add build.zig with auto gawkapi.h detection"
```

- [ ] **Step 5: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-5-build-zig
```

---

## Task 6: Zig 単体テスト

`binary.zig` のテスト。gawk 不要。`zig build test` で実行。

**Files:**
- Create: `libs/binary/tests/binary_test.zig`

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-6-zig-tests
```

- [ ] **Step 2: `libs/binary/tests/binary_test.zig` 作成**

```zig
// SPDX-License-Identifier: MIT
const std = @import("std");
const binary = @import("../src/binary.zig");

test "readAll: text file" {
    const tmp = "/tmp/hawk_zig_test_text";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello world" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const allocator = std.testing.allocator;
    const content = try binary.readAll(allocator, tmp, 1048576);
    defer allocator.free(content);

    try std.testing.expectEqualSlices(u8, "hello world", content);
}

test "readAll: binary bytes (null bytes)" {
    const tmp = "/tmp/hawk_zig_test_bin";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "\x00\x01\xff\x7f\x80" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const allocator = std.testing.allocator;
    const content = try binary.readAll(allocator, tmp, 1048576);
    defer allocator.free(content);

    try std.testing.expectEqualSlices(u8, "\x00\x01\xff\x7f\x80", content);
}

test "readAll: missing file returns error" {
    const allocator = std.testing.allocator;
    const result = binary.readAll(allocator, "/tmp/hawk_zig_nonexistent_file", 1048576);
    try std.testing.expectError(error.FileNotFound, result);
}

test "readAll: file exceeds max_bytes returns FileTooLarge" {
    const tmp = "/tmp/hawk_zig_test_large";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "abcde" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const allocator = std.testing.allocator;
    const result = binary.readAll(allocator, tmp, 3); // max 3 bytes, file is 5
    try std.testing.expectError(error.FileTooLarge, result);
}

test "lengthBytes: ascii" {
    try std.testing.expectEqual(@as(usize, 5), binary.lengthBytes("hello"));
}

test "lengthBytes: binary bytes" {
    try std.testing.expectEqual(@as(usize, 3), binary.lengthBytes("\xff\xfe\xfd"));
}

test "lengthBytes: empty" {
    try std.testing.expectEqual(@as(usize, 0), binary.lengthBytes(""));
}
```

- [ ] **Step 3: テスト実行**

```bash
cd /Users/redpeacock78/git/hawk/libs/binary
zig build test
```

期待: `7/7 tests passed`

- [ ] **Step 4: make test-libs 確認**

```bash
cd /Users/redpeacock78/git/hawk
make test-libs
```

期待: `Testing libs/binary/` → `7/7 tests passed`

- [ ] **Step 5: コミット**

```bash
git add libs/binary/tests/
git commit -m "test(libs/binary): add Zig unit tests for readAll + lengthBytes"
```

- [ ] **Step 6: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-6-zig-tests
```

---

## Task 7: awk 統合テスト + E2E binary 整合テスト

libs ビルド後の統合確認。awk 側から `hawk_bin_read` / `hawk_bin_length` を呼び出す。

**Files:**
- Verify: `tests/unit/test_libs.awk` (内容確認、不足なら追加)
- Verify: `tests/unit/run.awk` (test_libs 呼出し確認)
- Modify: `tests/e2e/run.sh` (binary md5 整合テスト追加)

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-7-integration-tests
```

- [ ] **Step 2: test_libs.awk の現状確認**

```bash
cat tests/unit/test_libs.awk
```

以下の 3 テスト関数が存在することを確認:
- `test_libs_binary_length` — `hawk_bin_length("hello")` = 5
- `test_libs_binary_read_text` — ファイル読込みテキスト
- `test_libs_binary_read_missing` — 存在しないファイル → ""

不足があれば追加する。

- [ ] **Step 3: run.awk の test_libs 呼出し確認**

```bash
grep "test_libs" tests/unit/run.awk
```

以下が存在することを確認:
```awk
test_libs_binary_length()
test_libs_binary_read_text()
test_libs_binary_read_missing()
```

- [ ] **Step 4: libs ビルド後のユニットテスト実行**

```bash
make build-libs && make test-unit
```

期待: libs ありで `106 passed` 以上 (3 skipped が 0 になる)。libs なしなら `3 skipped` のまま。

- [ ] **Step 5: E2E binary 整合テスト追加**

`tests/e2e/run.sh` に以下を追加 (既存テストの末尾):

```sh
# ---- binary integrity test (libs/binary が必要) ----
_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    echo ""
  fi
}

FAVICON="public/favicon.ico"
if [ ! -f "$FAVICON" ]; then
  echo "SKIP: $FAVICON not found (binary integrity)"
else
  ORIG_MD5=$(_md5 "$FAVICON")
  TMP_RECV=$(mktemp)
  curl -s "http://127.0.0.1:${PORT}/favicon.ico" -o "$TMP_RECV"
  RECV_MD5=$(_md5 "$TMP_RECV")
  rm -f "$TMP_RECV"

  LIB_SO=""
  for ext in so dylib; do
    if [ -f "libs/binary/zig-out/lib/libhawk_binary.${ext}" ]; then
      LIB_SO="found"; break
    fi
  done

  if [ -z "$ORIG_MD5" ]; then
    echo "SKIP: md5 tool not found"
    SKIP=$((SKIP + 1))
  elif [ "$ORIG_MD5" = "$RECV_MD5" ]; then
    echo "PASS: binary integrity (favicon.ico md5 matches)"
    PASS=$((PASS + 1))
  elif [ -z "$LIB_SO" ]; then
    echo "SKIP: libs/binary not built (binary integrity requires it)"
    SKIP=$((SKIP + 1))
  else
    echo "FAIL: binary integrity (orig=$ORIG_MD5 served=$RECV_MD5)" >&2
    FAIL=$((FAIL + 1))
  fi
fi
```

`tests/e2e/run.sh` の結果出力部分に `SKIP` カウンタが含まれているか確認し、なければ追加。

- [ ] **Step 6: E2E テスト実行 (libs なし)**

```bash
make test-e2e
```

期待: binary integrity テストは `SKIP` になる (libs 未ビルドのため)。

- [ ] **Step 7: libs ビルド後の E2E テスト実行**

```bash
make build-libs && make test-e2e
```

期待: `PASS: binary integrity (favicon.ico md5 matches)`

favicon.ico が `public/` に存在しない場合は `SKIP` で OK (テストはスキップ扱い)。

- [ ] **Step 8: make ci-full 全体確認**

```bash
make ci-full
```

期待: lint + unit + e2e + test-libs 全 pass (または適切な skip)

- [ ] **Step 9: コミット**

```bash
git add tests/e2e/run.sh tests/unit/test_libs.awk tests/unit/run.awk
git commit -m "test(libs): add binary integrity E2E test + verify awk unit tests"
```

- [ ] **Step 10: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-7-integration-tests
```

---

## Task 8: 受入基準確認

spec §15 の受入基準を全項目チェック。

**Files:** なし (確認のみ)

- [ ] **Step 1: ブランチ作成**

```bash
git checkout master
git checkout -b task-LZ-8-acceptance
```

- [ ] **Step 2: 受入基準チェック**

以下を順番に実行し、すべて pass/skip を確認:

```bash
# 1. make build-libs (Zig 0.14+)
make build-libs
ls libs/binary/zig-out/lib/

# 2. make test-libs (Zig 単体テスト)
make test-libs

# 3. make test (unit + e2e + libs)
make test

# 4. libs なしで make ci (warning が出るが test は全 pass)
make libs-clean && make ci

# 5. libs ありで make ci-full
make build-libs && make ci-full
```

- [ ] **Step 3: 結果記録**

以下の形式で結果を確認:

```
make build-libs: ✅ libs/binary/zig-out/lib/libhawk_binary.{so,dylib} 生成
make test-libs:  ✅ N/N tests passed
make test:       ✅ N passed, 0 failed, N skipped (libs あり)
make ci (libs なし): ✅ warning 表示 + test 全 pass
make ci-full:    ✅ 全 pass
```

- [ ] **Step 4: コミット**

変更があれば:
```bash
git add -A
git commit -m "chore(libs): acceptance criteria verified for v0.2"
```

変更なければスキップ。

- [ ] **Step 5: master へ ff-merge**

```bash
git checkout master
git merge --ff-only task-LZ-8-acceptance
```

---

## spec からの差分・注意事項

### hawk_bin_send の実装制限

spec §4.1 では `hawk_bin_send(sock_name, content)` がソケットに直接書き込む設計だが、gawk の `/inet/tcp` coprocess は extension API からアクセスできない。v0.2 では stub (常に 1 を返す) とし、実際の binary 送信は `http.awk` の `printf "%s", content |& sock` で行う (gawk は null byte 含む文字列を printf で送出可能)。

`core/http.awk` の `http_send` はすでにこの方式で実装済み:
```awk
if (res["_binary_path"] != "" && LIBS_LOADED["binary"]) {
    content = hawk_bin_read(res["_binary_path"])
    ...
    printf "%s", content |& sock
}
```

### gawkapi.h のパス

環境によって異なる:
- macOS homebrew: `/opt/homebrew/include/gawk/gawkapi.h`
- Linux: `/usr/include/gawk/gawkapi.h`

`build.zig` の `findGawkInclude` で自動検出。見つからない場合は `-Dgawk-include=<path>` で指定。

### Zig 0.16 API

本計画のコードは Zig 0.16.0 を前提として記述している。build.zig の API は毎マイナーバージョンで変更されるため、`zig build` のエラーメッセージを見て都度修正すること。`zig version` で 0.16.x であることを確認してから実装開始すること。
