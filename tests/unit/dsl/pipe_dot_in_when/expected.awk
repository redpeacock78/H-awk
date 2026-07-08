function h(    _ds_mc_1, raw, escaped, _ds_p_1) {
  _ds_mc_1 = ctx::dispatch("req.form", "title")
  if (result_ok(_ds_mc_1)) {
    raw = result_val(_ds_mc_1)
    _ds_p_1 = safe::dispatch("html.escape", raw)
    escaped = _ds_p_1
    return ctx::dispatch("res.html", escaped)
  } else {
    return ctx::dispatch("res.status", 400)
  }
}
