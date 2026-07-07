function handler(ctx, k) {
  let opt ?= cache.get(k)
  when opt of
    some x: return
    none: return
  end
}
