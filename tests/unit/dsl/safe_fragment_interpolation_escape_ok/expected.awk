function handler(    _ds_tc_1, raw, _ds_err_type__ds_tc_1, _ds_p_1, frag) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  frag = safe::dispatch("html.fragment", "<p>", _ds_p_1, "</p>")
  return ctx::dispatch("res.html", frag)
}
