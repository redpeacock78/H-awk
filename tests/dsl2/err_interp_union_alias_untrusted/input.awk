type U = Untrusted<Str>

function handler(x: Str|U) {
  let html = "<p>#{x}</p>"
  ctx.res.html(safe.html.raw(html))
}
