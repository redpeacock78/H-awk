function handler(x: Str) -> Response {
  return ctx.res.html(safe.html.fragment("#{safe.html.raw(safe.str.trust(x))}"))
}
