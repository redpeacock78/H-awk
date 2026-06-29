function handler() {
    let v: Effect<Result<Bool, CacheError>>
    v = cache.has("k")
}
