function handler(raw: Untrusted<Str>) -> HtmlFragment {
  return safe.html.fragment("#{safe.html.raw(safe.str.trust(raw) raw)}")
}
