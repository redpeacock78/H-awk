function my_sanitize(s: Str) -> Str {
  classify: sanitizer
  return s
}

function handler(raw: Untrusted<Str>) -> Response {
  let clean = raw |> my_sanitize()
  return ctx.res.html(safe.html.raw(clean))
}
