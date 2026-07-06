function handler(raw: Untrusted<Str>) -> HtmlFragment {
  return safe.html.fragment("<p>#{raw |> safe.html.raw()}</p>")
}
