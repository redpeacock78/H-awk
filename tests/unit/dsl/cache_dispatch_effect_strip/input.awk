function handler() {
    let r: Result<Void, CacheError> = cache.set("k", "v", 60)
}
