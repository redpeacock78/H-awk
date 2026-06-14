function trim(s) {
  return s
}

function non_empty(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, t, _ds_p_2, _ds_tc_2, v) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  t = _ds_p_1
  _ds_p_2 = non_empty(t)
  _ds_tc_2 = _ds_p_2
  if (!result_ok(_ds_tc_2)) {
    return ctx::dispatch("res.status", 500)
  }
  v = result_val(_ds_tc_2)
}
