function get_user(x) {
  return x
}

function validate_user(x) {
  return x
}

function handler() -> Response {
  return get_user(ctx.req.param("id")) |> validate_user()
}
