function handler(body: Str) -> Response {
  return ctx.res.html(safe.html.fragment("#{safe.html.raw(json.decode<Int>(body))}"))
}
