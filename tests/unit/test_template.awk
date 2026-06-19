# SPDX-License-Identifier: MIT
# tests/unit/test_template.awk -- template.awk ユニットテスト

function test_template_read(   root, content) {
  root = "/tmp/hawk_tpl_" PROCINFO["pid"]
  ENVIRON["HAWK_TEMPLATE_ROOT"] = root
  system("mkdir -p " root)
  system("printf '<h1>hi</h1>\\nbody' > " root "/index.html")

  content = template_read("index.html")
  assert_eq(content, "<h1>hi</h1>\nbody", "template: full content")

  system("rm -rf " root)
}

function test_template_read_missing() {
  ENVIRON["HAWK_TEMPLATE_ROOT"] = "/tmp"

  assert_eq(template_read("does_not_exist_" PROCINFO["pid"]), "", "template: missing file → empty string")

  if (template_read("/etc/passwd") != "") {
    print "FAIL: absolute path should be blocked" > "/dev/stderr"
    exit 1
  }
  print "PASS: absolute path blocked"

  if (template_read("../secret") != "") {
    print "FAIL: path traversal should be blocked" > "/dev/stderr"
    exit 1
  }
  print "PASS: path traversal blocked"

  if (template_read("") != "") {
    print "FAIL: empty path should be blocked" > "/dev/stderr"
    exit 1
  }
  print "PASS: empty path blocked"
}
