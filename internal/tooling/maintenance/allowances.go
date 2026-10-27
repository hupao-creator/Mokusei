package maintenance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type AllowanceOptions struct {
	Repository string
	Ref        string
	Output     string
	// Both local inputs are required together and require a pinned SHA. They
	// support reproducible review without a network request or source execution.
	CodePath   string
	DocsPath   string
	VerifiedAt string
	HTTP       *http.Client
}
type AllowanceResult struct {
	Output   string `json:"output"`
	Revision string `json:"revision"`
	Models   int    `json:"models"`
}
type MonthlyAllowance struct {
	Go     float64 `json:"go"`
	GoPlus float64 `json:"goPlus"`
}
type ModelAllowance struct {
	ID              string            `json:"id"`
	MonthlyUSD      *MonthlyAllowance `json:"monthlyUsd"`
	LimitedTimeFree bool              `json:"limitedTimeFree,omitempty"`
}
type AllowanceSnapshot struct {
	Source     string           `json:"source"`
	DocsSource string           `json:"docsSource"`
	VerifiedAt string           `json:"verifiedAt"`
	Models     []ModelAllowance `json:"models"`
}

var allowanceRevision = regexp.MustCompile(`^[a-f0-9]{40}$`)
var allowanceModelID = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]+$`)

func ExtractAllowances(code, docs, revision, verifiedAt string) (AllowanceSnapshot, error) {
	if !allowanceRevision.MatchString(revision) {
		return AllowanceSnapshot{}, errors.New("invalid official revision")
	}
	if parsed, err := time.Parse("2006-01-02", verifiedAt); err != nil || parsed.Format("2006-01-02") != verifiedAt {
		return AllowanceSnapshot{}, errors.New("verified-at must be YYYY-MM-DD")
	}
	declarations, err := allowanceDeclarations(code)
	if err != nil {
		return AllowanceSnapshot{}, err
	}
	rows, ok := declarations["goModels"].([]any)
	plus, plusOK := declarations["plusLimits"].(map[string]any)
	if !ok || len(rows) < 10 || len(rows) > 128 || !plusOK {
		return AllowanceSnapshot{}, errors.New("unrecognized allowance schema")
	}
	section := strings.Index(docs, "## Endpoints")
	if section < 0 {
		return AllowanceSnapshot{}, errors.New("official endpoint table missing")
	}
	idsByName := map[string]string{}
	for _, line := range strings.Split(docs[section:], "\n") {
		parts := strings.Split(line, "|")
		if len(parts) != 6 {
			continue
		}
		cells := make([]string, 4)
		for i := range cells {
			cells[i] = strings.TrimSpace(parts[i+1])
		}
		if !strings.Contains(cells[2], "https://opencode.ai/zen/go/v1/") {
			continue
		}
		id := strings.ReplaceAll(cells[1], "`", "")
		if allowanceModelID.MatchString(id) {
			idsByName[cells[0]] = id
		}
	}
	if len(idsByName) < 10 {
		return AllowanceSnapshot{}, errors.New("unrecognized official endpoint table")
	}
	models := map[string]ModelAllowance{}
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			return AllowanceSnapshot{}, errors.New("invalid model row")
		}
		id, ok := row["id"].(string)
		if !ok || !allowanceModelID.MatchString(id) {
			return AllowanceSnapshot{}, errors.New("invalid model ID")
		}
		allowance, hasGo := row["allowance"].(float64)
		limits, hasLimits := plus[id].([]any)
		var goPlus float64
		hasPlus := false
		if hasLimits && len(limits) > 1 {
			goPlus, hasPlus = limits[1].(float64)
		}
		limitedTime, _ := row["limitedTime"].(bool)
		free := hasGo && hasPlus && math.IsInf(allowance, 1) && math.IsInf(goPlus, 1) && limitedTime
		if !free && (!hasGo || !hasPlus || math.IsNaN(allowance) || math.IsInf(allowance, 0) || math.IsNaN(goPlus) || math.IsInf(goPlus, 0) || allowance <= 0 || goPlus <= 0) {
			return AllowanceSnapshot{}, fmt.Errorf("incomplete allowances: %s", id)
		}
		ids := []string{id}
		if name, ok := row["name"].(string); ok {
			if alias := idsByName[name]; alias != "" && alias != id {
				ids = append(ids, alias)
			}
		}
		for _, modelID := range ids {
			if _, exists := models[modelID]; exists {
				return AllowanceSnapshot{}, fmt.Errorf("duplicate allowance: %s", modelID)
			}
			model := ModelAllowance{ID: modelID, LimitedTimeFree: free}
			if !free {
				model.MonthlyUSD = &MonthlyAllowance{Go: allowance, GoPlus: goPlus}
			}
			models[modelID] = model
		}
	}
	root := "https://raw.githubusercontent.com/anomalyco/opencode/" + revision
	snapshot := AllowanceSnapshot{Source: root + "/packages/console/app/src/component/go-models.ts", DocsSource: root + "/packages/web/src/content/docs/go.mdx", VerifiedAt: verifiedAt, Models: make([]ModelAllowance, 0, len(models))}
	for _, model := range models {
		snapshot.Models = append(snapshot.Models, model)
	}
	sort.Slice(snapshot.Models, func(i, j int) bool { return snapshot.Models[i].ID < snapshot.Models[j].ID })
	return snapshot, nil
}

// UpdateAllowances resolves dev to an immutable official SHA before fetching the
// two data sources. Downloaded TypeScript is parsed as literals, never executed.
func UpdateAllowances(ctx context.Context, options AllowanceOptions) (AllowanceResult, error) {
	ref := options.Ref
	if ref == "" {
		ref = "dev"
	}
	if ref != "dev" && !allowanceRevision.MatchString(ref) {
		return AllowanceResult{}, errors.New("expected dev or an official 40-character lowercase commit SHA")
	}
	if (options.CodePath == "") != (options.DocsPath == "") {
		return AllowanceResult{}, errors.New("--code and --docs must be supplied together")
	}
	if options.CodePath != "" && ref == "dev" {
		return AllowanceResult{}, errors.New("local source fixtures require a pinned commit SHA")
	}
	client := options.HTTP
	if client == nil {
		client = &http.Client{}
	}
	copy := *client
	copy.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("official source redirects are disabled")
	}
	client = &copy
	read := func(url string) ([]byte, error) {
		bounded, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		request, err := http.NewRequestWithContext(bounded, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Accept", "application/vnd.github+json")
		request.Header.Set("User-Agent", "Mokusei-billing-catalog")
		response, err := client.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return nil, fmt.Errorf("official source returned HTTP %d", response.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 8*1024*1024+1))
		if err != nil {
			return nil, err
		}
		if len(body) > 8*1024*1024 {
			return nil, errors.New("official source exceeds 8 MiB")
		}
		return body, bounded.Err()
	}
	revision := ref
	if ref == "dev" {
		body, err := read("https://api.github.com/repos/anomalyco/opencode/commits/dev")
		if err != nil {
			return AllowanceResult{}, err
		}
		var value struct {
			SHA string `json:"sha"`
		}
		if json.Unmarshal(body, &value) != nil || !allowanceRevision.MatchString(value.SHA) {
			return AllowanceResult{}, errors.New("invalid official revision")
		}
		revision = value.SHA
	}
	var code, docs []byte
	if options.CodePath != "" {
		var err error
		code, err = maintenanceRead(options.CodePath, 8*1024*1024)
		if err != nil {
			return AllowanceResult{}, err
		}
		docs, err = maintenanceRead(options.DocsPath, 8*1024*1024)
		if err != nil {
			return AllowanceResult{}, err
		}
	} else {
		root := "https://raw.githubusercontent.com/anomalyco/opencode/" + revision
		paths := []string{root + "/packages/console/app/src/component/go-models.ts", root + "/packages/web/src/content/docs/go.mdx"}
		type sourceResult struct {
			index int
			body  []byte
			err   error
		}
		results := make(chan sourceResult, 2)
		for i, path := range paths {
			go func() { body, err := read(path); results <- sourceResult{i, body, err} }()
		}
		sources := make([][]byte, 2)
		var failures []error
		for range paths {
			result := <-results
			sources[result.index] = result.body
			if result.err != nil {
				failures = append(failures, result.err)
			}
		}
		if err := errors.Join(failures...); err != nil {
			return AllowanceResult{}, err
		}
		code, docs = sources[0], sources[1]
	}
	date := options.VerifiedAt
	if date == "" {
		date = time.Now().UTC().Format("2006-01-02")
	}
	snapshot, err := ExtractAllowances(string(code), string(docs), revision, date)
	if err != nil {
		return AllowanceResult{}, err
	}
	output := options.Output
	if output == "" {
		if options.Repository == "" {
			return AllowanceResult{}, errors.New("repository required for default allowance output")
		}
		output = filepath.Join(options.Repository, "internal", "plugins", "harness", "opencode", "accounttelemetry", "assets", "opencode-go-allowances.json")
	}
	output, err = filepath.Abs(output)
	if err != nil {
		return AllowanceResult{}, err
	}
	body, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return AllowanceResult{}, err
	}
	if err = ctx.Err(); err != nil {
		return AllowanceResult{}, err
	}
	if err = maintenanceAtomicWrite(output, append(body, '\n')); err != nil {
		return AllowanceResult{}, err
	}
	return AllowanceResult{Output: output, Revision: revision, Models: len(snapshot.Models)}, nil
}
