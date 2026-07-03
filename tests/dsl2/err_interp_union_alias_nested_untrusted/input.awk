type U = Str|Untrusted<Str>

function handler(x: U) {
  let html = "<p>#{x}</p>"
  ctx.res.html(safe.html.raw(html))
}
