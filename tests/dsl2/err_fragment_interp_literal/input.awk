function handler() -> Response {
  return ctx.res.html(safe.html.fragment("#{123}"))
}
