function handler(    a, b, c, d) {
  a = safe::dispatch("html.escape", "<b>")
  b = safe::dispatch("html.escape", "&")
  c = safe::dispatch("html.escape", "<i>")
  d = safe::dispatch("html.escape", "ok")
  return ctx::dispatch("res.html", safe::dispatch("html.fragment", a, b, c, d))
}
