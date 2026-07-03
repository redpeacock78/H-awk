function handler(Raw: Untrusted<Str>) -> Response {
  return ctx.res.html(safe.html.raw(Raw))
}
