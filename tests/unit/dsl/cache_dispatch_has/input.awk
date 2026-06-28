function handler() {
    let v: Result<Bool, CacheError> = cache.has("k")
    return v
}
