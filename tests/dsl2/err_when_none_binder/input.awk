function handler(ctx) -> Str {
  let opt = option.none()
  when opt of
    some x: return x
    none raw: return ctx.res.html(raw)
  end
}
