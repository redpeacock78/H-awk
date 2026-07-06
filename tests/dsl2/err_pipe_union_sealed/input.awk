type R = Result<Str, ParseError>

function handler(x: R|Str) -> Str {
  return x |> safe.str.trust()
}
