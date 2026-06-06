# H-awk libs (Zig native extension) 設計仕様書

- **プロジェクト名**: H-awk
- **サブシステム**: `libs/` (Zig 製 gawk extension 群)
- **作成日**: 2026-06-06
- **対象バージョン**: H-awk v0.2 (libs MVP)
- **ステータス**: Draft (ブレスト承認済、実装計画作成前)
- **前提仕様**: [`2026-06-06-h-awk-design.md`](2026-06-06-h-awk-design.md)

## 1. 概要

H-awk のコアは pure awk を維持しつつ、`awk` の言語特性上 原理的に実装が困難な機能 (binary-safe I/O / multipart parse / 暗号 / 圧縮など) を `libs/<name>/` 配下の Zig 製 gawk extension として提供する。

ユーザー (`app.awk` 作成者) からは Zig の存在は完全に透過化される。core/*.awk が optional dependency として libs を裏で呼び出し、libs 不在時は graceful degrade で機能が一部制限されるのみとなる。

### 1.1 目的

- pure awk では困難な機能 (binary I/O 等) を実用レベルで提供する
- ユーザーは awk のみでアプリケーションを記述できる体験を維持する
- 各機能を独立したライブラリとして分離し、必要なものだけビルド / 配布できる構造とする

### 1.2 非目標 (libs spec v0.1)

- ユーザー側 (app.awk / plugins) からの直接利用を必須にすること (libs は裏方)
- 5 種類すべての libs 同時提供 (本 spec の MVP は libs/binary のみ)
- Windows native サポート (WSL 経由のみ)
- musl libc 対応

### 1.3 スローガン補正

> **「awk でシンプルに書こう、難しい所は Zig が裏で頑張る」**

core = pure awk、libs = Zig 製裏方、plugins = ユーザー拡張 という 3 層構造で責務を明確化する。

## 2. アーキテクチャ概観

```
┌──────────────────────────────────────────────┐
│  ユーザー領域                                  │
│  ├── app.awk          (ルート登録 + handler)  │
│  └── plugins/<name>/  (フック経由拡張)         │
└──────────────┬───────────────────────────────┘
               │ 呼出
               ▼
┌──────────────────────────────────────────────┐
│  core/*.awk           (pure awk、動作必須)    │
│  ├── http / router / request / response       │
│  ├── static / template / tsv / json / util    │
│  ├── libs (← v0.2 新規、LIBS_LOADED 集約)     │
│  └── plugin (フック呼出)                      │
└──────────────┬───────────────────────────────┘
               │ optional 呼出 (libs 存在時)
               ▼
┌──────────────────────────────────────────────┐
│  libs/<name>/         (Zig 製 gawk extension) │
│  ├── binary    -- binary-safe file I/O        │
│  ├── multipart (v0.3) -- multipart parse      │
│  ├── crypto    (v0.3) -- sha256/hmac/argon2   │
│  ├── gzip      (v0.4) -- gzip 圧縮            │
│  └── url       (v0.4) -- url_decode 高速化    │
│                                               │
│  共通基盤:                                    │
│  └── libs/_common/gawk_ffi.zig                │
│      (gawk extension API → Zig 型 marshalling)│
└──────────────────────────────────────────────┘
```

### 2.1 責務分離

- **app.awk / plugins/**: ユーザー領域。awk のみ。libs の存在を意識する必要はない
- **core/*.awk**: pure awk、動作必須。libs 不在でも全機能 (一部 binary 配信や crypto 系を除く) が動く
- **libs/<name>/**: 各機能ごとの Zig 製 native extension。core が裏で optional 呼出。`LIBS_LOADED["<name>"] = 1` が立っているかで分岐する
- **libs/_common/**: gawk extension API のラッパと build.zig 共通ヘルパ

## 3. ディレクトリ構成

```
hawk/
├── bin/hawk                  # libs glob + AWKLIBPATH export 追加
├── core/*.awk                # 既存 (変更最小)
│   ├── libs.awk              # ★新規: LIBS_LOADED 集約
│   ├── static.awk            # libs/binary 振分追加
│   └── http.awk              # res["_binary_path"] 経由 binary 送信
├── hawk.awk                  # @include "core/libs.awk" 追加
├── libs/                     # ★新規
│   ├── _common/
│   │   ├── gawk_ffi.zig      # gawk extension API ⇄ Zig 型 marshalling
│   │   └── build_helper.zig  # build.zig 共通ヘルパ
│   ├── binary/
│   │   ├── build.zig
│   │   ├── src/
│   │   │   ├── root.zig      # gawk extension エントリ (dl_load_func)
│   │   │   └── binary.zig    # file_read_bin / send_bin 実装
│   │   ├── tests/
│   │   │   └── binary_test.zig
│   │   └── zig-out/lib/      # ビルド成果物 (gitignore)
│   │       └── libhawk_binary.{so,dylib}
│   └── README.md             # libs 追加方法 / precompiled DL 説明
├── scripts/
│   └── fetch-libs.sh         # ★新規: precompiled .so 取得
├── .github/workflows/
│   └── release-libs.yml      # ★新規: クロスプラットフォームビルド
├── tests/
│   └── unit/
│       └── test_libs.awk     # ★新規: libs 統合テスト (skip 機構付)
├── plugins/                  # 既存
├── LICENSE                   # ★新規: MIT
└── docs/superpowers/specs/
    └── 2026-06-06-libs-zig-ext-design.md
```

### 3.1 `.gitignore` 追加

```
libs/*/zig-out/
libs/*/zig-cache/
libs/*/.zig-cache/
```

### 3.2 Makefile 追加ターゲット

```makefile
build-libs:    ## libs/* を全ビルド (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  echo "Building $$d"; \
	  (cd "$$d" && zig build -Doptimize=ReleaseSafe); \
	done

fetch-libs:    ## GitHub Release から precompiled 取得 (Zig 不要)
	./scripts/fetch-libs.sh

test-libs:    ## libs/*/zig build test (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  echo "Testing $$d"; \
	  (cd "$$d" && zig build test); \
	done

libs-clean:    ## libs ビルド成果削除
	@for d in libs/*/; do rm -rf "$$d/zig-out" "$$d/zig-cache" "$$d/.zig-cache"; done

test: test-unit test-e2e test-libs ## 全テスト (libs 含む)

ci: lint test ## lint + 全テスト
```

## 4. libs/binary API 仕様

### 4.1 Zig 側 (gawk extension として export)

`libs/binary/src/root.zig`:

```zig
const std = @import("std");
const ffi = @import("../../_common/gawk_ffi.zig");
const binary = @import("binary.zig");

export const dl_load = ffi.makeDlLoad(.{
    .name = "hawk_binary",
    .api_major = 4,
    .api_minor = 0,
    .functions = &.{
        .{ .name = "hawk_bin_read",   .impl = binImplRead,   .args = 1 },
        .{ .name = "hawk_bin_send",   .impl = binImplSend,   .args = 2 },
        .{ .name = "hawk_bin_length", .impl = binImplLength, .args = 1 },
    },
});

fn binImplRead(args: ffi.Args) ffi.Result {
    const path = args.getString(0);
    const allocator = ffi.gawkAllocator();
    const content = binary.readAll(allocator, path) catch return .{ .string = "" };
    return .{ .string = content };
}

fn binImplSend(args: ffi.Args) ffi.Result {
    const sock_name = args.getString(0);
    const content = args.getString(1);
    binary.sendToSocket(sock_name, content) catch return .{ .int = 0 };
    return .{ .int = 1 };
}

fn binImplLength(args: ffi.Args) ffi.Result {
    const content = args.getString(0);
    return .{ .int = @intCast(content.len) };
}
```

### 4.2 awk 側 API

```awk
hawk_bin_read(path)              # ファイルを binary-safe に読込み、文字列で返す
                                 # (gawk は \0 含む文字列を保持可能)
                                 # 失敗時は空文字列

hawk_bin_send(sock_name, content) # binary content を socket に送信
                                 # 戻り値: 1=成功, 0=失敗

hawk_bin_length(content)         # bytes 数を返す
                                 # awk の length() は文字数で binary 不正確
```

### 4.3 制限事項 (MVP)

- 最大読込サイズ: `HAWK_MAX_BODY_SIZE` (デフォルト 1 MiB) を尊重。超過時は空文字列を返し、stderr に warning
- ファイルが存在しない / 読込権限なし: 空文字列を返し、stderr に warning
- 並行アクセス: なし (MVP single-thread 前提)

## 5. 共通基盤 `libs/_common/`

### 5.1 `gawk_ffi.zig`

各 libs の boilerplate を集約。Zig comptime で type-safe な関数登録を実現する。

**役割:**

- gawk extension API (gawkapi.h) の C ABI を Zig で wrap
- `awk_value_t` (gawk 側の値) ⇄ Zig 型 (`[]const u8`, `i64`, `f64`) の marshalling
- `dl_load` エントリの自動生成 (comptime で関数テーブル展開)
- gawk の `gawk_malloc` を使う allocator (Zig `std.mem.Allocator` 準拠)

**主要 API:**

```zig
pub const Args = struct {
    pub fn getString(self: Args, i: usize) []const u8;
    pub fn getInt(self: Args, i: usize) i64;
    pub fn getDouble(self: Args, i: usize) f64;
};

pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};

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

pub fn makeDlLoad(comptime cfg: DlLoadConfig) ExtensionEntry;
pub fn gawkAllocator() std.mem.Allocator;
```

`makeDlLoad` は comptime で各関数を gawk に register する `dl_load` 関数を生成する。各 libs はこれを `export const dl_load = ...` するだけで gawk extension として認識される。

### 5.2 `build_helper.zig`

各 libs の `build.zig` 共通ヘルパ。

```zig
// libs/binary/build.zig
const std = @import("std");
const helper = @import("../_common/build_helper.zig");

pub fn build(b: *std.Build) void {
    helper.makeExtension(b, .{
        .name = "hawk_binary",
        .source_root = "src/root.zig",
        .test_root   = "tests/binary_test.zig",
    });
}
```

`helper.makeExtension` の内部処理:
- 共有ライブラリ (.so / .dylib) ビルド設定
- `_common/gawk_ffi.zig` を import path に追加
- `zig build test` ターゲット登録 (Zig 単体テスト)
- ReleaseSafe デフォルト (panic 安全 + 最適化)

## 6. Load 機構

### 6.1 `bin/hawk` 追加部分

```sh
# libs glob: libs/<name>/zig-out/lib/libhawk_<name>.{so,dylib} を検出
LIBS_GAWK_ARGS=""
LIBS_VARS=""
case "$(uname -s)" in
  Darwin) SO_EXT=dylib ;;
  *)      SO_EXT=so ;;
esac

for d in libs/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  [ "$name" = "_common" ] && continue
  so="${d}zig-out/lib/libhawk_${name}.${SO_EXT}"
  if [ -f "$so" ]; then
    LIBS_GAWK_ARGS="$LIBS_GAWK_ARGS -l hawk_${name}"
    LIBS_VARS="$LIBS_VARS -v HAWK_LIBS_${name}=1"
    abspath=$(cd "$(dirname "$so")" && pwd)
    AWKLIBPATH="${abspath}:${AWKLIBPATH:-}"
  else
    echo "[WARN] libs/${name} 未ビルド ($so 不在)。機能 fallback 動作" >&2
  fi
done
export AWKLIBPATH

# gawk 起動 (-l で動的 load、-v でフラグ伝達)
exec gawk $LIBS_GAWK_ARGS $LIBS_VARS -f hawk.awk $PLUGIN_FILES -f "$APP"
```

### 6.2 `core/libs.awk` (新規)

```awk
# core/libs.awk -- libs 読込状態の集約とフラグ
#
# bin/hawk が -v HAWK_LIBS_<name>=1 を渡している場合のみ
# LIBS_LOADED["<name>"] = 1 を立てる。core/*.awk はこれをチェックして分岐する。

BEGIN {
  if (HAWK_LIBS_binary)    LIBS_LOADED["binary"]    = 1
  if (HAWK_LIBS_multipart) LIBS_LOADED["multipart"] = 1
  if (HAWK_LIBS_crypto)    LIBS_LOADED["crypto"]    = 1
  if (HAWK_LIBS_gzip)      LIBS_LOADED["gzip"]      = 1
  if (HAWK_LIBS_url)       LIBS_LOADED["url"]       = 1
}
```

### 6.3 `hawk.awk` 修正

```awk
@include "core/util.awk"
@include "core/libs.awk"        # ← 追加 (util の直後、他 core より前)
@include "core/json.awk"
@include "core/tsv.awk"
...
```

### 6.4 起動ログ例

```
$ ./bin/hawk app.awk
[WARN] libs/multipart 未ビルド (libs/multipart/zig-out/lib/libhawk_multipart.so 不在)。機能 fallback 動作
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: binary]
```

(libs 一覧表示は `core/http.awk` の起動ログを拡張して実装)

## 7. core からの呼出パターン

### 7.1 `core/static.awk` の binary 振分

```awk
function static_read(path,    line, out, first) {
  if (LIBS_LOADED["binary"]) {
    return hawk_bin_read(path)              # binary-safe
  }
  if (path ~ /\.(png|jpe?g|gif|webp|ico|woff2?)$/) {
    log_error("static_read: binary file requested but libs/binary not loaded: " path)
  }
  # fallback: text mode (PNG/JPG は壊れるが、現状は warning のみ)
  out = ""
  first = 1
  while ((getline line < path) > 0) {
    out = out (first ? "" : "\n") line
    first = 0
  }
  close(path)
  return out
}

function serve_static(req, res,    safe, full, content, mime, cmd) {
  if (req["method"] != "GET" && req["method"] != "HEAD") return 0
  safe = static_safe_path(req["path"])
  if (safe == "") return 0
  full = "public/" safe

  cmd = "test -f " _shellquote(full) " && test -r " _shellquote(full)
  if (system(cmd) != 0) return 0

  mime = static_mime(full)
  res["status"] = 200
  res["header:content-type"] = mime

  if (LIBS_LOADED["binary"] && _static_is_binary_mime(mime)) {
    # 送信時に hawk_bin_send 経由するため、path を保持
    res["_binary_path"] = full
    res["body"] = ""    # http_send が判定で binary 送信に切替
  } else {
    res["body"] = (req["method"] == "HEAD") ? "" : static_read(full)
  }
  return 1
}

function _static_is_binary_mime(mime) {
  return (index(mime, "image/") == 1)        \
      || (index(mime, "font/") == 1)         \
      || (mime == "application/octet-stream")
}
```

### 7.2 `core/http.awk` の binary 送信分岐

```awk
function http_send(sock, res, req, start_ms,    wire, headers_part, body_part, dur, ts) {
  if (res["sent"]) return

  if (res["_binary_path"] != "" && LIBS_LOADED["binary"]) {
    # binary 送信: ヘッダだけ wire 生成し、body 部は hawk_bin_send で
    res["body"] = ""
    res["header:content-length"] = _binary_file_size(res["_binary_path"])
    wire = response_wire(res)
    # response_wire は body を末尾に付与する仕様 → "\r\n\r\n" までを抽出
    headers_part = substr(wire, 1, index(wire, "\r\n\r\n") + 3)
    printf "%s", headers_part |& sock
    fflush(sock)
    hawk_bin_send(sock, hawk_bin_read(res["_binary_path"]))
  } else {
    wire = response_wire(res)
    printf "%s", wire |& sock
    fflush(sock)
  }
  res["sent"] = 1

  dur = now_ms() - start_ms
  ts  = strftime("%Y-%m-%dT%H:%M:%S%z")
  printf "%s\tINFO\t%s\t%s\t%d\t%d\n", ts, req["method"], req["path"], res["status"], dur
  fflush()
}

function _binary_file_size(path,    cmd, size) {
  cmd = "wc -c < " _shellquote(path)
  cmd | getline size
  close(cmd)
  return size + 0
}
```

## 8. 配布

### 8.1 開発者: ソースビルド

```sh
$ zig version
0.14.0
$ make build-libs
Building libs/binary/
... → libs/binary/zig-out/lib/libhawk_binary.{so,dylib}
```

### 8.2 エンドユーザー: precompiled DL (Zig 不要)

```sh
$ make fetch-libs                 # GitHub Release から取得
$ # or 手動
$ curl -L -o /tmp/hawk-libs.tar.gz \
    https://github.com/<owner>/hawk/releases/download/v0.2.0/hawk-libs-$(uname -s)-$(uname -m).tar.gz
$ tar xzf /tmp/hawk-libs.tar.gz -C .
```

### 8.3 GitHub Actions ビルドマトリックス

`.github/workflows/release-libs.yml`:

```yaml
name: Release libs
on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: macos-latest
            target: aarch64-macos
          - os: macos-13           # x86_64 Mac
            target: x86_64-macos
          - os: ubuntu-latest
            target: x86_64-linux-gnu
          - os: ubuntu-latest-arm
            target: aarch64-linux-gnu
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with: { version: 0.14.0 }
      - name: Build libs
        run: |
          for d in libs/*/; do
            [ "$d" = "libs/_common/" ] && continue
            (cd "$d" && zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe)
          done
      - name: Package
        run: |
          mkdir -p dist
          tar czf dist/hawk-libs-$(uname -s)-$(uname -m).tar.gz libs/*/zig-out/lib/
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/*.tar.gz
```

### 8.4 `scripts/fetch-libs.sh`

```sh
#!/bin/sh
set -e
TAG="${1:-latest}"
OS=$(uname -s)
ARCH=$(uname -m)
URL="https://github.com/<owner>/hawk/releases/download/${TAG}/hawk-libs-${OS}-${ARCH}.tar.gz"
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/libs.tar.gz" "$URL"
tar xzf "$TMP/libs.tar.gz" -C .
rm -rf "$TMP"
echo "fetched libs from $TAG"
```

### 8.5 サポートターゲット (v0.2)

- macOS arm64 (Apple Silicon)
- macOS x86_64 (Intel)
- Linux x86_64 (glibc)
- Linux aarch64 (glibc)

**非対応** (v0.2 では除外):
- Linux musl (Alpine 等) — Zig 自体は対応可、需要があれば v0.3
- Windows — gawk 自体 WSL 推奨、native は対象外

## 9. テスト戦略

### 9.1 3 層テスト構成

```
Zig 単体 (libs/*/tests/)
  ↓ build → libhawk_*.{so,dylib}
awk 統合 (tests/unit/test_libs.awk)
  ↓
E2E (tests/e2e/run.sh 拡張)
```

### 9.2 Zig 単体テスト

`libs/binary/tests/binary_test.zig`:

```zig
const std = @import("std");
const binary = @import("../src/binary.zig");

test "read full binary file" {
    const tmp = "/tmp/hawk_zig_test.bin";
    try std.fs.cwd().writeFile(.{
        .sub_path = tmp,
        .data = "\x00\x01\xff\x7f\x80",
    });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    var allocator = std.testing.allocator;
    const content = try binary.readAll(allocator, tmp);
    defer allocator.free(content);

    try std.testing.expectEqualSlices(u8, "\x00\x01\xff\x7f\x80", content);
}

test "length counts bytes not chars" {
    const s = "\xff\xfe\xfd";
    try std.testing.expectEqual(@as(usize, 3), binary.lengthBytes(s));
}
```

実行: `cd libs/binary && zig build test`、または `make test-libs`

### 9.3 awk 統合テスト

`tests/unit/test_libs.awk`:

```awk
function test_libs_binary_read_text(   tmp, content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  tmp = "/tmp/hawk_libs_text_" PROCINFO["pid"]
  system("printf 'hello' > " tmp)
  content = hawk_bin_read(tmp)
  assert_eq(content, "hello", "libs/binary: text read")
  system("rm -f " tmp)
}

function test_libs_binary_read_bytes(   tmp, content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  tmp = "/tmp/hawk_libs_bin_" PROCINFO["pid"]
  system("printf '\\xff\\xfe\\xfd' > " tmp)
  content = hawk_bin_read(tmp)
  assert_eq(hawk_bin_length(content), 3, "libs/binary: byte length")
  system("rm -f " tmp)
}
```

`tests/unit/run.awk` 拡張:

```awk
END {
  printf "%d passed, %d failed, %d skipped\n", \
    TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED
  exit (TESTS_FAILED > 0)
}
```

### 9.4 E2E binary 配信テスト

`tests/e2e/run.sh` に追加:

```sh
# PNG / ICO 配信の binary 完全性
md5_tool() {
  if command -v md5sum >/dev/null; then md5sum "$@" | awk '{print $1}';
  elif command -v md5 >/dev/null;    then md5 -q "$@";
  else echo ""; fi
}

ORIG_MD5=$(md5_tool public/favicon.ico)
SERVED_MD5=$(curl -s http://127.0.0.1:$PORT/favicon.ico | md5_tool /dev/stdin)

if [ -z "$ORIG_MD5" ]; then
  echo "SKIP: md5 tool not found"
elif [ "$ORIG_MD5" = "$SERVED_MD5" ]; then
  PASS=$((PASS + 1))
else
  # libs/binary 未ビルド時は壊れた md5 が返るため、その場合は skip 扱い
  if [ -f libs/binary/zig-out/lib/libhawk_binary.so ] || \
     [ -f libs/binary/zig-out/lib/libhawk_binary.dylib ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: binary integrity (orig=$ORIG_MD5 served=$SERVED_MD5)" >&2
  else
    echo "SKIP: libs/binary not built (binary integrity check requires it)"
  fi
fi
```

## 10. エラーハンドリング

### 10.1 起動時

- libs/<name>/zig-out/lib/libhawk_<name>.{so,dylib} 不在 → stderr に warning、起動継続、機能 fallback
- ファイル存在するが gawk が load 失敗 (ABI 不一致 等) → gawk 自身が exit 1。bin/hawk supervisor が再起動を 1 秒間隔で試みるが、再度失敗 → ループ。**運用上は手動介入が必要** (warning 文言に「`make libs-clean && make build-libs` でリビルドを推奨」と明記)

### 10.2 実行時

- `hawk_bin_read(path)`: ファイル不在 / 権限なし / サイズ超過 → 空文字列を返し、stderr に warning
- `hawk_bin_send(sock, content)`: socket 切断 → 0 を返す
- `hawk_bin_length(s)`: 常に成功、空文字列は 0

### 10.3 graceful degrade

各 core/*.awk は `LIBS_LOADED["<name>"]` を確認し、未ロード時は pure awk fallback で動作する。MVP 段階の fallback 一覧:

- binary 未ロード: PNG/JPG 等の binary 配信は壊れた状態で送信される (md5 一致しない)。warning ログのみ出力
- multipart 未ロード (v0.3 以降): `multipart/form-data` リクエストは `req["body"]` に生 body を保持するのみ。`req["form:*"]` は空
- crypto 未ロード (v0.3 以降): `sha256()` 等の関数は呼出時に「libs/crypto not loaded」エラー。plugin 側で `LIBS_LOADED["crypto"]` を事前確認

## 11. セキュリティ

### 11.1 memory safety

- Zig は default safety check 有効 (ReleaseSafe で本番ビルド)
- null deref / out-of-bounds は panic で停止 → gawk プロセス死 → bin/hawk supervisor が再起動
- libs 側のクラッシュが core/awk 側に伝播しない

### 11.2 allocator

- gawk が提供する `gawk_malloc` / `gawk_realloc` / `gawk_free` を経由
- `libs/_common/gawk_ffi.zig` の `gawkAllocator()` が `std.mem.Allocator` 準拠の wrapper を提供
- Zig std lib コードがそのまま使える

### 11.3 path traversal

- libs/binary は何もしない (input validation は呼出元 core/static.awk の `static_safe_path` で行う)
- libs 単体テストでも traversal 検証はしない (責務外)

### 11.4 bounded read

- `hawk_bin_read(path)` は `HAWK_MAX_BODY_SIZE` を尊重する
- 伝達経路: gawk が `ENVIRON["HAWK_MAX_BODY_SIZE"]` を持っているため、libs 側からは `std.process.getEnvVarOwned(allocator, "HAWK_MAX_BODY_SIZE")` で参照可能 (Zig std lib)
- 超過時は空文字列 + warning

### 11.5 拡張機能 ABI

- gawk 5.0+ extension API (API_MAJOR=4) に固定
- 4.x は後方互換、5.x で再ビルド必要時は warning 表示

## 12. ライセンス

### 12.1 採用ライセンス

**プロジェクト全体 MIT License**。各 Zig ソースに SPDX ヘッダ:

```zig
// SPDX-License-Identifier: MIT
```

リポジトリルートに `LICENSE` ファイル (MIT 標準テキスト) を配置する。

### 12.2 依存ライセンス

- **gawk**: GPLv3+ (依存先のみ、本プロジェクトには伝播させない)
- **Zig std lib**: MIT (互換)

### 12.3 GPL 縛りの可能性に関する見解

gawk extension が `.so` として dynamic link されることが GPL の "derivative work" に該当するかは、米国判例で結論が出ていない。FSF は dynamic link も GPL 縛りと主張するが、強制力はない。実際、多くの gawk extension が独立ライセンス (MIT / BSD 等) で配布される実例がある。

本プロジェクトは個人開発レベルの規模であり、法的リスクは実質ゼロと判断し MIT を採用する。

**ライセンス再検討タイミング**: 将来 v1.0 で商業利用 / 公的配布する際、上記論点に変化があれば LGPL or GPLv3 への移行を検討する。それまで MIT で進行する。

## 13. MVP スコープ (libs spec v0.1)

### 13.1 含むもの

- `libs/_common/gawk_ffi.zig` (gawk extension API ラッパ)
- `libs/_common/build_helper.zig` (build.zig 共通ヘルパ)
- `libs/binary/` 完成 (`hawk_bin_read` / `hawk_bin_send` / `hawk_bin_length`)
- Zig 単体テスト
- awk 統合テスト (`tests/unit/test_libs.awk` + skip 機構)
- E2E binary 整合テスト (md5 一致)
- `Makefile`: `build-libs` / `fetch-libs` / `libs-clean` / `test-libs` ターゲット
- `bin/hawk` glob + AWKLIBPATH + `-l` フラグ生成
- `core/libs.awk` (LIBS_LOADED 集約)
- `core/static.awk` の binary 振分
- `core/http.awk` の `res["_binary_path"]` 経由 binary 送信
- GitHub Actions `release-libs.yml` (4 ターゲット precompiled .so 配布)
- `scripts/fetch-libs.sh`
- README に libs セクション追加 (ユーザー視点では「自動でバイナリ対応」と説明)
- `LICENSE` ファイル (MIT)
- 各 Zig / awk ファイルに SPDX ヘッダ

### 13.2 含まないもの (v0.3 以降)

- `libs/multipart/`
- `libs/crypto/`
- `libs/gzip/`
- `libs/url/`
- Windows native サポート
- Linux musl サポート
- hot-reload (libs 再 build 後の自動再起動)
- HEAD リクエスト時の Content-Length 整合 (binary 送信パスは現状 GET のみ)

## 14. ロードマップ

| バージョン | 追加内容 |
|------------|----------|
| **H-awk v0.2** (本 spec) | libs/_common + libs/binary + 配布インフラ |
| **H-awk v0.3** | libs/multipart + libs/crypto + CSRF plugin の本格化 + 並行性 |
| **H-awk v0.4** | libs/gzip + libs/url + cookie ヘルパ + multipart + keep-alive |
| **H-awk v0.5** | musl 対応 / cross-compile マトリックス整備 |
| **H-awk v1.0** | 5 libs 公式提供確定、precompiled 配布安定、API freeze |

## 15. 受入基準 (libs spec v0.1 完了条件)

- `make build-libs` で libs/binary がビルドできる (Zig 0.14+)
- `make fetch-libs v0.2.0` で precompiled .so が `libs/binary/zig-out/lib/` に配置される (GitHub Release 公開後)
- `make test-libs` が pass する (Zig 単体テスト)
- `make test` が pass する (unit + e2e + libs。skip 件数は libs 有無で変動)
- libs/binary 未ビルドで `make ci` を走らせると warning が出るが、test は全 pass (該当 check は skip)
- libs/binary ビルド後 `make ci` で favicon.ico の md5 一致 check が pass する
- README にユーザー視点での説明が追加されている (Zig 不要パス + Zig ありパス両方)
- `LICENSE` が MIT で配置されている
- GitHub Actions の release-libs.yml が CI を通過する (タグ push 時のみ実行)

## 16. 用語集

- **gawk extension** … gawk 5.0+ で利用可能な動的読込ライブラリ機構。`@load "name"` または `gawk -l name` で `.so` / `.dylib` を読込み、その中で定義された関数を awk から呼出可能にする
- **gawkapi.h** … gawk extension API の C ヘッダ。awk 値型 (`awk_value_t`)、関数登録 (`add_ext_func`)、配列操作などを提供
- **dl_load** … gawk extension の必須エントリ関数。gawk が `.so` を dlopen した直後に呼ばれ、関数登録などの初期化を行う
- **Zig comptime** … Zig のコンパイル時実行機構。本 spec の `makeDlLoad` は comptime で関数テーブルから dl_load を自動生成する
- **ReleaseSafe** … Zig の最適化モードの 1 つ。Debug よりも高速、ReleaseFast よりも安全 (panic / bounds-check 残る)
- **graceful degrade** … 依存先 (libs) が不在でも、機能の一部を諦めることで全体動作を継続させる設計方針
- **AWKLIBPATH** … gawk が `@load` / `-l` で dlopen するときに走査するディレクトリパス (環境変数)
