function fallback() -> Str { return "fb" }
function h(v: Str) -> Str { return v }
function f() -> Str {
  return env.get("X") ?? (fallback() |> h())
}
