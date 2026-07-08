function handler(raw: Untrusted<Str>) -> HtmlFragment {
  return safe.html.fragment("<p>#{safe.html.raw(raw)}</p>")
}
