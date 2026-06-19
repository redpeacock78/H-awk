function escape_html(s) {
  return s
}

function non_empty(s) {
  return s
}

function handler(    _ds_tc_1, raw, _ds_err_type__ds_tc_1, _ds_p_1, valid, _ds_p_2, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = non_empty(raw)
  valid = _ds_p_1
  _ds_p_2 = escape_html(valid)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
