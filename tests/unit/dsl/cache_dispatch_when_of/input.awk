function probe(k) -> Effect<Result<Option<Str>, CacheError>> {
    when cache.get(k) of
      ok r:
        when r of
          some v:
            return cache.get(v)
          none:
            return cache.get(k)
        end
      ng e:
        return cache.get(k)
    end
}
