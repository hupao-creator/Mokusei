package git

import "testing"

func TestNumstatFramingAndBounds(t *testing.T) {
	for _, c := range []struct {
		name, input string
		a, d        int
		bad         bool
	}{
		{"empty", "", 0, 0, false}, {"unicode and tabs", "3\t2\t中文\tfile\nname\x00", 3, 2, false},
		{"rename", "1\t4\t\x00old\x00new\x00", 1, 4, false}, {"binary", "-\t-\timage\x00", 0, 0, false},
		{"truncated", "1\t2\tfile", 0, 0, true}, {"partial rename", "1\t2\t\x00old\x00", 0, 0, true},
		{"negative", "-1\t2\tfile\x00", 0, 0, true}, {"invalid UTF-8", "1\t2\t\xff\x00", 0, 0, true},
		{"overflow", "9007199254740991\t0\ta\x001\t0\tb\x00", 0, 0, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			a, d, e := parseNumstat(c.input)
			if (e != nil) != c.bad {
				t.Fatalf("error=%v", e)
			}
			if !c.bad && (a != c.a || d != c.d) {
				t.Fatalf("got %d/%d", a, d)
			}
		})
	}
}
