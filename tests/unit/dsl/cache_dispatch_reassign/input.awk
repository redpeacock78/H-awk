function handler() {
    let mut v: Effect<Result<Bool, CacheError>>
    v = cache.has("k")
}
