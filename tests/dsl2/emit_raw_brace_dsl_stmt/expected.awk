function todo_add(    raw_title, _ds_mc_1, raw, raw_q, _ds_tc_1, _ds_err_type__ds_tc_1, _) {
  raw_title = ctx::dispatch("req.form", "title")
  _ds_mc_1 = raw_title
  if (result_ok(_ds_mc_1)) {
    raw = result_val(_ds_mc_1)
      if (raw == "") {
    _ds_tc_1 = ctx::dispatch("req.query", "title")
    if (!result_ok(_ds_tc_1)) {
      _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
      if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
      if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
      if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
      if (_ds_err_type__ds_tc_1 == "JsonParseError") return ctx::dispatch("res.status", 400)
      if (_ds_err_type__ds_tc_1 == "JsonTypeError") return ctx::dispatch("res.status", 422)
      if (_ds_err_type__ds_tc_1 == "JsonTooDeepError") return ctx::dispatch("res.status", 400)
      return ctx::dispatch("res.status", 500)
    }
    raw_q = result_val(_ds_tc_1)
    raw = raw_q
      }
    return ctx::dispatch("res.text", raw)
  } else {
    _ = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
