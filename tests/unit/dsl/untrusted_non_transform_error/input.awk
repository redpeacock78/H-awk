function process(s: Str) -> Str {
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let result = raw |> process()
}
