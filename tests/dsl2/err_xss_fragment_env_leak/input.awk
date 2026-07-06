function f(raw: Str) -> HtmlFragment {
  return safe.html.fragment("<p>#{raw}</p>")
}
function g(raw: HtmlEscapedStr) -> HtmlFragment {
  return safe.html.fragment("<p>#{raw}</p>")
}
