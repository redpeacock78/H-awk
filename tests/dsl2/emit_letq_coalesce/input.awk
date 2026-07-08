function load(k) -> Effect<Result<Option<Str>, CacheError>> {
    let opt: Option<Str> ?= cache.get(k)
    when opt of
      some v:
        return cache.get(v)
      none:
        return cache.get(k)
    end
}

function setup() {
  let port: Int | Str = env.get("PORT") ?? 8080
}
