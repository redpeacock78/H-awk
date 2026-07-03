function handler() -> Response {
  return ctx.res.html(safe.html.fragment("#{safe.html.raw(\"}\")}"))
}
