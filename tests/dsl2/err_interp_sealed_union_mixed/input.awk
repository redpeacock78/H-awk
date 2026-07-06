function g(ctx) -> Str | Result<Untrusted<Str>, ParseError> { return ctx.req.form("name") }
function handler(ctx) -> Str { return "#{g(ctx) "y"}" }
