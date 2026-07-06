function handler(x: Str|Untrusted<Str>) {
  let html = "<p>#{x}</p>"
  ctx.res.html(safe.html.raw(html))
}
