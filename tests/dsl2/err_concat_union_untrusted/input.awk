function handler(x: Str|Untrusted<Str>) {
  ctx.res.html(safe.html.raw(x "!"))
}
