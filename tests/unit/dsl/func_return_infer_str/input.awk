function greet() {
  return "hello"
}

function handler() -> Response {
  let msg: Str = greet()
  return ctx.res.text(msg)
}
