# SPDX-License-Identifier: MIT
function test_util_url_decode() {
  assert_eq(url_decode("hello%20world"), "hello world", "util: url_decode space")
  assert_eq(url_decode("a+b"),            "a b",         "util: url_decode plus")
  assert_eq(url_decode("100%25"),         "100%",        "util: url_decode percent")
  assert_eq(url_decode("plain"),          "plain",       "util: url_decode no-op")
  assert_eq(url_decode(""),               "",            "util: url_decode empty")
}

function test_util_escape_html() {
  assert_eq(escape_html("<b>&\"'"),  "&lt;b&gt;&amp;&quot;&#39;", "util: escape all")
  assert_eq(escape_html("plain"),    "plain",                      "util: escape no-op")
}

function test_util_to_lower() {
  assert_eq(to_lower("Content-Type"), "content-type", "util: to_lower header")
  assert_eq(to_lower("ABC123"),       "abc123",       "util: to_lower mixed")
}

function test_util_log_warn() {
  # log_warn must exist and not crash — output goes to stderr, not testable here
  log_warn("test warn message")
  TESTS_SKIPPED++
}
