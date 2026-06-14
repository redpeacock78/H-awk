function handler(    s) {
  s = "foobar"
  return ctx::dispatch("res.text", s)
}
