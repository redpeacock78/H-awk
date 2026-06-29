function handler() {
    let r: Effect<Result<Void, CacheError>> = cache.set("k", "v", 60)
}
