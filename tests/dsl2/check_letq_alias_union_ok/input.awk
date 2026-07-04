type O = Option<Str>
type R = Result<Str, ParseError>

function get() -> O|R {
  return option.none()
}

function handler(ctx) {
  let x ?= get()
  let y = x
}
