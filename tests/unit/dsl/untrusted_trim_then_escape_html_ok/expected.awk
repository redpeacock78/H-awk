function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function handler(    raw, _ds_tc_1, _ds_err_type__ds_tc_1, trimmed, _ds_p_1, safe, _ds_p_2) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
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
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  trimmed = _ds_p_1
  _ds_p_2 = safe::dispatch("html.escape", trimmed)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
