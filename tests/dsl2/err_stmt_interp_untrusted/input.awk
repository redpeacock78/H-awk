function handler(raw: Untrusted<Str>) {
  ctx.res.html(safe.html.raw("#{raw}"))
}
