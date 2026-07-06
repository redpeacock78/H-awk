type MaybeStr = Option<Str>

function get() -> MaybeStr {
  return option.none()
}

function handler(ctx) {
  let x ?= get()
  let y = x
}
