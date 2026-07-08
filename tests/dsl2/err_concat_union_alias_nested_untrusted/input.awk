type U = Str|Untrusted<Str>

function handler(x: U) {
  ctx.res.html(safe.html.raw(x "!"))
}
