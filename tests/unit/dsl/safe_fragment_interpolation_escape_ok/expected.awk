function handler(    _ds_tc_1, raw, _ds_p_1, frag) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = safe::dispatch("html.escape", raw)
  frag = safe::dispatch("html.fragment", "<p>", _ds_p_1, "</p>")
  return ctx::dispatch("res.html", frag)
}
