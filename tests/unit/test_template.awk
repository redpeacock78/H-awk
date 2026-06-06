# SPDX-License-Identifier: MIT
# tests/unit/test_template.awk -- template.awk ユニットテスト

function test_template_read(   tmpfile, content) {
  tmpfile = "/tmp/hawk_tpl_" PROCINFO["pid"] ".html"
  system("printf '<h1>hi</h1>\\nbody' > " tmpfile)

  content = template_read(tmpfile)
  assert_eq(content, "<h1>hi</h1>\nbody", "template: full content")

  system("rm -f " tmpfile)
}

function test_template_read_missing() {
  assert_eq(template_read("/tmp/does_not_exist_" PROCINFO["pid"]), "", "template: missing file → empty string")
}
