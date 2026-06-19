function h() -> Response {
  let user ?= authenticate(ctx.req.get_header("Authorization"))
  return ctx.res.text(user["name"])
}
