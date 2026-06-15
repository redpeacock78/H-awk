function handler(    out, _ds_p_1, frag) {
  out = "<p>Hello</p>"
  _ds_p_1 = safe::dispatch("html.raw", out)
  frag = _ds_p_1
  return ctx::dispatch("res.html", frag)
}
