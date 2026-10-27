package opencode

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsolatedConfigurationUsesChildEnvironmentHome(t *testing.T) {
	ambientHome := t.TempDir()
	childHome := t.TempDir()
	t.Setenv("HOME", ambientHome)
	for _, fixture := range []struct {
		home  string
		value string
	}{{ambientHome, "ambient"}, {childHome, "child"}} {
		configDir := filepath.Join(fixture.home, ".config", "opencode")
		if err := os.MkdirAll(configDir, 0700); err != nil {
			t.Fatal(err)
		}
		config := Object{
			"model": fixture.value + "/model",
			"providers": Object{"fixture": Object{"settings": Object{
				"apiKey": "{file:~/fixture-key}",
			}}},
			"permissions": []any{
				Object{"action": "read", "resource": "~/documents/*", "effect": "allow"},
				Object{"action": "edit", "resource": "$HOME/documents/*", "effect": "deny"},
			},
			"agents": Object{"review": Object{"permissions": []any{
				Object{"action": "external_directory", "resource": "~", "effect": "deny"},
			}}},
		}
		body, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(configDir, "opencode.json"), body, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(fixture.home, "fixture-key"), []byte(fixture.value+"-synthetic-key\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, nativeOverride := range []bool{false, true} {
		t.Run(map[bool]string{false: "child-home", true: "native-permission-home"}[nativeOverride], func(t *testing.T) {
			env := map[string]string{"HOME": childHome, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DB": ":memory:"}
			permissionHome := childHome
			if nativeOverride {
				permissionHome = t.TempDir()
				env["OPENCODE_TEST_HOME"] = permissionHome
			}
			values, cleanup, err := PrepareEnvironment(Options{CWD: childHome, Environment: env, IsolateConfig: true}, filepath.Join(childHome, "bridge"))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if err := cleanup(); err != nil {
					t.Error(err)
				}
			})
			var configuration Object
			for _, entry := range values {
				if content, ok := strings.CutPrefix(entry, "OPENCODE_CONFIG_CONTENT="); ok {
					if err := json.Unmarshal([]byte(content), &configuration); err != nil {
						t.Fatal(err)
					}
				}
			}
			if configuration["model"] != "child/model" {
				t.Fatalf("configuration came from another HOME: %v", configuration["model"])
			}
			provider := object(object(configuration["providers"])["fixture"])
			if key := object(provider["settings"])["apiKey"]; key != "child-synthetic-key" {
				t.Fatalf("file substitution came from another HOME: %v", key)
			}
			permissions := array(configuration["permissions"])
			if len(permissions) != 2 {
				t.Fatalf("unexpected native permission rules: %v", permissions)
			}
			for _, raw := range permissions {
				if resource := object(raw)["resource"]; resource != filepath.Join(permissionHome, "documents", "*") {
					t.Fatalf("native permission expanded against another HOME: %v", resource)
				}
			}
			agent := object(object(configuration["agents"])["review"])
			agentPermissions := array(agent["permissions"])
			if len(agentPermissions) != 1 || object(agentPermissions[0])["resource"] != permissionHome {
				t.Fatalf("agent permission expanded against another HOME: %v", agentPermissions)
			}
			if env["HOME"] != childHome || env["OPENCODE_CONFIG_CONTENT"] != "" {
				t.Fatal("environment preparation mutated the supplied environment")
			}
		})
	}
}
