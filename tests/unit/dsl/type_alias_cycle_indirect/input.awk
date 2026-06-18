type MyStr = Error
type WrappedErr = MyStr | Int
type MyStr = WrappedErr

function handler() -> Str {
  return "ok"
}
