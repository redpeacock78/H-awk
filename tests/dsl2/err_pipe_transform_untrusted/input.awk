function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(raw: Untrusted<Str>) -> Response {
  let clean = raw |> strip()
  return ctx.res.html(safe.html.raw(clean))
}
