package codex

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// This is a deliberately narrow native authority, not an override of discovery.
// The user must already have selected this file in effective native config. The
// fixed location is included in the source key before any cache lookup, including
// when the file is absent. Arbitrary paths need a dependency-aware cache contract.
type staticCatalogAuthority struct {
	path          string
	data          []byte
	configuration []byte
	ids           map[string]bool
}

func captureStaticCatalogAuthority(ctx context.Context, server *AppServer, cwd string) (*staticCatalogAuthority, error) {
	version := strings.TrimSpace(strings.TrimPrefix(server.launch.Version, "codex-cli "))
	if !server.launch.StrictConfig || version != "0.166.0" {
		return nil, errors.New("Codex Moku catalog requires audited Codex 0.166.0 with strict configuration; other versions have unverified source completeness")
	}
	response, err := server.Call(ctx, "config/read", Map{"cwd": cwd, "includeLayers": false})
	if err != nil {
		return nil, err
	}
	config, ok := csRecord(response["config"])
	if !ok {
		return nil, errors.New("Codex effective catalog configuration is missing")
	}
	if provider := csString(config["model_provider"]); provider != "" && provider != "openai" {
		return nil, errors.New("Codex Moku static catalog proof currently supports only the native OpenAI provider")
	}
	providers, _ := csRecord(config["model_providers"])
	if override, exists := providers["openai"]; exists && override != nil {
		return nil, errors.New("Codex Moku static catalog proof does not support an overridden OpenAI provider")
	}
	if !regexp.MustCompile(`/0\.166\.0(?:[\s(]|$)`).MatchString(csString(server.initialized["userAgent"])) {
		return nil, errors.New("Codex initialized client does not confirm the audited catalog version")
	}
	path := filepath.Join(ceCodexHome(ceEnvironment(server.launch.Environment)), "models.json")
	path, err = filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	configured := csString(config["model_catalog_json"])
	if strings.HasPrefix(configured, "file:") {
		uri, parseErr := url.Parse(configured)
		if parseErr != nil || uri.Scheme != "file" || uri.Host != "" || uri.User != nil || uri.RawQuery != "" || uri.Fragment != "" {
			return nil, errors.New("Codex catalog URI is not a local file")
		}
		configured = uri.Path
	}
	if configured != path {
		return nil, errors.New("Codex Moku cannot prove the default remote catalog complete; configure native model_catalog_json to the absolute CODEX_HOME/models.json path with an authoritative catalog")
	}
	policy, err := server.Call(ctx, "configRequirements/read", Map{})
	if err != nil {
		return nil, err
	}
	rawRequirements, reported := policy["requirements"]
	if !reported {
		return nil, errors.New("Codex did not report model catalog policy")
	}
	if rawRequirements != nil {
		requirements, valid := csRecord(rawRequirements)
		if !valid {
			return nil, errors.New("Codex model catalog policy is malformed")
		}
		for _, field := range []string{"model_provider", "model_providers", "model_catalog_json", "models"} {
			if requirements[field] != nil {
				return nil, errors.New("Codex Moku static catalog proof does not support managed model catalog/provider overrides")
			}
		}
	}
	// Compare the full effective configuration again after enumeration. Never
	// project this private value (which can contain provider credentials).
	configuration, err := json.Marshal(Map{"config": config, "requirements": rawRequirements})
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	data, readErr := io.ReadAll(io.LimitReader(f, 4*1024*1024+1))
	if err := errors.Join(readErr, f.Close()); err != nil {
		return nil, err
	}
	if len(data) > 4*1024*1024 {
		return nil, errors.New("Codex authoritative catalog exceeds discovery size limit")
	}
	var catalog struct {
		Models []struct {
			Slug string `json:"slug"`
		} `json:"models"`
	}
	if err := json.Unmarshal(data, &catalog); err != nil {
		return nil, errors.New("Codex authoritative catalog is malformed")
	}
	ids := map[string]bool{}
	for _, model := range catalog.Models {
		if strings.TrimSpace(model.Slug) == "" || ids[model.Slug] {
			return nil, errors.New("Codex authoritative catalog has missing or duplicate model IDs")
		}
		ids[model.Slug] = true
	}
	if len(ids) == 0 {
		return nil, errors.New("Codex authoritative catalog is empty")
	}
	return &staticCatalogAuthority{path: path, data: data, configuration: configuration, ids: ids}, nil
}

func (a *staticCatalogAuthority) verify(ctx context.Context, server *AppServer, cwd string, models []Map) (plugin.CatalogSourceEvidence, error) {
	current, err := captureStaticCatalogAuthority(ctx, server, cwd)
	if err != nil {
		return plugin.CatalogSourceEvidence{}, err
	}
	if current.path != a.path || !bytes.Equal(current.data, a.data) || !bytes.Equal(current.configuration, a.configuration) {
		return plugin.CatalogSourceEvidence{}, errors.New("Codex authoritative catalog configuration changed during enumeration")
	}
	if len(models) != len(a.ids) {
		return plugin.CatalogSourceEvidence{}, errors.New("Codex native enumeration does not cover the whole configured catalog (including auth-filtered entries)")
	}
	for _, model := range models {
		if !a.ids[csString(model["value"])] {
			return plugin.CatalogSourceEvidence{}, errors.New("Codex native enumeration differs from its configured catalog")
		}
	}
	return plugin.CatalogSourceEvidence{Complete: true, Basis: fmt.Sprintf("Codex 0.166.0 strict native explicit-config StaticModelsManager; all configured IDs enumerated; catalog SHA-256 %x", sha256.Sum256(a.data))}, nil
}
