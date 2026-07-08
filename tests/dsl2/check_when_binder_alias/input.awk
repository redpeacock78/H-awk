type MaybeStr = Option<Str>

function get() -> MaybeStr {
  return option.none()
}

function handler() -> Str {
  when get() of
    some v: return v
    none: return ""
  end
}
