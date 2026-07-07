function handler(x,    m) {
  m = sprintf("%s", x~/safe.html.raw()/)
  return ctx::dispatch("res.text", m)
}
