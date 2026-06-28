function handler() {
    let v: Result<Bool, CacheError> = cache.del("k")
    return v
}
