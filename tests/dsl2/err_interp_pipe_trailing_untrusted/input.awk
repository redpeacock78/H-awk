function handler(raw: Untrusted<Str>) -> Response {
  return ctx.res.html(safe.html.raw("#{raw |> safe.html.escape() raw}"))
}
