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

function test_static_serve_shell_metachars(   pubdir, fname, fpath, marker, req, res, ok) {
  pubdir = "public"
  system("mkdir -p " pubdir)

  # 副作用検出用マーカー。事前に消しておく。
  ENVIRON["TMPDIR"] = "/tmp/"
  marker = ENVIRON["TMPDIR"] "hawk_pwn_marker_" PROCINFO["pid"]
  system("rm -f " marker)

  # スペース、シングルクォート、$、バッククォート、波括弧、glob 文字に加え、
  # 実行されれば marker を作るコマンド置換を埋め込む。
  fname = "sq test '$(touch ${TMPDIR}hawk_pwn_marker_" PROCINFO["pid"] ")`x`{a,b}*_" PROCINFO["pid"] ".txt"
  fpath = pubdir "/" fname

  # fixture 生成はシェルを介さず AWK のリダイレクトで行う。
  print "ok" > fpath
  close(fpath)

  delete req; delete res
  req["method"] = "GET"
  req["path"]   = "/" fname

  ok = serve_static(req, res)
  assert_eq(ok, 1,                              "static: serve_static returns 1 for meta path")
  assert_eq(res["status"], 200,                 "static: serve_static status 200 for meta path")
  sub(/\n$/, "", res["body"]); assert_eq(res["body"], "ok", "static: serve_static body for meta path")

  # 副作用検出: コマンド置換が実行されると marker が残る。
  assert_true((system("test ! -e " marker) == 0), \
              "static: no command substitution side effect")

  # 後始末（assertion で早期 fatal しても marker 消去は次回実行で救う）。
  system("rm -f " marker)
  # ファイル削除もシェルを介さない安全な経路を通す（本体 _shellquote 経由）。
  system("rm -f -- " _shellquote(fpath))
}
