function handler() -> Response {
  if (env.get("X") ?? 1) {
    return ctx.res.text("y")
  }
  return ctx.res.text("n")
}
