function handler() -> Response {
  if (1) {
    let x: Str = "hello"
  }
  return ctx.res.text(x)
}
