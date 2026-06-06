# SPDX-License-Identifier: MIT
# 仮プラグイン (テスト中のみ)
function plugin_demo_manifest(meta) {
  meta["name"]        = "demo"
  meta["version"]     = "0.0.1"
  meta["description"] = "demo plugin for tests"
  meta["hooks"]       = "pre_request,post_request"
  meta["api"]         = "demo_marker"
  meta["config_keys"] = ""
}

function plugin_demo_pre_request(req, res) {
  PLUGIN_TRACE[++PLUGIN_TRACE_COUNT] = "pre"
  if (req["path"] == "/abort") {
    status(res, 401)
    text(res, "blocked")
    return 1
  }
  return 0
}

function plugin_demo_post_request(req, res) {
  PLUGIN_TRACE[++PLUGIN_TRACE_COUNT] = "post"
  header(res, "X-Demo", "1")
  return 0
}

function _plugin_reset() {
  delete PLUGINS
  delete HOOKS
  delete HOOKS_COUNT
  delete PLUGIN_TRACE
  PLUGIN_TRACE_COUNT = 0
  PLUGIN_REGISTER_ERROR = 0
}

function test_plugin_register_one(   meta) {
  _plugin_reset()
  delete meta
  plugin_demo_manifest(meta)
  plugin_register("demo", meta)

  assert_eq(PLUGINS["demo", "version"], "0.0.1", "plugin: registered version")
  assert_eq(HOOKS_COUNT["pre_request"],  1,      "plugin: pre_request hook count")
  assert_eq(HOOKS_COUNT["post_request"], 1,      "plugin: post_request hook count")
  assert_eq(HOOKS["pre_request",  1], "plugin_demo_pre_request",  "plugin: hook name pre")
  assert_eq(HOOKS["post_request", 1], "plugin_demo_post_request", "plugin: hook name post")
}

function test_plugin_call_hooks_normal(   req, res, abort, meta) {
  _plugin_reset()
  delete meta
  plugin_demo_manifest(meta)
  plugin_register("demo", meta)

  delete req; req["method"] = "GET"; req["path"] = "/x"
  delete res
  abort = call_hooks("pre_request", req, res)
  assert_eq(abort, 0,                 "plugin: pre normal not abort")
  assert_eq(PLUGIN_TRACE[1], "pre",   "plugin: pre called")
}

function test_plugin_call_hooks_abort(   req, res, abort, meta) {
  _plugin_reset()
  delete meta
  plugin_demo_manifest(meta)
  plugin_register("demo", meta)

  delete req; req["method"] = "GET"; req["path"] = "/abort"
  delete res
  abort = call_hooks("pre_request", req, res)
  assert_eq(abort, 1,            "plugin: abort returns 1")
  assert_eq(res["status"], 401,  "plugin: abort status set")
}

function test_plugin_missing_config(   meta) {
  _plugin_reset()
  delete meta
  meta["name"] = "needs_env"
  meta["hooks"] = ""
  meta["config_keys"] = "__HAWK_TEST_ENV_THAT_NEVER_EXISTS__"

  PLUGIN_REGISTER_ERROR = 0
  PLUGIN_QUIET = 1
  plugin_register("needs_env", meta)
  PLUGIN_QUIET = 0
  assert_eq(PLUGIN_REGISTER_ERROR, 1, "plugin: config missing flagged")
}
