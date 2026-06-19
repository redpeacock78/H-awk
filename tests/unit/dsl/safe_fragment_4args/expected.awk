function handler(    a, b, c, d) {
  a = safe::dispatch("html.escape", "<b>")
  b = safe::dispatch("html.escape", "&")
  c = safe::dispatch("html.escape", "<i>")
  d = safe::dispatch("html.escape", "ok")
  delete _ds_frag_args_1
  _ds_frag_args_1[1] = a
  _ds_frag_args_1[2] = b
  _ds_frag_args_1[3] = c
  _ds_frag_args_1[4] = d
  return ctx::dispatch("res.html", safe::fragment_v(_ds_frag_args_1, 4))
}
