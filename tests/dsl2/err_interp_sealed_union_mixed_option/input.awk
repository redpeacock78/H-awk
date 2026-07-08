function g(ctx) -> Str | Option<Untrusted<Str>> { return option.none() }
function handler(ctx) -> Str { return "#{g(ctx) "y"}" }
