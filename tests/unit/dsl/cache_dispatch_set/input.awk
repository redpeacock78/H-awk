function handler() {
    let v: Effect<Result<Void, CacheError>> = cache.set("k", "v", 60)
    return v
}
