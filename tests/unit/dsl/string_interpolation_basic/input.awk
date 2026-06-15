function handler() -> Response {
  let name: Str = "hawk"
  let msg = "hello #{name}!"
  return ctx.res.text(msg)
}
