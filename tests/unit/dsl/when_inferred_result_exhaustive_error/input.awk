type DbError = Error
type CacheError = Error

function fetch_backend(id: Str) -> Result<Str, DbError | CacheError> {
  return DbError("not found")
}

function fetch_user(id: Str) {
  return fetch_backend(id)
}

function handler() -> Response {
  when fetch_user("1") of
    ok u:
      return ctx.res.json(u)
    ng e<DbError>:
      return ctx.res.status(500)
  end
}
