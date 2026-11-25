package main

// The settings file (config.yaml). Everything about the preview is set here, there is no
// settings window: the syntax side (color scheme, token colors, extra TextMate grammars) is
// applied to Lithe's engine right here; the view side (font, view colors, limits, file name
// mappings) is checked and handed to Swift as JSON.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"codelook/internal/syntax"
	"gopkg.in/yaml.v3"
)

type fileConfig struct {
	Font struct {
		Family     string  `yaml:"family"`
		Size       float64 `yaml:"size"`
		LineHeight float64 `yaml:"lineHeight"`
		Ligatures  *bool   `yaml:"ligatures"`
	} `yaml:"font"`
	View struct {
		TabWidth    int   `yaml:"tabWidth"`
		LineNumbers *bool `yaml:"lineNumbers"`
	} `yaml:"view"`
	Theme struct {
		Scheme         string            `yaml:"scheme"`
		ItalicComments bool              `yaml:"italicComments"`
		Tokens         map[string]string `yaml:"tokens"`
		Light          appearance        `yaml:"light"`
		Dark           appearance        `yaml:"dark"`
	} `yaml:"theme"`
	Files    map[string]string `yaml:"files"`
	Grammars []grammarConfig   `yaml:"grammars"`
	Limits   struct {
		MaxFileSize byteSize `yaml:"maxFileSize"`
		MaxLines    int      `yaml:"maxLines"`
	} `yaml:"limits"`
}

type appearance struct {
	Background string            `yaml:"background"`
	Text       string            `yaml:"text"`
	LineNumber string            `yaml:"lineNumber"`
	Selection  string            `yaml:"selection"`
	Tokens     map[string]string `yaml:"tokens"`
}

type grammarConfig struct {
	Language   string            `yaml:"language"`
	Name       string            `yaml:"name"`
	Grammar    string            `yaml:"grammar"`
	Extensions []string          `yaml:"extensions"`
	FileNames  []string          `yaml:"fileNames"`
	Scopes     map[string]string `yaml:"scopes"`
}

// byteSize is a number of bytes, or a string such as "8MB" or "512 KB".
type byteSize int64

func (b *byteSize) UnmarshalYAML(node *yaml.Node) error {
	s := strings.ToUpper(strings.ReplaceAll(node.Value, " ", ""))
	unit := int64(1)
	for _, u := range []struct {
		suffix string
		n      int64
	}{{"GB", 1 << 30}, {"MB", 1 << 20}, {"KB", 1 << 10}, {"G", 1 << 30}, {"M", 1 << 20}, {"K", 1 << 10}, {"B", 1}} {
		if strings.HasSuffix(s, u.suffix) {
			s, unit = strings.TrimSuffix(s, u.suffix), u.n
			break
		}
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil || n <= 0 {
		return fmt.Errorf("line %d: %q is not a size such as 8MB", node.Line, node.Value)
	}
	*b = byteSize(n * float64(unit))
	return nil
}

// configResult is what Swift gets back: the settings with defaults filled in, and what was
// wrong with the file.
type configResult struct {
	Path        string            `json:"path"`
	Exists      bool              `json:"exists"`
	Problems    []string          `json:"problems"`
	Font        fontResult        `json:"font"`
	TabWidth    int               `json:"tabWidth"`
	LineNumbers bool              `json:"lineNumbers"`
	MaxBytes    int64             `json:"maxBytes"`
	MaxLines    int               `json:"maxLines"`
	Light       viewColors        `json:"light"`
	Dark        viewColors        `json:"dark"`
	Files       map[string]string `json:"files"`
	Languages   map[string]string `json:"languages"`
	Extensions  []string          `json:"extensions"`
	FileNames   []string          `json:"fileNames"`
	Watch       []string          `json:"watch"`
}

type fontResult struct {
	Family     string  `json:"family"`
	Size       float64 `json:"size"`
	LineHeight float64 `json:"lineHeight"`
	Ligatures  bool    `json:"ligatures"`
}

// viewColors are 0xRRGGBB, absent for the defaults; text is always the theme's.
type viewColors struct {
	Background *uint32 `json:"background,omitempty"`
	Text       uint32  `json:"text"`
	LineNumber *uint32 `json:"lineNumber,omitempty"`
	Selection  *uint32 `json:"selection,omitempty"`
}

var (
	// themes are the light and dark themes ls_line colors with; configure replaces them.
	themes       atomic.Pointer[[2]*syntax.Theme]
	defaultTheme sync.Once
	// configureMu keeps two configure calls from interleaving their registry updates.
	configureMu sync.Mutex
)

func currentThemes() *[2]*syntax.Theme {
	if t := themes.Load(); t != nil {
		return t
	}
	defaultTheme.Do(func() {
		t := buildThemes(&fileConfig{}, nil)
		themes.CompareAndSwap(nil, &t)
	})
	return themes.Load()
}

var schemes = []string{syntax.SchemeLithe, syntax.SchemeIDEA, syntax.SchemeVSCode, syntax.SchemeGitHub, syntax.SchemeOne}

// configure reads the settings at path (missing or "" means the defaults), applies the syntax
// side and returns the rest.
func configure(path string) configResult {
	configureMu.Lock()
	defer configureMu.Unlock()

	r := configResult{Path: path}
	var c fileConfig
	problem := func(format string, args ...any) { r.Problems = append(r.Problems, fmt.Sprintf(format, args...)) }

	if path != "" {
		data, err := os.ReadFile(path)
		switch {
		case err == nil:
			r.Exists = true
			r.Watch = append(r.Watch, path)
			decoder := yaml.NewDecoder(bytes.NewReader(data))
			decoder.KnownFields(true)
			err = decoder.Decode(&c)
			var typeErr *yaml.TypeError
			switch {
			case err == nil, errors.Is(err, io.EOF):
			case errors.As(err, &typeErr):
				// The rest of the file is applied; only these values are skipped.
				for _, e := range typeErr.Errors {
					problem("%s", readable(e))
				}
			default:
				problem("%s (the whole file is ignored)", readable(err.Error()))
				c = fileConfig{}
			}
		case errors.Is(err, fs.ErrNotExist):
		default:
			problem("cannot read it: %v", err)
		}
	}

	// Font and view
	r.Font = fontResult{Family: "JetBrains Mono", Size: 12, LineHeight: 1.5}
	if c.Font.Family != "" {
		r.Font.Family = c.Font.Family
	}
	if s := c.Font.Size; s != 0 {
		if s >= 6 && s <= 72 {
			r.Font.Size = s
		} else {
			problem("font.size %v is out of range (6–72)", s)
		}
	}
	if h := c.Font.LineHeight; h != 0 {
		if h > 0 && h <= 100 {
			r.Font.LineHeight = h
		} else {
			problem("font.lineHeight %v is out of range", h)
		}
	}
	if c.Font.Ligatures != nil {
		r.Font.Ligatures = *c.Font.Ligatures
	}
	r.TabWidth = 4
	if t := c.View.TabWidth; t != 0 {
		if t >= 1 && t <= 16 {
			r.TabWidth = t
		} else {
			problem("view.tabWidth %d is out of range (1–16)", t)
		}
	}
	r.LineNumbers = c.View.LineNumbers == nil || *c.View.LineNumbers
	r.MaxBytes, r.MaxLines = 8<<20, 1_000_000
	if b := int64(c.Limits.MaxFileSize); b > 0 {
		r.MaxBytes = min(b, 256<<20)
	}
	if n := c.Limits.MaxLines; n != 0 {
		if n > 0 {
			r.MaxLines = n
		} else {
			problem("limits.maxLines must be positive")
		}
	}

	// Colors
	if c.Theme.Scheme != "" && !contains(schemes, c.Theme.Scheme) {
		problem("theme.scheme %q is not one of %s", c.Theme.Scheme, strings.Join(schemes, ", "))
		c.Theme.Scheme = ""
	}
	t := buildThemes(&c, problem)
	themes.Store(&t)
	for i, a := range []appearance{c.Theme.Light, c.Theme.Dark} {
		name := [2]string{"light", "dark"}[i]
		v := viewColors{Text: uint32(t[i].Default().Foreground)}
		v.Background = viewColor(a.Background, "theme."+name+".background", problem)
		v.LineNumber = viewColor(a.LineNumber, "theme."+name+".lineNumber", problem)
		v.Selection = viewColor(a.Selection, "theme."+name+".selection", problem)
		if i == 0 {
			r.Light = v
		} else {
			r.Dark = v
		}
	}

	// Grammars
	dir := filepath.Dir(path)
	var plugins []syntax.PluginLanguage
	r.Languages = map[string]string{}
	for i, g := range c.Grammars {
		where := fmt.Sprintf("grammars[%d]", i)
		if g.Language == "" {
			problem("%s: language is missing", where)
			continue
		}
		where = "grammar " + g.Language
		p := syntax.PluginLanguage{ID: g.Language, Extensions: g.Extensions, FileNames: g.FileNames}
		if g.Grammar != "" {
			file := resolvePath(dir, g.Grammar)
			r.Watch = append(r.Watch, file)
			data, err := readGrammar(file)
			if err != nil {
				problem("%s: %v", where, err)
				continue
			}
			p.Grammar = data
		} else if registry().Syntax(g.Language) == nil {
			problem("%s: no grammar file, and Lithe has no grammar for %q", where, g.Language)
			continue
		}
		if len(g.Scopes) > 0 {
			scopes := make([]string, 0, len(g.Scopes))
			for scope := range g.Scopes {
				scopes = append(scopes, scope)
			}
			// More specific scopes first, so "markup.inserted.diff" wins over "markup".
			sort.Slice(scopes, func(a, b int) bool { return len(scopes[a]) > len(scopes[b]) })
			for _, scope := range scopes {
				p.Rules = append(p.Rules, syntax.Rule{Scope: scope, Token: g.Scopes[scope]})
			}
			p.Rules = append(p.Rules, syntax.DefaultRules...)
		}
		plugins = append(plugins, p)
		name := g.Name
		if name == "" {
			name = g.Language
		}
		r.Languages[g.Language] = name
		r.Extensions = append(r.Extensions, normalizeExtensions(g.Extensions)...)
		r.FileNames = append(r.FileNames, g.FileNames...)
	}
	failed, _ := registry().SetPluginLanguages(plugins)
	for _, f := range failed {
		problem("grammar %s: %v", f.ID, f.Err)
		delete(r.Languages, f.ID)
	}

	// File names and extensions → languages ("*.foo" and ".foo" are extensions).
	r.Files = map[string]string{}
	for key, language := range c.Files {
		key = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(key, "*")))
		if key == "" || key == "." {
			problem("files: empty name")
			continue
		}
		r.Files[key] = strings.TrimSpace(language)
		if strings.HasPrefix(key, ".") {
			r.Extensions = append(r.Extensions, key[1:])
		} else {
			r.FileNames = append(r.FileNames, key)
		}
	}
	r.Extensions = dedupe(r.Extensions)
	r.FileNames = dedupe(r.FileNames)
	return r
}

// buildThemes builds the light and dark themes: the scheme, then the token styles of
// theme.tokens and those of the appearance on top.
func buildThemes(c *fileConfig, problem func(string, ...any)) [2]*syntax.Theme {
	var out [2]*syntax.Theme
	scheme := c.Theme.Scheme
	if scheme == "" {
		scheme = syntax.SchemeLithe
	}
	palette := syntax.DefaultPalette()
	for i, a := range []appearance{c.Theme.Light, c.Theme.Dark} {
		dark := i == 1
		opts := syntax.ThemeOptions{Dark: dark, Scheme: scheme, ItalicComments: c.Theme.ItalicComments}
		custom := &syntax.CustomTheme{Dark: dark, Tokens: map[string]syntax.CustomTokenStyle{}}
		for j, tokens := range []map[string]string{c.Theme.Tokens, a.Tokens} {
			where := "theme.tokens"
			if j == 1 {
				where = "theme." + [2]string{"light", "dark"}[i] + ".tokens"
			}
			for name, spec := range tokens {
				style, err := tokenStyle(spec)
				if err != nil {
					// theme.tokens is read for both appearances; report it once.
					if problem != nil && (j == 1 || i == 0) {
						problem("%s.%s: %v", where, name, err)
					}
					continue
				}
				custom.Tokens[name] = style
			}
		}
		if a.Text != "" {
			if color, ok := hexColor(a.Text); ok {
				custom.Colors = map[string]string{"foreground": color}
			} else if problem != nil {
				problem("theme.%s.text: %q is not a color such as #1F2328", [2]string{"light", "dark"}[i], a.Text)
			}
		}
		if len(custom.Tokens) > 0 || custom.Colors != nil {
			opts.Custom = custom
		}
		out[i] = syntax.BuildTheme(opts, palette)
	}
	return out
}

// tokenStyle reads "#RRGGBB bold italic": a color, font styles, or both. "regular" clears the
// scheme's bold or italic.
func tokenStyle(spec string) (syntax.CustomTokenStyle, error) {
	var style syntax.CustomTokenStyle
	var fonts []string
	for _, word := range strings.Fields(spec) {
		switch w := strings.ToLower(word); w {
		case "bold", "italic", "underline", "strikethrough":
			fonts = append(fonts, w)
			style.SetsFontStyle = true
		case "regular", "normal", "plain":
			style.SetsFontStyle = true
		default:
			color, ok := hexColor(word)
			if !ok {
				return style, fmt.Errorf("%q is neither a color such as #0033B3 nor bold, italic, underline, strikethrough, regular", word)
			}
			style.Foreground = color
		}
	}
	if style.Foreground == "" && !style.SetsFontStyle {
		return style, errors.New("empty style")
	}
	style.FontStyle = strings.Join(fonts, " ")
	return style, nil
}

var hexPattern = regexp.MustCompile(`^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$`)

// hexColor normalizes "#abc", "abc", "#AABBCC" and "#AABBCCDD" to "#AABBCC" / "#AABBCCDD".
func hexColor(s string) (string, bool) {
	m := hexPattern.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return "", false
	}
	h := strings.ToUpper(m[1])
	if len(h) == 3 {
		h = string([]byte{h[0], h[0], h[1], h[1], h[2], h[2]})
	}
	return "#" + h, true
}

func viewColor(s, where string, problem func(string, ...any)) *uint32 {
	if s == "" {
		return nil
	}
	color, ok := hexColor(s)
	if !ok {
		problem("%s: %q is not a color such as #FFFFFF", where, s)
		return nil
	}
	n, _ := strconv.ParseUint(color[1:7], 16, 32)
	v := uint32(n)
	return &v
}

// readGrammar reads a TextMate grammar in JSON, or in YAML (.yaml, .yml) converted to JSON.
func readGrammar(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".yaml", ".yml":
		var v any
		if err := yaml.Unmarshal(data, &v); err != nil {
			return nil, err
		}
		return json.Marshal(v)
	case ".tmlanguage", ".plist":
		return nil, errors.New("plist grammars are not supported; use the JSON or YAML form (.tmLanguage.json)")
	}
	return data, nil
}

func resolvePath(dir, p string) string {
	if strings.HasPrefix(p, "~/") {
		if u, err := user.Current(); err == nil {
			return filepath.Join(u.HomeDir, p[2:])
		}
	}
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(dir, p)
}

func normalizeExtensions(list []string) []string {
	out := make([]string, 0, len(list))
	for _, e := range list {
		if e = strings.ToLower(strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(e), "*"), ".")); e != "" {
			out = append(out, e)
		}
	}
	return out
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	out := list[:0]
	for _, s := range list {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// The type yaml.v3 names can be an anonymous struct, spaces and all: drop the rest of the line.
var unknownField = regexp.MustCompile(`(?m)field (\S+) not found in type .*$`)

// readable turns yaml.v3's messages into ones about settings.
func readable(msg string) string {
	msg = strings.TrimPrefix(msg, "yaml: ")
	msg = unknownField.ReplaceAllString(msg, `unknown setting "$1"`)
	return strings.ReplaceAll(msg, "unmarshal errors:\n  ", "")
}
