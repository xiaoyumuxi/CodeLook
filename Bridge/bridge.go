// Package main is the C interface of Lithe's syntax engine for the Quick Look extension
// (built with -buildmode=c-archive; the header is LitheSyntax.h).
//
// A document is opened once with its whole text. Lithe's Highlighter keeps tokenizer states at
// checkpoints and tokenizes a line only when it is asked for, so the view asks for the lines it
// draws and nothing else is computed up front. Offsets in the results are UTF-16 units within
// the line, which is what the view's strings are indexed by.
package main

/*
#include <stdint.h>
#include <stdlib.h>
typedef const char ls_cstr;
typedef void (*ls_changed_fn)(void *context, int32_t first, int32_t last);
static inline void ls_call_changed(ls_changed_fn f, void *context, int32_t first, int32_t last) {
	f(context, first, last);
}
*/
import "C"

import (
	"encoding/json"
	"runtime/cgo"
	"sync"
	"unicode/utf8"
	"unsafe"

	"codelook/internal/rope"
	"codelook/internal/syntax"
)

var registry = sync.OnceValue(syntax.NewRegistry)

type document struct {
	text        rope.Rope
	highlighter *syntax.Highlighter
	mu          sync.Mutex // guards tokens and line, the scratch of ls_line
	tokens      []syntax.Token
	line        []byte
	// callbacks is held for reading while changed runs and for writing by ls_close, so no
	// callback runs once ls_close returns (Highlighter.Close does not wait for its goroutine).
	callbacks sync.RWMutex
	closed    bool
}

// ls_language_for_path returns the Lithe language ID of a file name (into buf, NUL-terminated),
// or 0 when Lithe has no language with a grammar for it.
//
//export ls_language_for_path
func ls_language_for_path(path *C.ls_cstr, buf *C.char, size C.int32_t) C.int32_t {
	s := registry().SyntaxForPath(goString(path))
	if s == nil {
		return 0
	}
	return copyOut(s.Language().ID, buf, size)
}

// ls_has_language reports whether Lithe colors language id (or an alias of it, as "bash").
//
//export ls_has_language
func ls_has_language(id *C.ls_cstr) C.int32_t {
	if registry().Syntax(goString(id)) != nil {
		return 1
	}
	return 0
}

// ls_open starts highlighting text (UTF-8, length bytes) as language id; an unknown id shows it
// plain. changed, when not NULL, is called from a background thread with lines whose colors
// changed after they were read. The result is a handle for the other calls; ls_close frees it.
//
//export ls_open
func ls_open(id *C.ls_cstr, text *C.ls_cstr, length C.int64_t, changed C.ls_changed_fn, context unsafe.Pointer) C.uintptr_t {
	d := &document{text: rope.New(C.GoBytes(unsafe.Pointer(text), C.int(length)))}
	var options syntax.HighlighterOptions
	if changed != nil {
		options.OnChange = func(first, last int) {
			d.callbacks.RLock()
			defer d.callbacks.RUnlock()
			if !d.closed {
				C.ls_call_changed(changed, context, C.int32_t(first), C.int32_t(last))
			}
		}
	}
	d.highlighter = syntax.NewHighlighter(registry().Syntax(goString(id)), d.text, options)
	return C.uintptr_t(cgo.NewHandle(d))
}

// ls_close stops background work and frees the document. No callback runs after it returns.
//
//export ls_close
func ls_close(h C.uintptr_t) {
	handle := cgo.Handle(h)
	d := handle.Value().(*document)
	d.highlighter.Close()
	d.callbacks.Lock()
	d.closed = true
	d.callbacks.Unlock()
	handle.Delete()
}

// ls_prepare tokenizes lines first to last (0-based, inclusive) if they are not yet: what the
// view is about to draw.
//
//export ls_prepare
func ls_prepare(h C.uintptr_t, first, last C.int32_t) {
	d := cgo.Handle(h).Value().(*document)
	d.highlighter.Prepare(int(first), int(last))
}

// ls_line writes the styled runs of a line as triples (start, 0xRRGGBB, font) into out, at most
// capacity triples, and returns how many the line has: more than capacity means call again with
// room for them all. start is in UTF-16 units from the start of the line; a run goes to the next
// run's start or the end of the line. font has bit 0 italic, bit 1 bold, bit 2 underline, bit 3
// strikethrough.
//
//export ls_line
func ls_line(h C.uintptr_t, line C.int32_t, dark C.int32_t, out *C.uint32_t, capacity C.int32_t) C.int32_t {
	d := cgo.Handle(h).Value().(*document)
	theme := currentThemes()[dark&1]
	d.mu.Lock()
	defer d.mu.Unlock()
	d.tokens = d.highlighter.Line(d.tokens[:0], int(line))
	d.line = d.text.AppendLine(d.line[:0], int(line))
	if len(d.tokens) > int(capacity) {
		return C.int32_t(len(d.tokens))
	}
	dst := unsafe.Slice((*uint32)(unsafe.Pointer(out)), int(capacity)*3)
	n, at, units := 0, 0, 0
	for _, t := range d.tokens {
		for at < int(t.Start) && at < len(d.line) {
			r, size := utf8.DecodeRune(d.line[at:])
			at += size
			units += 1 + boolInt(r >= 0x10000)
		}
		style := theme.Style(t.Name)
		dst[n*3], dst[n*3+1], dst[n*3+2] = uint32(units), uint32(style.Foreground), uint32(style.Font)
		n++
	}
	return C.int32_t(n)
}

// ls_default_color is the text color of the theme, 0xRRGGBB.
//
//export ls_default_color
func ls_default_color(dark C.int32_t) C.uint32_t {
	return C.uint32_t(currentThemes()[dark&1].Default().Foreground)
}

// ls_configure reads the settings file at path (NULL, "" or a missing file: the defaults),
// applies its colors and grammars to the engine and returns the settings as JSON, defaults
// filled in, with what was wrong in "problems". The caller frees the result with free().
//
//export ls_configure
func ls_configure(path *C.ls_cstr) *C.char {
	p := ""
	if path != nil {
		p = goString(path)
	}
	data, err := json.Marshal(configure(p))
	if err != nil {
		data = []byte(`{"problems":["internal: ` + err.Error() + `"]}`)
	}
	return C.CString(string(data))
}

// ls_bundled_languages writes "id ext ext …\n" for every language Lithe colors (into buf) and
// returns the length needed, so a caller can retry with a larger buffer.
//
//export ls_bundled_languages
func ls_bundled_languages(buf *C.char, size C.int32_t) C.int32_t {
	var b []byte
	for _, t := range syntax.BundledFileTypes() {
		if !t.Highlighted {
			continue
		}
		b = append(b, t.ID...)
		for _, e := range t.Extensions {
			b = append(b, ' ')
			b = append(b, e...)
		}
		b = append(b, '\n')
	}
	return copyOut(string(b), buf, size)
}

func goString(s *C.ls_cstr) string { return C.GoString((*C.char)(unsafe.Pointer(s))) }

func copyOut(s string, buf *C.char, size C.int32_t) C.int32_t {
	if int(size) > len(s) {
		dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(size))
		copy(dst, s)
		dst[len(s)] = 0
	}
	return C.int32_t(len(s))
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func main() {}
