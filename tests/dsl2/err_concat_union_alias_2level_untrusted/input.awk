type U = Str|Untrusted<Str>
type U2 = Int|U

function handler(x: U2) {
  ctx.res.html(safe.html.raw(x "!"))
}
