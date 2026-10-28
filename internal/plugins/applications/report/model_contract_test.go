package report

import (
	"encoding/json"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"strings"
	"testing"
)

func TestReportPersistenceContract(t *testing.T) {
	valid := Data{Scope: "inbox", Title: "报告", HTML: "<p>正文</p>", ContentRevision: "v1", RelatedExecutions: []model.ExecutionRef{}, TagSources: map[string]TagSource{}}
	cases := []struct {
		name string
		edit func(map[string]any)
	}{
		{"missing scope", func(v map[string]any) { delete(v, "scope") }},
		{"null scope", func(v map[string]any) { v["scope"] = nil }},
		{"relative scope", func(v map[string]any) { v["scope"] = "project" }},
		{"unclean scope", func(v map[string]any) { v["scope"] = "/a/../b" }},
		{"unknown field", func(v map[string]any) { v["extra"] = true }},
		{"null references", func(v map[string]any) { v["relatedExecutions"] = nil }},
		{"orphan tags", func(v map[string]any) { v["tagSources"] = map[string]any{"orphan": map[string]any{}} }},
		{"blank title", func(v map[string]any) { v["title"] = "  " }},
	}
	raw, _ := json.Marshal(valid)
	if _, err := ParseData(raw); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var v map[string]any
			json.Unmarshal(raw, &v)
			c.edit(v)
			b, _ := json.Marshal(v)
			if _, err := ParseData(b); err == nil {
				t.Fatalf("accepted invalid report: %s", b)
			}
		})
	}
}
func TestReportSearchExcludesHiddenHTML(t *testing.T) {
	text := HTMLSearchText(`<html><head><title>SECRET_HEAD</title></head><body><p>可见 &amp; 内容</p><script>SECRET_SCRIPT</script><style>SECRET_STYLE</style><template>SECRET_TEMPLATE</template><p>第二段</p></body></html>`)
	if strings.Contains(text, "SECRET") || !strings.Contains(text, "可见 & 内容") || !strings.Contains(text, "第二段") {
		t.Fatalf("search projection: %q", text)
	}
}

func TestReaderTextHTMLSemantics(t *testing.T) {
	cases := []struct{ name, source, want string }{
		{"named entities", "<p>α control | &alpha; | &le; | &rarr; | &times; | &amp;</p>", "α control | α | ≤ | → | × | &"},
		{"case sensitive entities", "<p>&Alpha; &alpha; &NotEqualTilde; &amp;lt;</p>", "Α α ≂̸ &lt;"},
		{"inline boundaries", "<p>KEEP<span>WORD<strong>JOIN</strong></span>_52EE</p>", "KEEPWORDJOIN_52EE"},
		{"comments and blocks", "<p>A<!-- hidden -->B<br>C</p><p>D</p>", "AB C D"},
		{"nested templates", "<p>BEFORE</p><template><template>INNER</template>OUTER</template><p>AFTER</p>", "BEFORE AFTER"},
		{"template raw text", "<template><script>'</template>'</script>HIDDEN</template><p>VISIBLE</p>", "VISIBLE"},
		{"rcdata", "<textarea>VISIBLE_RC_<b>TAG</b>_KEEP &amp;</textarea>", "VISIBLE_RC_<b>TAG</b>_KEEP &"},
		{"self closing svg", "<p>A<svg/>B</p>", "AB"},
		{"self closing template", "<template/>HIDDEN</template><p>VISIBLE</p>", "VISIBLE"},
		{"misplaced head text follows HTML tree repair", "<html><head>VISIBLE</head><body><p>AFTER</p></body></html>", "VISIBLE AFTER"},
		{"unclosed rcdata", "<textarea>A<b>B", "A<b>B"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := HTMLSearchText(c.source); got != c.want {
				t.Errorf("search = %q, want %q", got, c.want)
			}
			if got := HTMLPreview(c.source, ""); got != c.want {
				t.Errorf("preview = %q, want %q", got, c.want)
			}
		})
	}
}

func TestReaderTextForeignContent(t *testing.T) {
	cases := []struct{ name, content string }{
		{"svg style", "<svg><style/></svg>"},
		{"svg script", "<svg><script/></svg>"},
		{"svg title", "<svg><title/></svg>"},
		{"svg nested", "<svg><g><title/><script/><style/></g></svg>"},
		{"svg cdata", "<svg><![CDATA[</svg><p>HIDDEN</p>]]></svg>"},
		{"svg integration point", "<svg><foreignObject><textarea>&lt;/svg&gt;<b>HIDDEN</b></textarea></foreignObject></svg>"},
		{"mathml self closing", "<math><style/><title/><script/></math>"},
		{"ignored head", "<template><head><title>HIDDEN</title></template>"},
	}
	for _, c := range cases {
		for _, wrapped := range []bool{false, true} {
			name, content := c.name, c.content
			if wrapped {
				name += " in template"
				content = "<template>" + content + "<template>HIDDEN</template></template>"
			}
			t.Run(name, func(t *testing.T) {
				source := "<p>BEFORE</p>" + content + "<p>AFTER</p>"
				for projection, got := range map[string]string{"preview": HTMLPreview(source, ""), "search": HTMLSearchText(source)} {
					if got != "BEFORE AFTER" {
						t.Errorf("%s = %q", projection, got)
					}
				}
			})
		}
	}
}
