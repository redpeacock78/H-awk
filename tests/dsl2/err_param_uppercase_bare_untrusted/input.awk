function handler(Raw, y: Untrusted<Str>) -> Response {
  return ctx.res.html(safe.html.raw(y))
}
