type U = Untrusted<Str>

function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(raw: U) -> Response {
  return ctx.res.text("#{raw |> strip()}")
}
