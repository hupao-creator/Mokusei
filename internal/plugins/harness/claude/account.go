package claude

import (
	"context"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func readAccountSettings(path string) (model.Object, error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return model.Object{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot read native Claude account settings: %s", path)
	}
	parsed, err := model.DecodeObject(contents)
	if err != nil {
		return nil, fmt.Errorf("invalid native Claude account settings: %s", path)
	}
	return parsed, nil
}

func usesNativeAccount(ctx context.Context, cwd string, environment map[string]string, homeDirectory string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if homeDirectory == "" {
		homeDirectory, _ = os.UserHomeDir()
	}
	root := environment["CLAUDE_CONFIG_DIR"]
	if root == "" {
		root = filepath.Join(homeDirectory, ".claude")
	}
	settingsEnvironment := map[string]string{}
	for _, path := range []string{filepath.Join(root, "settings.json"), filepath.Join(cwd, ".claude", "settings.json"), filepath.Join(cwd, ".claude", "settings.local.json")} {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		settings, err := readAccountSettings(path)
		if err != nil {
			return false, nil
		}
		if env, ok := settings["env"].(map[string]any); ok {
			for key, value := range env {
				if text, ok := value.(string); ok {
					settingsEnvironment[key] = text
				}
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	for key, value := range environment {
		settingsEnvironment[key] = value
	}
	env := settingsEnvironment
	external := (env["ANTHROPIC_BASE_URL"] != "" && !nativeAnthropicBase(env["ANTHROPIC_BASE_URL"])) || env["ANTHROPIC_API_KEY"] != "" || env["ANTHROPIC_AUTH_TOKEN"] != "" || env["CLAUDE_CODE_USE_BEDROCK"] == "1" || env["CLAUDE_CODE_USE_VERTEX"] == "1" || env["CLAUDE_CODE_USE_FOUNDRY"] == "1"
	return !external, nil
}

func nativeAnthropicBase(value string) bool {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || !strings.EqualFold(parsed.Hostname(), "api.anthropic.com") || (parsed.Port() != "" && parsed.Port() != "443") || parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" {
		return false
	}
	return parsed.Path == "" || parsed.Path == "/" || parsed.Path == "/v1" || parsed.Path == "/v1/"
}
