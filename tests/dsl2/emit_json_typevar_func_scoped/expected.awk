function a(s,    items, _ds_tc_1, _ds_err_type__ds_tc_1, _ds_letq_ty__ds_tc_1) {
  _ds_tc_1 = json::dispatch("decode_t", "List<Int>", s)
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
  result_val_into_map(_ds_tc_1, items, _ds_letq_ty__ds_tc_1)
  items["__json_type"] = "array"
  return json(res, items, _ds_letq_ty__ds_tc_1)
}
function b(s,    items, _ds_tc_2, _ds_err_type__ds_tc_2, _ds_letq_ty__ds_tc_2) {
  _ds_tc_2 = json::dispatch("decode_t", "List<Int>", s)
  if (!result_ok(_ds_tc_2)) {
    _ds_err_type__ds_tc_2 = awk::result_err_type(_ds_tc_2)
    if (_ds_err_type__ds_tc_2 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_2 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_2 == "NotFoundError") return ctx::dispatch("res.status", 404)
    if (_ds_err_type__ds_tc_2 == "JsonParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_2 == "JsonTypeError") return ctx::dispatch("res.status", 422)
    if (_ds_err_type__ds_tc_2 == "JsonTooDeepError") return ctx::dispatch("res.status", 400)
    return ctx::dispatch("res.status", 500)
  }
  result_val_into_map(_ds_tc_2, items, _ds_letq_ty__ds_tc_2)
  items["__json_type"] = "array"
  return json(res, items, _ds_letq_ty__ds_tc_2)
}
