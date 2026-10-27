package artificialanalysis

import "testing"

func TestReleaseAttributionFailsClosed(t *testing.T) {
	r := Release{Slug: "model-2", Name: "Model 2", Evaluations: []Evaluation{{Slug: "eval"}}}
	for _, c := range []struct {
		name string
		s    Snapshot
		i    Identity
		want string
	}{
		{"exact", Snapshot{Availability: "available", Releases: []Release{r}}, Identity{Selector: "model-2"}, "matched"},
		{"version conflict", Snapshot{Availability: "available", Releases: []Release{r}}, Identity{Selector: "model-3", DisplayName: "Model 2"}, "unmatched"},
		{"ambiguous", Snapshot{Availability: "available", Releases: []Release{r, r}}, Identity{Selector: "model-2"}, "ambiguous"},
		{"suppressed", Snapshot{Availability: "available", Releases: []Release{r}}, Identity{Selector: "model-2", SuppressFallback: true}, "unmatched"},
		{"unavailable", Snapshot{Availability: "unavailable", Releases: []Release{r}}, Identity{Selector: "model-2"}, "unmatched"},
		{"no evaluation", Snapshot{Availability: "available", Releases: []Release{{Slug: "model-2"}}}, Identity{Selector: "model-2"}, "unmatched"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := MatchRelease(c.s, c.i)
			if got.Status != c.want {
				t.Fatalf("got %+v want %s", got, c.want)
			}
			if c.want != "matched" && got.Release != nil {
				t.Fatal("uncertain identity exposed release")
			}
		})
	}
}
