function handler() {
    let v: Result<Option<Str>, CacheError> = cache.get("k")
    return v
}
