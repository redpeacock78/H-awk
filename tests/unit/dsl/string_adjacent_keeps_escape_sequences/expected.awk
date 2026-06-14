function handler(    s) {
  s = "line1\nline2\tline3"
  return ctx::dispatch("res.text", s)
}
