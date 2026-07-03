function handler(raw: Untrusted<Str>) -> Response {
  return ctx.res.html(safe.html.fragment("#{safe.html.raw(raw \"\")}"))
}
