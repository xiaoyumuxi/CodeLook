// The Quick Look extension's highlighter: Lithe's editor syntax engine (TextMate grammars,
// language table, color schemes) built as a C static library. The module path sits under
// Lithe's desktop module so it may import the editor's internal packages; Lithe itself is
// read from the checkout next to CodeLook and is not changed.
module github.com/1lck/Lithe-IDEA/desktop/codelookbridge

go 1.26.0

toolchain go1.27.4

require (
	github.com/1lck/Lithe-IDEA/desktop v0.0.0
	gopkg.in/yaml.v3 v3.0.1
)

replace github.com/1lck/Lithe-IDEA/desktop => ../../Lithe-IDEA/desktop

replace github.com/vivaui/viva => github.com/Lithe-IDEA/viva v0.6.8-0.20261123134538-bb85256c8ffa
