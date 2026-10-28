package model

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf16"

	"github.com/dlclark/regexp2"
	whatwgurl "github.com/nlnwa/whatwg-url/url"
)

type AnswerValidation struct {
	Valid             bool                       `json:"valid"`
	Errors            map[string]string          `json:"errors"`
	ActiveQuestionIDs []string                   `json:"activeQuestionIds"`
	Answers           map[string]json.RawMessage `json:"answers"`
	// ValidatedFormValues contains native typed values, including active defaults.
	// It is internal handoff data, never accepted from a client.
	ValidatedFormValues map[string]any `json:"-"`
}

// ParsePublicJSONObjectAnswer accepts the JSON editor's encoded string, not an
// arbitrary object supplied in place of the public answer wire representation.
func ParsePublicJSONObjectAnswer(answer any) (Object, error) {
	text, ok := answer.(string)
	if !ok {
		return nil, errors.New("Answer must be a JSON object.")
	}
	value, err := Decode([]byte(text))
	if err != nil {
		return nil, errors.New("Answer must be valid JSON.")
	}
	object, ok := value.(map[string]any)
	if !ok || !finiteQuestionJSON(value) {
		return nil, errors.New("Answer must be a JSON object.")
	}
	return object, nil
}

func finiteQuestionJSON(value any) bool {
	switch value := value.(type) {
	case nil, bool, string:
		return true
	case json.Number:
		_, valid := number(value)
		return valid
	case []any:
		for _, item := range value {
			if !finiteQuestionJSON(item) {
				return false
			}
		}
		return true
	case map[string]any:
		for _, item := range value {
			if !finiteQuestionJSON(item) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

// ValidatePublicInteractionAnswers is deterministic preflight for the finite
// native form vocabulary. Conditions observe preceding validated form values;
// hidden/defaulted values participate, while hidden/inactive answers never leave
// the process. Wire option IDs are checked before decoding native option values.
func ValidatePublicInteractionAnswers(interaction PublicInteraction, input map[string]json.RawMessage) AnswerValidation {
	result := AnswerValidation{
		Errors: make(map[string]string), Answers: make(map[string]json.RawMessage), ValidatedFormValues: make(map[string]any),
		ActiveQuestionIDs: make([]string, 0, len(interaction.Questions)),
	}
	effective := make(map[string]any)
	known := make(map[string]bool, len(interaction.Questions))
	for _, question := range interaction.Questions {
		known[question.ID] = true
	}
	for id := range input {
		if !known[id] {
			result.Errors[id] = "Unknown question."
		}
	}
	for _, question := range interaction.Questions {
		form := question.Form
		if form != nil && !questionConditionsMatch(form.When, effective) {
			continue
		}
		hidden := form != nil && form.Hidden != nil && *form.Hidden
		if !hidden {
			result.ActiveQuestionIDs = append(result.ActiveQuestionIDs, question.ID)
		}
		raw, present := input[question.ID]
		if hidden {
			present = false
		}
		encoded, err := decodeQuestionWire(question, raw, present)
		if err != nil {
			result.Errors[question.ID] = err.Error()
			continue
		}
		if present && len(question.Options) > 0 && !question.AllowOther {
			for _, candidate := range questionAnswerStrings(encoded) {
				available := false
				for _, option := range question.Options {
					if option.Value == candidate {
						available = true
						break
					}
				}
				if !available {
					err = errors.New("Choose an available option.")
					break
				}
			}
		}
		if err != nil {
			result.Errors[question.ID] = err.Error()
			continue
		}
		// Only the empty string is omission here. Whitespace supplied explicitly
		// remains an answer and receives the native numeric decoding error.
		if form != nil && (form.Type == "number" || form.Type == "integer") && encoded == "" {
			present = false
		}
		if form != nil {
			value, hasValue, decodeErr := decodeQuestionFormAnswer(*form, encoded, present)
			if decodeErr != nil {
				err = decodeErr
			} else {
				var options []string
				if form.OptionValues != nil {
					options = make([]string, 0, len(form.OptionValues))
					for _, option := range form.OptionValues {
						options = append(options, option)
					}
				}
				if message := publicFormValueError(*form, value, hasValue, options, question.AllowOther); message != "" {
					err = errors.New(message)
				} else if hasValue {
					effective[question.ID] = value
					result.ValidatedFormValues[question.ID] = value
				}
			}
		} else {
			values := questionAnswerStrings(encoded)
			if !present || len(values) == 0 {
				err = errors.New("An answer is required.")
			}
			seen := make(map[string]bool)
			for _, value := range values {
				if trimQuestionSpace(value) == "" {
					err = errors.New("An answer is required.")
					break
				}
				if seen[value] {
					err = errors.New("Answers must not contain duplicates.")
				}
				seen[value] = true
			}
			if err == nil && question.AnswerFormat == "json-object" {
				_, err = ParsePublicJSONObjectAnswer(encoded)
			}
		}
		if err != nil {
			result.Errors[question.ID] = err.Error()
		} else if present {
			result.Answers[question.ID] = CloneRaw(raw)
		}
	}
	result.Valid = len(result.Errors) == 0
	return result
}

func decodeQuestionWire(question PublicInteractionQuestion, raw json.RawMessage, present bool) (any, error) {
	if !present {
		return nil, nil
	}
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return nil, errors.New("Invalid answer encoding.")
	}
	if question.Multiple {
		items, ok := value.([]any)
		if !ok {
			return nil, errors.New("Choose one or more answers.")
		}
		values := make([]string, len(items))
		for i, item := range items {
			value, ok := item.(string)
			if !ok {
				return nil, errors.New("Choose one or more answers.")
			}
			values[i] = value
		}
		return values, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, errors.New("Enter a single answer.")
	}
	return text, nil
}

func questionAnswerStrings(value any) []string {
	switch value := value.(type) {
	case string:
		return []string{value}
	case []string:
		return value
	default:
		return nil
	}
}

func questionConditionsMatch(conditions []PublicQuestionCondition, effective map[string]any) bool {
	for _, condition := range conditions {
		actual, exists := effective[condition.QuestionID]
		if !exists {
			return false
		}
		wanted, err := Decode(condition.Value)
		if err != nil {
			return false
		}
		matches := questionValuesEqual(actual, wanted)
		switch actual := actual.(type) {
		case []string:
			for _, value := range actual {
				matches = matches || questionValuesEqual(value, wanted)
			}
		case []any:
			for _, value := range actual {
				matches = matches || questionValuesEqual(value, wanted)
			}
		}
		if (condition.Op == "eq" && !matches) || (condition.Op != "eq" && matches) {
			return false
		}
	}
	return true
}

func questionValuesEqual(left, right any) bool {
	switch left := left.(type) {
	case string:
		right, ok := right.(string)
		return ok && left == right
	case bool:
		right, ok := right.(bool)
		return ok && left == right
	case float64, json.Number:
		a, okA := number(left)
		b, okB := number(right)
		return okA && okB && a == b
	default:
		return false
	}
}

func decodeQuestionFormAnswer(form PublicQuestionForm, encoded any, present bool) (any, bool, error) {
	if !present {
		if len(form.Default) == 0 {
			return nil, false, nil
		}
		value, err := Decode(form.Default)
		return value, true, err
	}
	decode := func(value string) (string, error) {
		if native, ok := form.OptionValues[value]; ok {
			return native, nil
		}
		return value, nil
	}
	if form.Type == "multiselect" {
		values := questionAnswerStrings(encoded)
		decoded := make([]string, 0, len(values))
		for _, value := range values {
			value, err := decode(value)
			if err != nil {
				return nil, true, err
			}
			decoded = append(decoded, value)
		}
		return decoded, true, nil
	}
	text, ok := encoded.(string)
	if !ok {
		return nil, true, errors.New("Enter a single answer.")
	}
	value, err := decode(text)
	if err != nil {
		return nil, true, err
	}
	switch form.Type {
	case "number", "integer":
		if trimQuestionSpace(value) == "" {
			return nil, true, errors.New("Enter a number.")
		}
		return questionNumber(value), true, nil
	case "boolean", "external":
		if value != "true" && value != "false" {
			return nil, true, errors.New("Choose yes or no.")
		}
		return value == "true", true, nil
	default:
		return value, true, nil
	}
}

func publicFormValueError(form PublicQuestionForm, value any, present bool, options []string, allowOther bool) string {
	if form.Type == "external" {
		if complete, ok := value.(bool); ok && complete {
			return ""
		}
		return "Confirm that this step is complete."
	}
	if !present {
		if form.Required {
			return "An answer is required."
		}
		return ""
	}
	switch form.Type {
	case "string":
		text, ok := value.(string)
		if !ok {
			return "Enter text."
		}
		length := UTF16Length(text)
		if form.Required && length == 0 {
			return "An answer is required."
		}
		if form.MinLength != nil && length < *form.MinLength {
			return fmt.Sprintf("Enter at least %d characters.", *form.MinLength)
		}
		if form.MaxLength != nil && length > *form.MaxLength {
			return fmt.Sprintf("Enter at most %d characters.", *form.MaxLength)
		}
		if form.Pattern != nil {
			matched, err := matchPublicQuestionPattern(*form.Pattern, text)
			if err != nil {
				return "The required answer pattern could not be evaluated."
			}
			if !matched {
				return "Answer does not match the required pattern."
			}
		}
		if options != nil && !allowOther && !questionContains(options, text) {
			return "Choose an available option."
		}
		switch form.Format {
		case "email":
			if !questionEmail(text) {
				return "Enter an email address."
			}
		case "uri":
			if !questionURI(text) {
				return "Enter a URI."
			}
		case "date":
			date, err := time.Parse("2006-01-02", text)
			if err != nil || date.Format("2006-01-02") != text {
				return "Enter a valid date."
			}
		case "date-time":
			if !questionDateTime(text) {
				return "Enter a valid date and time."
			}
		}
	case "number", "integer":
		n, ok := number(value)
		if !ok {
			return "Enter a finite number."
		}
		if form.Type == "integer" && math.Trunc(n) != n {
			return "Enter an integer."
		}
		if form.Minimum != nil && n < *form.Minimum {
			return fmt.Sprintf("Enter a number of at least %s.", strconv.FormatFloat(*form.Minimum, 'f', -1, 64))
		}
		if form.Maximum != nil && n > *form.Maximum {
			return fmt.Sprintf("Enter a number of at most %s.", strconv.FormatFloat(*form.Maximum, 'f', -1, 64))
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return "Choose yes or no."
		}
	case "multiselect":
		values, ok := questionStringArray(value)
		if !ok {
			return "Choose one or more answers."
		}
		if form.Required && len(values) == 0 {
			return "An answer is required."
		}
		if form.MinItems != nil && len(values) < *form.MinItems {
			return fmt.Sprintf("Choose at least %d answers.", *form.MinItems)
		}
		if form.MaxItems != nil && len(values) > *form.MaxItems {
			return fmt.Sprintf("Choose at most %d answers.", *form.MaxItems)
		}
		seen := make(map[string]bool)
		for _, value := range values {
			if seen[value] {
				return "Answers must not contain duplicates."
			}
			seen[value] = true
		}
		for _, value := range values {
			if !allowOther && !questionContains(options, value) {
				return "Choose available options."
			}
		}
	}
	return ""
}

func questionStringArray(value any) ([]string, bool) {
	if values, ok := value.([]string); ok {
		return values, true
	}
	values, ok := value.([]any)
	if !ok {
		return nil, false
	}
	result := make([]string, len(values))
	for i, value := range values {
		text, ok := value.(string)
		if !ok {
			return nil, false
		}
		result[i] = text
	}
	return result, true
}

func questionContains(options []string, value string) bool {
	for _, option := range options {
		if option == value {
			return true
		}
	}
	return false
}

func questionSpace(r rune) bool {
	return r == '\t' || r == '\v' || r == '\f' || r == '\n' || r == '\r' ||
		r == '\u2028' || r == '\u2029' || r == '\ufeff' || unicode.Is(unicode.Zs, r)
}

func trimQuestionSpace(value string) string { return strings.TrimFunc(value, questionSpace) }

var questionDecimalPattern = regexp.MustCompile(`^[+-]?(?:(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[Ee][+-]?[0-9]+)?|Infinity)$`)

func questionNumber(value string) float64 {
	value = trimQuestionSpace(value)
	if len(value) > 2 && value[0] == '0' {
		base := 0
		switch value[1] {
		case 'x', 'X':
			base = 16
		case 'o', 'O':
			base = 8
		case 'b', 'B':
			base = 2
		}
		if base != 0 {
			digits := value[2:]
			for _, digit := range digits {
				if digit < '0' || (digit > '9' && !(base == 16 && ((digit >= 'a' && digit <= 'f') || (digit >= 'A' && digit <= 'F')))) {
					return math.NaN()
				}
			}
			n, ok := new(big.Int).SetString(digits, base)
			if !ok {
				return math.NaN()
			}
			number, _ := new(big.Float).SetInt(n).Float64()
			return number
		}
	}
	if !questionDecimalPattern.MatchString(value) {
		return math.NaN()
	}
	n, err := strconv.ParseFloat(value, 64)
	if err != nil && !math.IsInf(n, 0) {
		return math.NaN()
	}
	return n
}

// Form patterns are ECMAScript patterns without the Unicode flag. Convert
// astral literals and input to UTF-16 code units so . and quantifiers retain
// their original behavior while regexp2 supplies lookarounds/backreferences.
func compilePublicQuestionPattern(pattern string) (*regexp2.Regexp, error) {
	var expression strings.Builder
	escaped, inClass := false, false
	for _, r := range pattern {
		if r > 0xffff {
			high, low := utf16.EncodeRune(r)
			if escaped {
				fmt.Fprintf(&expression, `u%04X\u%04X`, high, low)
			} else {
				fmt.Fprintf(&expression, `\u%04X\u%04X`, high, low)
			}
		} else if r == '$' && !escaped && !inClass {
			// regexp2 otherwise permits a final newline before $, unlike an
			// ECMAScript pattern without the multiline flag.
			expression.WriteString(`(?![\s\S])`)
		} else {
			expression.WriteRune(r)
		}
		if !escaped {
			if r == '[' {
				inClass = true
			} else if r == ']' {
				inClass = false
			}
		}
		if r == '\\' && !escaped {
			escaped = true
		} else {
			escaped = false
		}
	}
	re, err := regexp2.Compile(expression.String(), regexp2.ECMAScript)
	if err != nil {
		return nil, err
	}
	re.MatchTimeout = 100 * time.Millisecond
	return re, nil
}

func ValidatePublicQuestionPattern(pattern string) error {
	_, err := compilePublicQuestionPattern(pattern)
	return err
}

func matchPublicQuestionPattern(pattern, text string) (bool, error) {
	re, err := compilePublicQuestionPattern(pattern)
	if err != nil {
		return false, err
	}
	units := utf16.Encode([]rune(text))
	runes := make([]rune, len(units))
	for i, unit := range units {
		runes[i] = rune(unit)
	}
	return re.MatchRunes(runes)
}

func questionEmail(text string) bool {
	parts := strings.Split(text, "@")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	for _, r := range text {
		if questionSpace(r) {
			return false
		}
	}
	// The existing form contract intentionally uses a simple shape check,
	// without imposing mailbox/DNS validation or rejecting internal dots.
	domain := parts[1]
	return len(domain) >= 3 && strings.Contains(domain[1:len(domain)-1], ".")
}

func questionURI(text string) bool {
	// URL.canParse uses WHATWG parsing, including special-scheme repair and
	// nonfatal percent-encoding validation errors. RFC-only parsers differ.
	_, _, err := ParseAbsoluteURL(text)
	return err == nil
}

// ParseAbsoluteURL provides the URL constructor's no-base WHATWG semantics for
// both native forms and public input codecs. scheme excludes the trailing colon;
// normalized retains the fragment, query, and credentials just like URL.href.
func ParseAbsoluteURL(text string) (scheme, normalized string, err error) {
	parsed, err := whatwgurl.Parse(text)
	if err != nil {
		return "", "", err
	}
	return parsed.Scheme(), parsed.Href(false), nil
}

func questionDateTime(value string) bool {
	original := value
	value = trimQuestionSpace(value)
	if valid, recognized := questionISODateTime(value); recognized {
		if original != value && strings.ContainsAny(value, "Tt") {
			return false
		}
		return valid
	}
	for _, layout := range []string{
		time.RFC3339Nano, "2006-01-02T15:04Z07:00", "2006-01-02T15:04:05.999999999",
		"2006-01-02T15:04", "2006-01-02 15:04:05.999999999Z07:00", "2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04", "2006-01-02", "2006-01", "2006", time.RFC1123, time.RFC1123Z,
		time.RFC822, time.RFC822Z, time.RFC850, time.ANSIC, time.UnixDate, time.RubyDate,
		"Jan 2, 2006", "January 2, 2006", "Jan 2 2006", "January 2 2006", "1/2/2006", "2006/1/2",
	} {
		if _, err := time.Parse(layout, value); err == nil {
			return true
		}
	}
	// Legacy numeric date strings are accepted by the prior native form's
	// JavaScript Date parser. 13..31 are neither a month nor a two-digit year.
	if questionUnsignedIntegerPattern.MatchString(value) {
		n, err := strconv.ParseInt(value, 10, 32)
		if err != nil || n > 275760 || (n >= 13 && n <= 31 && len(value) < 4) {
			return false
		}
		if len(value) < 4 && n < 100 {
			return true
		}
		ms := time.Date(int(n), time.January, 1, 0, 0, 0, 0, time.Local).UnixMilli()
		return ms >= -8_640_000_000_000_000 && ms <= 8_640_000_000_000_000
	}
	return false
}

var questionUnsignedIntegerPattern = regexp.MustCompile(`^[0-9]+$`)
var questionISODateTimePattern = regexp.MustCompile(`(?i)^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?$`)

// ECMAScript's standardized date-time grammar permits signed six-digit years,
// missing date fields, midnight written as 24:00, and dates whose day rolls into
// the following month. Date forms without a time are UTC; bare times use the
// local zone. TimeClip rejects dates outside +/-100,000,000 days from epoch.
func questionISODateTime(value string) (valid, recognized bool) {
	parts := questionISODateTimePattern.FindStringSubmatch(value)
	if parts == nil {
		return false, false
	}
	parse := func(value string, fallback int) int {
		if value == "" {
			return fallback
		}
		n, _ := strconv.Atoi(value)
		return n
	}
	year, month, day := parse(parts[1], 0), parse(parts[2], 1), parse(parts[3], 1)
	hour, minute, second := parse(parts[4], 0), parse(parts[5], 0), parse(parts[6], 0)
	if parts[1] == "-000000" || month < 1 || month > 12 || day < 1 || day > 31 ||
		hour > 24 || minute > 59 || second > 59 {
		return false, true
	}
	fraction := parts[7]
	if hour == 24 && (minute != 0 || second != 0 || strings.Trim(fraction, "0") != "") {
		return false, true
	}
	if len(fraction) > 3 {
		fraction = fraction[:3]
	}
	for len(fraction) < 3 {
		fraction += "0"
	}
	millisecond := parse(fraction, 0)
	zone := time.UTC
	if parts[4] != "" && parts[8] == "" {
		zone = time.Local
	}
	if offset := parts[8]; len(offset) > 1 {
		digits := strings.ReplaceAll(offset[1:], ":", "")
		hours, minutes := parse(digits[:2], 0), parse(digits[2:], 0)
		if hours > 23 || minutes > 59 {
			return false, true
		}
		seconds := (hours*60 + minutes) * 60
		if offset[0] == '-' {
			seconds = -seconds
		}
		zone = time.FixedZone("", seconds)
	}
	instant := time.Date(year, time.Month(month), day, hour, minute, second, millisecond*int(time.Millisecond), zone)
	ms := instant.UnixMilli()
	return ms >= -8_640_000_000_000_000 && ms <= 8_640_000_000_000_000, true
}
