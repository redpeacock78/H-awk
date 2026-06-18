function handler() -> Response {
  return get_user(ctx.req.param("id")) |> validate_user()
}
