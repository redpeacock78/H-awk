# SPDX-License-Identifier: MIT
function test_safe_fragment_v_empty(    parts) {
  delete parts
  assert_eq(safe::fragment_v(parts, 0), "", "safe: fragment_v empty")
}

function test_safe_fragment_v_concatenates(    parts) {
  delete parts
  parts[1] = "<p>"
  parts[2] = "hello"
  parts[3] = "</p>"
  assert_eq(safe::fragment_v(parts, 3), "<p>hello</p>", "safe: fragment_v concatenates")
}
