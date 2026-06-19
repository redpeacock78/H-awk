function h() -> Response {
  let val: Int|Str = ctx.req.query_raw("n")
  return ctx.res.text(val)
}
