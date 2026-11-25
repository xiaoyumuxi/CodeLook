// The Quick Look extension's highlighter: Lithe's editor syntax engine (TextMate grammars,
// language table, color schemes) built as a C static library. The engine's packages live in
// internal/ (copied from Lithe, see internal/README.md); nothing outside this repository is needed.
module codelook

go 1.26.0

// Same toolchain as Lithe, so gofmt output and the engine's behavior match it.
toolchain go1.27.4

require gopkg.in/yaml.v3 v3.0.1
