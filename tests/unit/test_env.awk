# SPDX-License-Identifier: MIT

function test_env_get_existing() {
  ENVIRON["__TEST_ENV_KEY"] = "hello"
  assert_eq(env::get("__TEST_ENV_KEY"), "hello", "env::get existing")
  delete ENVIRON["__TEST_ENV_KEY"]
}

function test_env_get_missing() {
  delete ENVIRON["__TEST_ENV_MISSING"]
  assert_eq(env::get("__TEST_ENV_MISSING"), "", "env::get missing")
}

function test_env_set() {
  env::set("__TEST_ENV_SET", "world")
  assert_eq(env::get("__TEST_ENV_SET"), "world", "env::set then get")
  delete ENVIRON["__TEST_ENV_SET"]
}

function test_env_del() {
  ENVIRON["__TEST_ENV_DEL"] = "temp"
  env::del("__TEST_ENV_DEL")
  assert_eq(env::has("__TEST_ENV_DEL"), 0, "env::del then has")
}

function test_env_has_existing() {
  ENVIRON["__TEST_ENV_HAS"] = "1"
  assert_eq(env::has("__TEST_ENV_HAS"), 1, "env::has existing")
  delete ENVIRON["__TEST_ENV_HAS"]
}

function test_env_has_missing() {
  delete ENVIRON["__TEST_ENV_HAS_MISSING"]
  assert_eq(env::has("__TEST_ENV_HAS_MISSING"), 0, "env::has missing")
}

function test_env_set_overwrite() {
  env::set("__TEST_ENV_OW", "first")
  env::set("__TEST_ENV_OW", "second")
  assert_eq(env::get("__TEST_ENV_OW"), "second", "env::set overwrite")
  delete ENVIRON["__TEST_ENV_OW"]
}
