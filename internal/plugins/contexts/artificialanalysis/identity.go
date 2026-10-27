package artificialanalysis

import (
	"regexp"
	"sort"
	"strings"
)

type Match struct {
	Status  string
	Release *Release
}
type forms struct{ normalized, spelling, family, versions string }

var contextSuffix = regexp.MustCompile(`(?i)\[1m\]$`)
var commercialSuffix = regexp.MustCompile(`(?i)(?:[-\s]free|\s*\((?:free|new)\))$`)
var identitySplit = regexp.MustCompile(`[^a-z0-9]+`)
var identityTokens = regexp.MustCompile(`[a-z]+|\d+`)
var releaseAliases = map[string]string{"muse-spark-1-2-contributor": "muse-spark-1-2", "muse-spark-1-3-contributor": "muse-spark-1-3", "qwen3-8-flash": "qwen3-8-flash-next", "nemotron-3-ultra": "nemotron-3-ultra-550b-a55b"}

func identityForms(value string) forms {
	name := strings.Trim(identitySplit.ReplaceAllString(strings.ToLower(commercialSuffix.ReplaceAllString(contextSuffix.ReplaceAllString(value, ""), "")), "-"), "-")
	if alias, ok := releaseAliases[name]; ok {
		name = alias
	}
	tokens := identityTokens.FindAllString(name, -1)
	words, numbers := []string{}, []string{}
	for _, token := range tokens {
		if token[0] >= '0' && token[0] <= '9' {
			numbers = append(numbers, token)
		} else {
			words = append(words, token)
		}
	}
	sort.Strings(words)
	return forms{name, strings.Join(tokens, "-"), strings.Join(words, "-"), strings.Join(numbers, "-")}
}
func score(a, b forms) int {
	if a.normalized == b.normalized {
		return 3
	}
	if a.spelling == b.spelling {
		return 2
	}
	if a.family == b.family && a.versions == b.versions {
		return 1
	}
	return 0
}
func IdentityNames(identity Identity) []string {
	result := []string{}
	seen := map[string]bool{}
	for _, name := range append(append([]string{identity.Selector}, identity.Aliases...), identity.DisplayName) {
		if name != "" && !seen[name] {
			seen[name] = true
			result = append(result, name)
		}
	}
	return result
}
func MatchNames(names []string, releases []Release) Match {
	converted := []forms{}
	for _, name := range names {
		value := identityForms(name)
		if value.normalized != "" {
			converted = append(converted, value)
		}
	}
	best, count := 0, 0
	var matched *Release
	for index := range releases {
		release := &releases[index]
		candidates := []forms{}
		for _, name := range append([]string{release.Slug, release.Name}, release.Aliases...) {
			value := identityForms(name)
			if value.normalized != "" {
				candidates = append(candidates, value)
			}
		}
		contradictory := false
		for _, name := range converted {
			exact, conflict := false, false
			for _, candidate := range candidates {
				if score(name, candidate) > 0 {
					exact = true
				}
				if strings.HasPrefix(name.spelling, candidate.spelling+"-") || (name.family == candidate.family && name.versions != "" && name.versions != candidate.versions) {
					conflict = true
				}
			}
			if !exact && conflict {
				contradictory = true
				break
			}
		}
		if contradictory {
			continue
		}
		rank := 0
		for _, name := range converted {
			for _, candidate := range candidates {
				rank = max(rank, score(name, candidate))
			}
		}
		if rank > best {
			best = rank
			count = 1
			matched = release
		} else if rank > 0 && rank == best {
			count++
		}
	}
	if best == 0 {
		return Match{Status: "unmatched"}
	}
	if count != 1 {
		return Match{Status: "ambiguous"}
	}
	return Match{Status: "matched", Release: matched}
}
func matchSlug(slug string, releases []Release) Match {
	var found *Release
	for i := range releases {
		if releases[i].Slug == slug {
			if found != nil {
				return Match{Status: "ambiguous"}
			}
			found = &releases[i]
		}
	}
	if found == nil {
		return Match{Status: "unmatched"}
	}
	return Match{Status: "matched", Release: found}
}
func MatchRelease(snapshot Snapshot, identity Identity) Match {
	if snapshot.Availability != "available" || identity.SuppressFallback {
		return Match{Status: "unmatched"}
	}
	releases := []Release{}
	for _, release := range snapshot.Releases {
		if len(release.Evaluations) > 0 {
			releases = append(releases, release)
		}
	}
	if identity.EvaluationRelease != nil {
		return matchSlug(*identity.EvaluationRelease, releases)
	}
	return MatchNames(IdentityNames(identity), releases)
}
