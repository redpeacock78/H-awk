type Status = Int | Str

function run() -> Response {
  return ctx.res.text("ok")
}
