function handler() -> Response {
  let out: Str = "<p>Hello</p>"
  return ctx.res.html(html_raw(out))
}
