function f(s: Str) -> Str {
  return s
}
function handler() -> Response {
  let s = "#{ f("}") }"
  return ctx.res.text(s)
}
