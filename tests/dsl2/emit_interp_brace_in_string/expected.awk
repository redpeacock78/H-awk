function f(s) {
  return s
}
function handler(    s) {
  s = sprintf("%s", f("}"))
  return ctx::dispatch("res.text", s)
}
