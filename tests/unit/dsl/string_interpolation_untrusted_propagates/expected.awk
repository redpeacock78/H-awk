function handler(    _ds_tc_1, raw, msg) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  msg = sprintf("title: %s", raw)
  return ctx::dispatch("res.text", msg)
}
