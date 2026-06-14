function handler() -> Response {
  let html: Str = "<p>Hello</p>"
  return ctx.res.html(html)
}
