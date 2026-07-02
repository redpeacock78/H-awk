function handler(    _ds_tc_1, xs, _ds_tct_1, _ds_err_type__ds_tc_1) {
  _ds_tc_1 = ctx::dispatch("req.json_t", "List<Int>")
  if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
    return ctx::dispatch("res.status", 500)
  }
  result_val_into_map(_ds_tc_1, xs, _ds_tct_1)
  xs["__json_type"] = "array"
  return json(res, xs, _ds_tct_1)
}
