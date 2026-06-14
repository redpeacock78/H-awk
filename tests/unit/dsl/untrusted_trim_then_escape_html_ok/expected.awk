function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function handler(    _ds_tc_1, raw, _ds_p_1, trimmed, _ds_p_2, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = trim(raw)
  trimmed = _ds_p_1
  _ds_p_2 = escape_html(trimmed)
  safe = _ds_p_2
  return ctx::dispatch("res.html", safe)
}
