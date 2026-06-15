function handler(    _ds_tc_1, raw, _ds_p_1, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  safe = _ds_p_1
  return ctx::dispatch("res.html", safe)
}
