function handler(    out) {
  out = "<p>Hello</p>"
  return ctx::dispatch("res.html", html_raw(out))
}
