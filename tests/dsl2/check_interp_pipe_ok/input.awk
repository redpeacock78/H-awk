function handler(ok: Str) -> HtmlFragment {
  return safe.html.fragment("<p>#{ok |> safe.html.escape()}</p>")
}
