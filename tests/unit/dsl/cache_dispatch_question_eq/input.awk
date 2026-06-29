function load(k) -> Effect<Result<Option<Str>, CacheError>> {
    let opt: Option<Str> ?= cache.get(k)
    when opt of
      some v:
        return cache.get(v)
      none:
        return cache.get(k)
    end
}
