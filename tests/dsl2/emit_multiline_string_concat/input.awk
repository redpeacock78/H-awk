function build(title: Str) -> Str {
  let html: Str =
    "<tr>"
      "<td>bullet</td>"
      "<td>#{title}</td>"
      "</tr>"
  return html
}
