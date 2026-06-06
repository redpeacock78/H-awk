# SPDX-License-Identifier: MIT
function test_static_mime() {
  assert_eq(static_mime("a.html"), "text/html; charset=utf-8",       "mime: html")
  assert_eq(static_mime("b.css"),  "text/css; charset=utf-8",        "mime: css")
  assert_eq(static_mime("c.js"),   "application/javascript; charset=utf-8", "mime: js")
  assert_eq(static_mime("d.png"),  "image/png",                       "mime: png")
  assert_eq(static_mime("e.svg"),  "image/svg+xml; charset=utf-8",    "mime: svg")
  assert_eq(static_mime("f.bin"),  "application/octet-stream",        "mime: default")
}

function test_static_safe_path() {
  assert_eq(static_safe_path("/foo/bar"),       "foo/bar",   "static: leading slash strip")
  assert_eq(static_safe_path("foo/bar"),        "foo/bar",   "static: passthrough")
  assert_eq(static_safe_path("../etc/passwd"),  "",          "static: parent traversal rejected")
  assert_eq(static_safe_path("a/../b"),         "",          "static: embedded traversal rejected")
  assert_eq(static_safe_path("a/./b"),          "",          "static: dot segment rejected")
}

function test_static_read(   tmpdir, content) {
  tmpdir = "/tmp/hawk_static_" PROCINFO["pid"]
  system("rm -rf " tmpdir " && mkdir -p " tmpdir " && printf 'body { color: red; }' > " tmpdir "/x.css")

  content = static_read(tmpdir "/x.css")
  assert_eq(content, "body { color: red; }", "static: read full")

  system("rm -rf " tmpdir)
}
