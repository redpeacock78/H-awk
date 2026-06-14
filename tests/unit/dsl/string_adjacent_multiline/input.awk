function handler() -> Response {
  let html: Str =
    "<tr>"
    "<td>Hello</td>"
    "</tr>"
  return ctx.res.text(html)
}
