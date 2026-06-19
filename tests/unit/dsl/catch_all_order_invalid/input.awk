function h() -> Response {
  when fetch_user(ctx.req.param("id")) of
    ok user:
      return ctx.res.text(user)
    default:
      return ctx.res.status(500)
    ng eAuthError:
      return ctx.res.status(401)
  end
}
