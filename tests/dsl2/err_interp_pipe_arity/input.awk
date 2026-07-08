function handler(raw: Str) -> Response {
  return ctx.res.html(safe.html.fragment("#{raw |> safe.html.raw(raw)}"))
}
