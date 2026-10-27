package codex

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"
)

type Map = map[string]any

func str(v any) string { s, _ := v.(string); return s }
func obj(v any) Map {
	if m, ok := v.(map[string]any); ok && m != nil {
		return m
	}
	return Map{}
}
func arr(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case []Map:
		r := make([]any, len(x))
		for i := range x {
			r[i] = x[i]
		}
		return r
	}
	return []any{}
}
func num(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}
func clone(m Map) Map {
	b, e := json.Marshal(m)
	if e != nil {
		return Map{}
	}
	r := Map{}
	_ = json.Unmarshal(b, &r)
	return r
}
func uid() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		return fmt.Sprintf("codex-%d", time.Now().UnixNano())
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
func now() int64 { return time.Now().UnixMilli() }
func jsonText(v any) string {
	b, e := json.Marshal(v)
	if e != nil {
		return ""
	}
	return string(b)
}
func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	i := len(s) - n
	for i < len(s) && s[i]&0xc0 == 0x80 {
		i++
	}
	return "…\n" + s[i:]
}
func first(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}
func present(m Map, keys ...string) Map {
	r := Map{}
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			r[k] = v
		}
	}
	return r
}
