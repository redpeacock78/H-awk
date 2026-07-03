function handler(ctx, raw: Untrusted<Str>) {
  let s: Str = "<p>#{safe.html.escape(raw) raw}</p>"
}
