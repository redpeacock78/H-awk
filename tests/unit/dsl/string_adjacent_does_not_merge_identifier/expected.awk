function handler(    x, s) {
  x = "foo"
  s = x
  return ctx::dispatch("res.text", s)
}
