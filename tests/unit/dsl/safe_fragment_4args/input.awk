function handler() -> Response {
  let a: HtmlEscapedStr = safe.html.escape("<b>")
  let b: HtmlEscapedStr = safe.html.escape("&")
  let c: HtmlEscapedStr = safe.html.escape("<i>")
  let d: HtmlEscapedStr = safe.html.escape("ok")
  return ctx.res.html(safe.html.fragment(a, b, c, d))
}
