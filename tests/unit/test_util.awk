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
  log_warn("test warn message")
  assert_true(1, "log_warn: smoke test (output on stderr above)")
}

function test_util_shellquote_plain() {
  assert_eq(_shellquote("hello"),      "'hello'",      "util: shellquote plain")
  assert_eq(_shellquote(""),           "''",           "util: shellquote empty")
  assert_eq(_shellquote("with space"), "'with space'", "util: shellquote space")
}

function test_util_shellquote_single_quote() {
  assert_eq(_shellquote("a'b"),   "'a'\\''b'",   "util: shellquote single quote")
  assert_eq(_shellquote("'"),     "''\\'''",     "util: shellquote only quote")
  assert_eq(_shellquote("a''b"),  "'a'\\'''\\''b'", "util: shellquote consecutive quotes")
}

function test_util_shellquote_shell_meta() {
  assert_eq(_shellquote("$(rm -rf /)"), "'$(rm -rf /)'", "util: shellquote command substitution")
  assert_eq(_shellquote("a;b|c&d"),     "'a;b|c&d'",     "util: shellquote metachars")
  assert_eq(_shellquote("a`b`c"),       "'a`b`c'",       "util: shellquote backtick")
  assert_eq(_shellquote("$HOME"),       "'$HOME'",       "util: shellquote variable")
}

function test_util_shellquote_whitespace_and_backslash() {
  assert_eq(_shellquote("a\nb"), "'a\nb'", "util: shellquote newline")
  assert_eq(_shellquote("a\tb"), "'a\tb'", "util: shellquote tab")
  assert_eq(_shellquote("a\\b"), "'a\\b'", "util: shellquote backslash")
}

function test_util_shellquote_glob_and_expansion() {
  assert_eq(_shellquote("*.txt"),   "'*.txt'",   "util: shellquote glob star")
  assert_eq(_shellquote("a?b"),     "'a?b'",     "util: shellquote glob question")
  assert_eq(_shellquote("[abc]"),   "'[abc]'",   "util: shellquote glob bracket")
  assert_eq(_shellquote("~/x"),     "'~/x'",     "util: shellquote tilde")
  assert_eq(_shellquote("{a,b}"),   "'{a,b}'",   "util: shellquote brace")
}
