type U = Untrusted<Str>

function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(raw: U) -> Response {
  let clean = strip(raw)
  return ctx.res.html(safe.html.raw(clean))
}
