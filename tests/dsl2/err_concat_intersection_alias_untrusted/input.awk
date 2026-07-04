type X = Str & Untrusted<Str>

function handler(x: X) {
  ctx.res.html(safe.html.raw(x "!"))
}
