function handler() {
    let v: Result<Void, CacheError> = cache.set("k", "v", 60)
    return v
}
