function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(raw: Untrusted<Str>) -> Response {
  return ctx.res.html(safe.html.raw("#{raw |> strip()}"))
}
