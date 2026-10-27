package maintenance

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// This deliberately small parser extracts data, never a JavaScript program.
// Only the target declarations' arrays/objects/strings/numbers/booleans/Infinity
// are interpreted. Calls, spreads, computed properties and expressions fail.
type literalToken struct {
	kind, text string
	value      any
	offset     int
}

var literalNumber = regexp.MustCompile(`^(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9_]+)(?:[eE][+-]?[0-9_]+)?)`)

func literalTokens(source string) ([]literalToken, error) {
	tokens := []literalToken{}
	for i := 0; i < len(source); {
		start := i
		r, size := utf8.DecodeRuneInString(source[i:])
		if r == utf8.RuneError && size == 1 {
			return nil, errors.New("official source is not UTF-8")
		}
		if unicode.IsSpace(r) {
			i += size
			continue
		}
		if strings.HasPrefix(source[i:], "//") {
			end := strings.IndexByte(source[i:], '\n')
			if end < 0 {
				break
			}
			i += end + 1
			continue
		}
		if strings.HasPrefix(source[i:], "/*") {
			end := strings.Index(source[i+2:], "*/")
			if end < 0 {
				return nil, errors.New("unterminated source comment")
			}
			i += end + 4
			continue
		}
		if r == '\'' || r == '"' {
			value, end, err := literalString(source, i)
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, literalToken{kind: "string", text: source[i:end], value: value, offset: i})
			i = end
			continue
		}
		if r == '`' {
			i++
			closed := false
			for i < len(source) {
				if source[i] == '\\' {
					i += 2
					continue
				}
				if source[i] == '`' {
					i++
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, errors.New("unterminated template literal")
			}
			tokens = append(tokens, literalToken{kind: "unsupported", text: "template literal", offset: start})
			continue
		}
		if unicode.IsLetter(r) || r == '_' || r == '$' {
			i += size
			for i < len(source) {
				next, n := utf8.DecodeRuneInString(source[i:])
				if !unicode.IsLetter(next) && !unicode.IsDigit(next) && next != '_' && next != '$' {
					break
				}
				i += n
			}
			tokens = append(tokens, literalToken{kind: "identifier", text: source[start:i], offset: start})
			continue
		}
		if r >= '0' && r <= '9' || r == '.' && i+1 < len(source) && source[i+1] >= '0' && source[i+1] <= '9' {
			value := literalNumber.FindString(source[i:])
			if value == "" {
				return nil, errors.New("invalid source number")
			}
			clean := strings.ReplaceAll(value, "_", "")
			var number float64
			var err error
			if strings.HasPrefix(clean, "0x") || strings.HasPrefix(clean, "0X") || strings.HasPrefix(clean, "0b") || strings.HasPrefix(clean, "0B") || strings.HasPrefix(clean, "0o") || strings.HasPrefix(clean, "0O") {
				var integer uint64
				integer, err = strconv.ParseUint(clean, 0, 64)
				number = float64(integer)
			} else {
				number, err = strconv.ParseFloat(clean, 64)
			}
			if err != nil || math.IsInf(number, 0) || math.IsNaN(number) {
				return nil, errors.New("invalid source numeric literal")
			}
			tokens = append(tokens, literalToken{kind: "number", text: value, value: number, offset: start})
			i += len(value)
			continue
		}
		punct := source[i : i+size]
		for _, operator := range []string{"...", "=>", "===", "!==", "==", "!=", "<=", ">=", "&&", "||", "?.", "??", "++", "--", "**"} {
			if strings.HasPrefix(source[i:], operator) {
				punct = operator
				break
			}
		}
		tokens = append(tokens, literalToken{kind: "punct", text: punct, offset: i})
		i += len(punct)
	}
	return tokens, nil
}

func literalString(source string, start int) (string, int, error) {
	quote := source[start]
	var result strings.Builder
	for i := start + 1; i < len(source); {
		b := source[i]
		if b == quote {
			return result.String(), i + 1, nil
		}
		if b == '\n' || b == '\r' {
			return "", 0, errors.New("newline in source string")
		}
		if b != '\\' {
			r, size := utf8.DecodeRuneInString(source[i:])
			if r == utf8.RuneError && size == 1 {
				return "", 0, errors.New("invalid source string UTF-8")
			}
			result.WriteRune(r)
			i += size
			continue
		}
		i++
		if i >= len(source) {
			return "", 0, errors.New("unterminated source string escape")
		}
		escape := source[i]
		i++
		switch escape {
		case '\n':
			continue
		case '\r':
			if i < len(source) && source[i] == '\n' {
				i++
			}
			continue
		case 'n':
			result.WriteByte('\n')
		case 'r':
			result.WriteByte('\r')
		case 't':
			result.WriteByte('\t')
		case 'b':
			result.WriteByte('\b')
		case 'f':
			result.WriteByte('\f')
		case 'v':
			result.WriteByte('\v')
		case '0':
			if i < len(source) && source[i] >= '0' && source[i] <= '9' {
				return "", 0, errors.New("legacy octal escape is unsupported")
			}
			result.WriteByte(0)
		case 'x', 'u':
			count := 2
			if escape == 'u' {
				count = 4
			}
			digitsStart := i
			braced := escape == 'u' && i < len(source) && source[i] == '{'
			if braced {
				digitsStart++
				end := strings.IndexByte(source[digitsStart:], '}')
				if end < 1 || end > 6 {
					return "", 0, errors.New("invalid Unicode code-point escape")
				}
				count = end
				i = digitsStart
			}
			if i+count > len(source) {
				return "", 0, errors.New("short source string escape")
			}
			number, err := strconv.ParseUint(source[i:i+count], 16, 32)
			if err != nil || number > utf8.MaxRune {
				return "", 0, errors.New("invalid source string escape")
			}
			i += count
			if braced {
				i++
			}
			r := rune(number)
			if r >= 0xd800 && r <= 0xdbff && strings.HasPrefix(source[i:], "\\u") && i+6 <= len(source) {
				low, err := strconv.ParseUint(source[i+2:i+6], 16, 16)
				if err == nil && low >= 0xdc00 && low <= 0xdfff {
					r = utf16.DecodeRune(r, rune(low))
					i += 6
				}
			}
			if r >= 0xd800 && r <= 0xdfff {
				return "", 0, errors.New("unpaired Unicode surrogate is unsupported")
			}
			result.WriteRune(r)
		default:
			if escape >= '1' && escape <= '9' {
				return "", 0, errors.New("legacy numeric escape is unsupported")
			}
			result.WriteByte(escape)
		}
	}
	return "", 0, errors.New("unterminated source string")
}

type literalParser struct {
	tokens []literalToken
	index  int
	depth  int
}

func (p *literalParser) take(text string) bool {
	if p.index < len(p.tokens) && p.tokens[p.index].text == text {
		p.index++
		return true
	}
	return false
}
func (p *literalParser) value() (any, error) {
	if p.index >= len(p.tokens) {
		return nil, errors.New("missing data literal")
	}
	if p.depth >= 64 {
		return nil, errors.New("source literal nesting limit exceeded")
	}
	p.depth++
	defer func() { p.depth-- }()
	token := p.tokens[p.index]
	p.index++
	switch token.kind {
	case "string", "number":
		return token.value, nil
	case "identifier":
		switch token.text {
		case "true":
			return true, nil
		case "false":
			return false, nil
		case "Infinity":
			return math.Inf(1), nil
		}
	}
	if token.text == "[" {
		result := []any{}
		if p.take("]") {
			return result, nil
		}
		for {
			value, err := p.value()
			if err != nil {
				return nil, err
			}
			result = append(result, value)
			if len(result) > 16384 {
				return nil, errors.New("source literal collection limit exceeded")
			}
			if p.take("]") {
				return result, nil
			}
			if !p.take(",") {
				return nil, errors.New("array value is not a data literal")
			}
			if p.take("]") {
				return result, nil
			}
		}
	}
	if token.text == "{" {
		result := map[string]any{}
		if p.take("}") {
			return result, nil
		}
		for {
			if p.index >= len(p.tokens) {
				return nil, errors.New("unterminated object literal")
			}
			keyToken := p.tokens[p.index]
			p.index++
			key := keyToken.text
			if keyToken.kind == "string" {
				key = keyToken.value.(string)
			} else if keyToken.kind != "identifier" {
				return nil, errors.New("computed or unsupported source property")
			}
			if key == "__proto__" {
				return nil, errors.New("unsupported source property")
			}
			if _, exists := result[key]; exists {
				return nil, fmt.Errorf("duplicate source property: %s", key)
			}
			if !p.take(":") {
				return nil, errors.New("methods and shorthand source properties are unsupported")
			}
			value, err := p.value()
			if err != nil {
				return nil, err
			}
			result[key] = value
			if len(result) > 16384 {
				return nil, errors.New("source literal collection limit exceeded")
			}
			if p.take("}") {
				return result, nil
			}
			if !p.take(",") {
				return nil, errors.New("object value is not a data literal")
			}
			if p.take("}") {
				return result, nil
			}
		}
	}
	return nil, fmt.Errorf("unsupported data expression at byte %d: %s; inspect upstream source instead of executing it", token.offset, token.text)
}

func allowanceDeclarations(code string) (map[string]any, error) {
	tokens, err := literalTokens(code)
	if err != nil {
		return nil, err
	}
	result := map[string]any{}
	depth := 0
	for i := 0; i < len(tokens); i++ {
		token := tokens[i]
		if depth == 0 && (token.text == "const" || token.text == "let" || token.text == "var") && i+1 < len(tokens) {
			name := tokens[i+1].text
			if name == "goModels" || name == "plusLimits" {
				if _, exists := result[name]; exists {
					return nil, fmt.Errorf("duplicate allowance declaration: %s", name)
				}
				j := i + 2
				annotationDepth := 0
				for ; j < len(tokens); j++ {
					text := tokens[j].text
					if text == "=" && annotationDepth == 0 {
						break
					}
					if text == ";" && annotationDepth == 0 {
						return nil, errors.New("allowance declaration has no initializer")
					}
					if text == "(" || text == "[" || text == "{" {
						annotationDepth++
					}
					if text == ")" || text == "]" || text == "}" {
						annotationDepth--
						if annotationDepth < 0 {
							return nil, errors.New("invalid allowance declaration")
						}
					}
				}
				if j >= len(tokens) {
					return nil, errors.New("missing allowance initializer")
				}
				parser := literalParser{tokens: tokens, index: j + 1}
				value, err := parser.value()
				if err != nil {
					return nil, fmt.Errorf("%s: %w", name, err)
				}
				if parser.take(".") {
					if name != "goModels" || !parser.take("sort") || !parser.take("(") {
						return nil, errors.New("only goModels.sort(...) may wrap allowance data")
					}
					nesting := 1
					for parser.index < len(tokens) && nesting > 0 {
						current := tokens[parser.index].text
						parser.index++
						if current == "(" {
							nesting++
						}
						if current == ")" {
							nesting--
						}
					}
					if nesting != 0 {
						return nil, errors.New("unterminated goModels.sort call")
					}
				}
				// A following operator would make this an expression, not the
				// literal supported by the previous AST-based implementation.
				if parser.index < len(tokens) {
					next := tokens[parser.index]
					if next.text != ";" && next.text != "," && next.text != "export" && next.text != "const" && next.text != "let" && next.text != "var" && next.text != "function" && next.text != "type" && next.text != "interface" {
						return nil, fmt.Errorf("unsupported suffix after %s literal: %s", name, next.text)
					}
				}
				result[name] = value
				i = parser.index - 1
				continue
			}
		}
		if token.text == "{" || token.text == "[" || token.text == "(" {
			depth++
		}
		if token.text == "}" || token.text == "]" || token.text == ")" {
			depth--
			if depth < 0 {
				return nil, errors.New("unbalanced source delimiters")
			}
		}
	}
	if result["goModels"] == nil || result["plusLimits"] == nil {
		return nil, errors.New("official goModels or plusLimits declaration missing")
	}
	return result, nil
}
