function handler(ctx) {
  let raw: Str = "x"
  let esc: HtmlEscapedStr = safe.html.escape(raw)
  let r: Response = ctx.res.html(raw esc)
}
