function handler() {
    let v: Effect<Result<Bool, CacheError>> = cache.has("k")
    return v
}
