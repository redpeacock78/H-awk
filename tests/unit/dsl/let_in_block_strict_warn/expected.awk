function handler(    x) {
  if (1) {
  x = "hello"
  }
  return ctx::dispatch("res.text", x)
}
