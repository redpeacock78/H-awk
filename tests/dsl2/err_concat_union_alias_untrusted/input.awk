type U = Untrusted<Str>

function handler(x: Str|U) {
  ctx.res.html(safe.html.raw(x "!"))
}
