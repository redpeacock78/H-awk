type AuthError = Error

function authenticate(auth: Option<Str>) -> Result<Map, AuthError> {
  return AuthError("bad")
}

function h() -> Response {
  let user ?= authenticate(ctx.req.get_header("Authorization"))
  return ctx.res.text(user["name"])
}
