function handler(    s) {
  s = "line1\n" "line2\t" "line3"
  return ctx::dispatch("res.text", s)
}
