function handler() {
    let v: Effect<Result<Option<Str>, CacheError>> = cache.get("k")
    return v
}
