# SPDX-License-Identifier: MIT
# tests/unit/test_libs.awk

function test_libs_binary_length(   ) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  assert_eq(hawk_bin_length("hello"), 5, "libs/binary: length ascii")
  assert_eq(hawk_bin_length(""),      0, "libs/binary: length empty")
}

function test_libs_binary_read_text(   tmp, content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  tmp = "/tmp/hawk_libs_text_" PROCINFO["pid"]
  system("printf 'hello' > " tmp)
  content = hawk_bin_read(tmp)
  assert_eq(content, "hello", "libs/binary: read text")
  system("rm -f " tmp)
}

function test_libs_binary_read_missing(   content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  content = hawk_bin_read("/tmp/this_does_not_exist_hawk_libs")
  assert_eq(content, "", "libs/binary: read missing -> empty")
}
