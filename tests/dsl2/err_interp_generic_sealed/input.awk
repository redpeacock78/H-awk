function handler(body: Str) -> Response {
  return ctx.res.html(safe.html.fragment("#{json.decode<Int>(body)}"))
}
