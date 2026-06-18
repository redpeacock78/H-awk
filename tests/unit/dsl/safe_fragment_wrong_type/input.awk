function handler() -> Response {
  let raw: Str = "untrusted"
  return ctx.res.html(safe.html.fragment(raw))
}
