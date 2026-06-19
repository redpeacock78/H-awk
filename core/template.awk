# SPDX-License-Identifier: MIT
# core/template.awk -- MVP テンプレート (生 HTML 読込のみ)
#
# 変数置換・ループ・分岐は v0.2 以降。MVP はファイル全文を返す薄いラッパー。
# 動的部分はユーザーが awk 文字列連結で組み立て、res["body"] に直接書き込む。

function _template_safe_path(p) {
  return p !~ /[^A-Za-z0-9_.\/-]/
}

function template_read(path,    root, abs_path, real_root, real_path, cmd, line, out, first, content) {
  root = ENVIRON["HAWK_TEMPLATE_ROOT"]
  if (root == "") {
    content = ""
    while ((getline line < path) > 0) content = content line "\n"
    close(path)
    return content
  }

  if (path == "") {
    print "template: empty path not allowed" > "/dev/stderr"
    return ""
  }
  if (substr(path, 1, 1) == "/") {
    print "template: absolute path not allowed: " path > "/dev/stderr"
    return ""
  }
  if (path ~ /(^|\/)\.\.(\/|$)/) {
    print "template: path traversal not allowed: " path > "/dev/stderr"
    return ""
  }
  if (!_template_safe_path(root) || !_template_safe_path(path)) {
    print "template: unsafe characters in path" > "/dev/stderr"
    return ""
  }

  abs_path = root "/" path

  cmd = "realpath -- " root " 2>/dev/null"
  if ((cmd | getline real_root) <= 0) {
    close(cmd)
    print "template: cannot resolve template root" > "/dev/stderr"
    return ""
  }
  close(cmd)

  cmd = "realpath -- " abs_path " 2>/dev/null"
  if ((cmd | getline real_path) <= 0) {
    close(cmd)
    print "template: cannot resolve path: " path > "/dev/stderr"
    return ""
  }
  close(cmd)

  if (index(real_path, real_root "/") != 1) {
    print "template: path outside root: " path > "/dev/stderr"
    return ""
  }

  out = ""
  first = 1
  while ((getline line < abs_path) > 0) {
    out = out (first ? "" : "\n") line
    first = 0
  }
  close(abs_path)
  return out
}
