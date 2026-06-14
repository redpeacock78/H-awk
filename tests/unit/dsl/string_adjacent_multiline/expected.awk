function handler(    html) {
  html = "<tr><td>Hello</td></tr>"
  return ctx::dispatch("res.text", html)
}
