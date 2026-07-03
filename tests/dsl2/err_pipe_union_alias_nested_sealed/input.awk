type S = Str|Result<Str, ParseError>

function handler(x: S) -> Str {
  return x |> safe.str.trust()
}
