type U = Untrusted<Str>

function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(raw: U) -> Response {
  let x = raw |> strip()
  return ctx.res.html(safe.html.raw(x))
}
