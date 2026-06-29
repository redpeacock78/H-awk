function handler() {
    let v: Effect<Result<Bool, CacheError>> = cache.del("k")
    return v
}
