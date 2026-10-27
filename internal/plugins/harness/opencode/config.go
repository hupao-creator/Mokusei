package opencode

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"gopkg.in/yaml.v3"
)

// mergeOpenCodeConfig merges objects recursively; arrays and scalar values replace
// their predecessors. It never modifies either argument.
func mergeOpenCodeConfig(previous, overlay map[string]any) map[string]any {
	result := copyConfigObject(previous)
	for key, after := range overlay {
		before, beforeOK := configObject(previous[key])
		next, nextOK := configObject(after)
		if beforeOK && nextOK {
			result[key] = mergeOpenCodeConfig(before, next)
		} else {
			result[key] = after
		}
	}
	return result
}

// readNativeDataConfig follows native discovery order while admitting only model,
// agent and permission data. Plugins, MCP servers and ambient instructions must
// never enter an isolated Mokusei session through native configuration.
func readNativeDataConfig(environment map[string]string, cwd string) (map[string]any, error) {
	home, err := environmentHome(environment)
	if err != nil {
		return nil, errors.New("Cannot resolve native OpenCode configuration paths")
	}
	configDirectory := environment["OPENCODE_CONFIG_DIR"]
	if configDirectory == "" {
		configHome := environment["XDG_CONFIG_HOME"]
		if configHome == "" {
			configHome = filepath.Join(home, ".config")
		}
		configDirectory = filepath.Join(configHome, "opencode")
	}
	configDirectory, err = filepath.Abs(configDirectory)
	if err != nil {
		return nil, errors.New("Cannot resolve native OpenCode configuration paths")
	}
	if nativeHome := environment["OPENCODE_TEST_HOME"]; nativeHome != "" {
		home = nativeHome
	}
	globalRoots := make(map[string]bool)
	for _, path := range []string{configDirectory, filepath.Join(home, ".claude"), filepath.Join(home, ".agents")} {
		canonical, err := canonicalPath(path)
		if err != nil {
			return nil, err
		}
		globalRoots[canonical] = true
	}
	globalFiles := make(map[string]bool)
	for _, name := range []string{"opencode.json", "opencode.jsonc"} {
		canonical, err := canonicalPath(filepath.Join(configDirectory, name))
		if err != nil {
			return nil, err
		}
		globalFiles[canonical] = true
	}
	canonicalCwd, err := canonicalPath(cwd)
	if err != nil {
		return nil, err
	}
	canonicalConfig, err := canonicalPath(configDirectory)
	if err != nil {
		return nil, err
	}
	disableProject, exists := environment["OPENCODE_CONFIG_PROJECT_DISABLE"]
	if !exists {
		disableProject = environment["OPENCODE_DISABLE_PROJECT_CONFIG"]
	}
	disableProject = strings.ToLower(disableProject)
	var ancestors []string
	if disableProject != "1" && disableProject != "true" && canonicalCwd != canonicalConfig {
		current, err := filepath.Abs(cwd)
		if err != nil {
			return nil, errors.New("Cannot resolve native OpenCode configuration paths")
		}
		for {
			ancestors = append(ancestors, current)
			parent := filepath.Dir(current)
			if current == parent {
				break
			}
			current = parent
		}
		for left, right := 0, len(ancestors)-1; left < right; left, right = left+1, right-1 {
			ancestors[left], ancestors[right] = ancestors[right], ancestors[left]
		}
	}
	result := make(map[string]any)
	readDocument := func(path string) error {
		text, exists, err := optionalConfigText(path)
		if err != nil || !exists {
			return err
		}
		config, err := parseConfigObject(text, "native configuration")
		if err != nil {
			return err
		}
		substituted, err := substituteConfig(safeNativeConfig(config), environment, filepath.Dir(path))
		if err != nil {
			return err
		}
		result = mergeNativeDataConfig(result, substituted.(map[string]any), environment)
		return nil
	}
	readDirectory := func(directory string) error {
		for _, name := range []string{"opencode.json", "opencode.jsonc"} {
			if err := readDocument(filepath.Join(directory, name)); err != nil {
				return err
			}
		}
		files, err := nativeAgentFiles(directory)
		if err != nil {
			return err
		}
		for _, file := range files {
			text, exists, err := optionalConfigText(file.path)
			if err != nil {
				return err
			}
			if exists {
				if config := markdownAgent(directory, file.path, file.primary, text); config != nil {
					result = mergeNativeDataConfig(result, config, environment)
				}
			}
		}
		return nil
	}
	if err := readDirectory(configDirectory); err != nil {
		return nil, err
	}
	if explicit := environment["OPENCODE_CONFIG"]; explicit != "" {
		if !filepath.IsAbs(explicit) {
			explicit = filepath.Join(cwd, explicit)
		}
		if err := readDocument(explicit); err != nil {
			return nil, err
		}
	}
	for _, directory := range ancestors {
		for _, name := range []string{"opencode.json", "opencode.jsonc"} {
			path := filepath.Join(directory, name)
			canonical, err := canonicalPath(path)
			if err != nil {
				return nil, err
			}
			if !globalFiles[canonical] {
				if err := readDocument(path); err != nil {
					return nil, err
				}
			}
		}
	}
	for _, directory := range ancestors {
		path := filepath.Join(directory, ".opencode")
		canonical, err := canonicalPath(path)
		if err != nil {
			return nil, err
		}
		if !globalRoots[canonical] {
			if err := readDirectory(path); err != nil {
				return nil, err
			}
		}
	}
	return result, nil
}

func safeNativeConfig(config map[string]any) map[string]any {
	result := make(map[string]any)
	for _, key := range []string{"providers", "provider", "model", "agents", "agent", "mode", "default_agent", "small_model", "permissions", "permission", "tools"} {
		if value, exists := config[key]; exists {
			result[key] = value
		}
	}
	return result
}

func canonicalPath(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", errors.New("Cannot resolve native OpenCode configuration paths")
	}
	canonical, err := filepath.EvalSymlinks(absolute)
	if err == nil {
		return canonical, nil
	}
	if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, syscall.ENOTDIR) {
		return "", errors.New("Cannot resolve native OpenCode configuration paths")
	}
	parent := filepath.Dir(absolute)
	if parent == absolute {
		return absolute, nil
	}
	canonical, err = canonicalPath(parent)
	if err != nil {
		return "", err
	}
	return filepath.Join(canonical, filepath.Base(absolute)), nil
}

func optionalConfigText(path string) (string, bool, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		return string(data), true, nil
	}
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.EISDIR) {
		return "", false, nil
	}
	return "", false, errors.New("Cannot read native OpenCode configuration")
}

type nativeAgentFile struct {
	path    string
	primary bool
}

func nativeAgentFiles(directory string) ([]nativeAgentFile, error) {
	var collect func(string, bool, map[string]bool) ([]string, error)
	collect = func(path string, recursive bool, parents map[string]bool) ([]string, error) {
		canonical, err := filepath.EvalSymlinks(path)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
				return nil, nil
			}
			return nil, errors.New("Cannot read native OpenCode agent directory")
		}
		if parents[canonical] {
			return nil, nil
		}
		nextParents := make(map[string]bool, len(parents)+1)
		for key := range parents {
			nextParents[key] = true
		}
		nextParents[canonical] = true
		entries, err := os.ReadDir(path)
		if err != nil {
			return nil, errors.New("Cannot read native OpenCode agent directory")
		}
		var found []string
		for _, entry := range entries {
			child := filepath.Join(path, entry.Name())
			info, err := os.Stat(child)
			if err != nil {
				// Native skips dangling or unreadable symbolic links.
				if entry.Type()&os.ModeSymlink != 0 {
					continue
				}
				return nil, errors.New("Cannot read native OpenCode agent directory")
			}
			if info.Mode().IsRegular() && strings.HasSuffix(child, ".md") {
				found = append(found, child)
			} else if recursive && info.IsDir() {
				children, err := collect(child, true, nextParents)
				if err != nil {
					return nil, err
				}
				found = append(found, children...)
			}
		}
		return found, nil
	}
	var result []nativeAgentFile
	for _, group := range []struct {
		names     []string
		recursive bool
		primary   bool
	}{{[]string{"agent", "agents"}, true, false}, {[]string{"mode", "modes"}, false, true}} {
		var files []string
		for _, name := range group.names {
			found, err := collect(filepath.Join(directory, name), group.recursive, nil)
			if err != nil {
				return nil, err
			}
			files = append(files, found...)
		}
		sort.Strings(files)
		for _, file := range files {
			result = append(result, nativeAgentFile{path: file, primary: group.primary})
		}
	}
	return result, nil
}

var frontmatterPattern = regexp.MustCompile(`(?s)^---\r?\n(.*?)\r?\n---`)
var frontmatterEntryPattern = regexp.MustCompile(`^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$`)
var legacyModelPattern = regexp.MustCompile(`^[^/#]+/[^#]+$`)
var substitutionPattern = regexp.MustCompile(`\{(env|file):([^}]+)\}`)

// Object insertion order is meaningful in native permission maps, where later
// rules can override earlier rules. Keep nested document objects ordered until
// they have been translated into explicit permission rule arrays.
type orderedConfigObject struct {
	values map[string]any
	keys   []string
}

func newOrderedConfigObject() *orderedConfigObject {
	return &orderedConfigObject{values: make(map[string]any)}
}

func (object *orderedConfigObject) set(key string, value any) {
	if _, exists := object.values[key]; !exists {
		object.keys = append(object.keys, key)
		// JavaScript enumerates array-index keys ahead of other properties.
		if index, indexed := configIndexKey(key); indexed {
			position := len(object.keys) - 1
			for position > 0 {
				previousIndex, previousIndexed := configIndexKey(object.keys[position-1])
				if previousIndexed && previousIndex < index {
					break
				}
				object.keys[position] = object.keys[position-1]
				position--
			}
			object.keys[position] = key
		}
	}
	object.values[key] = value
}

func configIndexKey(key string) (uint64, bool) {
	if key == "" || (len(key) > 1 && key[0] == '0') {
		return 0, false
	}
	index, err := strconv.ParseUint(key, 10, 32)
	return index, err == nil && index < 4294967295 && strconv.FormatUint(index, 10) == key
}

func (object *orderedConfigObject) MarshalJSON() ([]byte, error) {
	var result bytes.Buffer
	result.WriteByte('{')
	for i, key := range object.keys {
		if i != 0 {
			result.WriteByte(',')
		}
		name, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
		value, err := json.Marshal(object.values[key])
		if err != nil {
			return nil, err
		}
		result.Write(name)
		result.WriteByte(':')
		result.Write(value)
	}
	result.WriteByte('}')
	return result.Bytes(), nil
}

func decodeOrderedConfig(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	delimiter, nested := token.(json.Delim)
	if !nested {
		return token, nil
	}
	switch delimiter {
	case '{':
		object := newOrderedConfigObject()
		for decoder.More() {
			token, err := decoder.Token()
			if err != nil {
				return nil, err
			}
			key, ok := token.(string)
			if !ok {
				return nil, errors.New("Invalid JSON object key")
			}
			value, err := decodeOrderedConfig(decoder)
			if err != nil {
				return nil, err
			}
			object.set(key, value)
		}
		if end, err := decoder.Token(); err != nil || end != json.Delim('}') {
			return nil, errors.New("Invalid JSON object")
		}
		return object, nil
	case '[':
		array := make([]any, 0)
		for decoder.More() {
			value, err := decodeOrderedConfig(decoder)
			if err != nil {
				return nil, err
			}
			array = append(array, value)
		}
		if end, err := decoder.Token(); err != nil || end != json.Delim(']') {
			return nil, errors.New("Invalid JSON array")
		}
		return array, nil
	default:
		return nil, errors.New("Invalid JSON delimiter")
	}
}

func parseAgentFrontmatter(text string) (map[string]any, error) {
	var document yaml.Node
	if err := yaml.Unmarshal([]byte(text), &document); err != nil {
		return nil, err
	}
	if len(document.Content) == 0 {
		return make(map[string]any), nil
	}
	var decoded map[string]any
	if err := document.Decode(&decoded); err != nil {
		return nil, err
	}
	if decoded == nil {
		decoded = make(map[string]any)
	}
	// Normalize YAML scalar types (including timestamps) to JSON values, and
	// reject non-string object keys just as native configuration requires.
	encoded, err := json.Marshal(decoded)
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		return nil, err
	}
	result := orderedYAMLValue(decoded, document.Content[0])
	return configRecord(result), nil
}

func orderedYAMLValue(value any, node *yaml.Node) any {
	if node == nil {
		return value
	}
	if node.Kind == yaml.AliasNode {
		return orderedYAMLValue(value, node.Alias)
	}
	switch value := value.(type) {
	case map[string]any:
		keys, entries := yamlObjectEntries(node, make(map[*yaml.Node]bool))
		result := newOrderedConfigObject()
		for _, key := range keys {
			if item, exists := value[key]; exists {
				result.set(key, orderedYAMLValue(item, entries[key]))
			}
		}
		for _, key := range configKeys(value) {
			if _, exists := result.values[key]; !exists {
				result.set(key, value[key])
			}
		}
		return result
	case []any:
		result := make([]any, len(value))
		for i, item := range value {
			var child *yaml.Node
			if node.Kind == yaml.SequenceNode && i < len(node.Content) {
				child = node.Content[i]
			}
			result[i] = orderedYAMLValue(item, child)
		}
		return result
	default:
		return value
	}
}

func yamlObjectEntries(node *yaml.Node, parents map[*yaml.Node]bool) ([]string, map[string]*yaml.Node) {
	entries := make(map[string]*yaml.Node)
	if node == nil || parents[node] {
		return nil, entries
	}
	parents[node] = true
	defer delete(parents, node)
	if node.Kind == yaml.AliasNode {
		return yamlObjectEntries(node.Alias, parents)
	}
	var keys []string
	merge := func(source *yaml.Node) {
		incomingKeys, incoming := yamlObjectEntries(source, parents)
		for _, key := range incomingKeys {
			if _, exists := entries[key]; !exists {
				keys = append(keys, key)
				entries[key] = incoming[key]
			}
		}
	}
	if node.Kind != yaml.MappingNode {
		return nil, entries
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		key, value := node.Content[i], node.Content[i+1]
		if key.Tag == "!!merge" {
			if value.Kind == yaml.SequenceNode {
				for _, child := range value.Content {
					merge(child)
				}
			} else {
				merge(value)
			}
			continue
		}
		if _, exists := entries[key.Value]; !exists {
			keys = append(keys, key.Value)
		}
		entries[key.Value] = value
	}
	return keys, entries
}

func markdownAgent(directory, path string, primary bool, text string) map[string]any {
	data := make(map[string]any)
	content := text
	if bounds := frontmatterPattern.FindStringSubmatchIndex(text); bounds != nil {
		frontmatter := text[bounds[2]:bounds[3]]
		var err error
		data, err = parseAgentFrontmatter(frontmatter)
		if err != nil {
			data, err = parseAgentFrontmatter(sanitizeFrontmatter(frontmatter))
			if err != nil {
				return nil
			}
		}
		content = text[bounds[1]:]
	}
	name, err := filepath.Rel(directory, path)
	if err != nil {
		return nil
	}
	name = filepath.ToSlash(name)
	if separator := strings.IndexByte(name, '/'); separator != -1 {
		name = name[separator+1:]
	}
	name = strings.TrimSuffix(name, ".md")
	known := map[string]bool{"model": true, "request": true, "system": true, "description": true, "mode": true, "hidden": true, "color": true, "steps": true, "disabled": true, "permissions": true, "variant": true}
	legacy := false
	for key := range data {
		if !known[key] {
			legacy = true
		}
	}
	var agent map[string]any
	if legacy {
		data["prompt"] = strings.TrimSpace(content)
		agent = migrateLegacyAgent(data)
	} else {
		agent = copyConfigObject(data)
		agent["system"] = strings.TrimSpace(content)
		model, modelOK := agent["model"].(string)
		variant, variantOK := agent["variant"].(string)
		if modelOK && !strings.Contains(model, "#") && variantOK && variant != "" && !strings.Contains(variant, "#") {
			agent["model"] = model + "#" + variant
		}
		delete(agent, "variant")
	}
	if primary {
		agent["mode"] = "primary"
	}
	return map[string]any{"agents": map[string]any{name: agent}}
}

func sanitizeFrontmatter(text string) string {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	var result []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		entry := frontmatterEntryPattern.FindStringSubmatch(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") || entry == nil {
			result = append(result, line)
			continue
		}
		value := strings.TrimSpace(entry[2])
		if value == "" || value == ">" || value == "|" || strings.HasPrefix(value, `"`) || strings.HasPrefix(value, "'") || !strings.Contains(value, ":") {
			result = append(result, line)
		} else {
			result = append(result, entry[1]+": |-", "  "+value)
		}
	}
	return strings.Join(result, "\n")
}

// These are external native configuration formats, not Mokusei legacy data.
func migrateLegacyAgent(input map[string]any) map[string]any {
	known := map[string]bool{"name": true, "model": true, "variant": true, "temperature": true, "top_p": true, "prompt": true, "tools": true, "disable": true, "description": true, "mode": true, "hidden": true, "options": true, "color": true, "steps": true, "maxSteps": true, "permission": true}
	body := copyConfigObject(configRecord(input["options"]))
	for key, value := range input {
		if !known[key] {
			body[key] = value
		}
	}
	for _, key := range []string{"temperature", "top_p"} {
		if value, exists := input[key]; exists {
			body[key] = value
		}
	}
	permission := newOrderedConfigObject()
	for _, tool := range configKeys(input["tools"]) {
		action := tool
		if tool == "write" || tool == "edit" || tool == "patch" {
			action = "edit"
		}
		effect := "deny"
		if configTruthy(configRecord(input["tools"])[tool]) {
			effect = "allow"
		}
		permission.set(action, effect)
	}
	if value, ok := input["permission"].(string); ok {
		permission.set("*", value)
	} else {
		for _, key := range configKeys(input["permission"]) {
			permission.set(key, configRecord(input["permission"])[key])
		}
	}
	result := make(map[string]any)
	for _, key := range []string{"description", "mode", "hidden"} {
		if value, exists := input[key]; exists {
			result[key] = value
		}
	}
	if model, ok := input["model"].(string); ok && legacyModelPattern.MatchString(model) {
		provider, name, _ := strings.Cut(model, "/")
		if provider == "azure-cognitive-services" {
			provider = "azure"
		} else if provider == "google-vertex-anthropic" {
			provider = "google-vertex"
		}
		selection := map[string]any{"providerID": provider, "model": name}
		if variant, ok := input["variant"].(string); ok && variant != "" && !strings.Contains(variant, "#") {
			selection["variant"] = variant
		}
		result["model"] = selection
	}
	if len(body) != 0 {
		result["request"] = map[string]any{"body": body}
	}
	if value, exists := input["prompt"]; exists {
		result["system"] = value
	}
	if value, exists := input["disable"]; exists {
		result["disabled"] = value
	}
	if value, exists := input["color"]; exists {
		color, ok := value.(string)
		if !ok || !strings.HasPrefix(color, "#") {
			color = "#aaaaaa"
		}
		result["color"] = color
	}
	if steps, exists := input["steps"]; exists || input["maxSteps"] != nil {
		if steps == nil {
			steps = input["maxSteps"]
		}
		result["steps"] = steps
	}
	if rules := migratePermissions(permission); len(rules) != 0 {
		result["permissions"] = rules
	}
	return result
}

func migratePermissions(value any) []any {
	input := value
	if rule, ok := value.(string); ok {
		input = map[string]any{"*": rule}
	}
	var result []any
	for _, action := range configKeys(input) {
		rule := configRecord(input)[action]
		resources := rule
		if effect, ok := rule.(string); ok {
			resources = map[string]any{"*": effect}
		}
		normalized := action
		switch action {
		case "write", "patch":
			normalized = "edit"
		case "task":
			normalized = "subagent"
		case "bash":
			normalized = "shell"
		}
		for _, resource := range configKeys(resources) {
			effect, _ := configRecord(resources)[resource].(string)
			if effect == "ask" || effect == "allow" || effect == "deny" {
				result = append(result, map[string]any{"action": normalized, "resource": resource, "effect": effect})
			}
		}
	}
	return result
}

func mergeNativeDataConfig(previous, overlay map[string]any, environment map[string]string) map[string]any {
	result := mergeOpenCodeConfig(previous, overlay)
	if incoming, ok := configObject(overlay["providers"]); ok {
		providers := copyConfigObject(configRecord(previous["providers"]))
		for id, value := range incoming {
			entry, ok := configObject(value)
			if !ok {
				continue
			}
			before := configRecord(providers[id])
			provider := mergeProviderData(before, entry)
			if incomingModels, ok := configObject(entry["models"]); ok {
				models := copyConfigObject(configRecord(before["models"]))
				for modelID, modelValue := range incomingModels {
					model, ok := configObject(modelValue)
					if !ok {
						continue
					}
					old := configRecord(models[modelID])
					merged := mergeProviderData(old, model)
					if incomingVariants, ok := configSlice(model["variants"]); ok {
						variants := append([]any{}, configArray(old["variants"])...)
						for _, variantValue := range incomingVariants {
							variant, ok := configObject(variantValue)
							if !ok {
								continue
							}
							index := -1
							for i, item := range variants {
								if existing, ok := configObject(item); ok && configScalarEqual(existing["id"], variant["id"]) {
									index = i
									break
								}
							}
							if index == -1 {
								variants = append(variants, variant)
							} else {
								variants[index] = mergeProviderData(configRecord(variants[index]), variant)
							}
						}
						merged["variants"] = variants
					}
					models[modelID] = merged
				}
				provider["models"] = models
			}
			providers[id] = provider
		}
		result["providers"] = providers
	}
	if model, exists := overlay["model"]; exists {
		result["model"] = model
	}
	agents := copyConfigObject(configRecord(previous["agents"]))
	incoming := make(map[string]any)
	for id, value := range configRecord(overlay["agent"]) {
		if agent, ok := configObject(value); ok {
			incoming[id] = migrateLegacyAgent(agent)
		}
	}
	if small, ok := overlay["small_model"].(string); ok {
		incoming["title"] = shallowConfigMerge(migrateLegacyAgent(map[string]any{"model": small}), configRecord(incoming["title"]))
	}
	for id, value := range configRecord(overlay["mode"]) {
		if mode, ok := configObject(value); ok {
			incoming[id] = migrateLegacyAgent(shallowConfigMerge(mode, map[string]any{"mode": "primary"}))
		}
	}
	incoming = shallowConfigMerge(incoming, configRecord(overlay["agents"]))
	home := environment["OPENCODE_TEST_HOME"]
	if home == "" {
		home, _ = environmentHome(environment)
	}
	expand := func(rules []any) []any {
		result := make([]any, len(rules))
		for i, value := range rules {
			result[i] = value
			rule, ok := configObject(value)
			if !ok {
				continue
			}
			action, _ := rule["action"].(string)
			resource, resourceOK := rule["resource"].(string)
			if !resourceOK || (action != "read" && action != "edit" && action != "external_directory") {
				continue
			}
			switch {
			case resource == "~", resource == "$HOME":
				resource = home
			case strings.HasPrefix(resource, "~/"):
				resource = filepath.Join(home, resource[2:])
			case strings.HasPrefix(resource, "$HOME/"), strings.HasPrefix(resource, `$HOME\`):
				resource = filepath.Join(home, resource[6:])
			}
			result[i] = shallowConfigMerge(rule, map[string]any{"resource": resource})
		}
		return result
	}
	for id, value := range incoming {
		agent, ok := configObject(value)
		if !ok {
			continue
		}
		before := configRecord(agents[id])
		if before["disabled"] == true {
			before = nil
		}
		if agent["disabled"] == true {
			agents[id] = map[string]any{"disabled": true}
			continue
		}
		next := shallowConfigMerge(before, agent)
		if request, ok := configObject(agent["request"]); ok {
			previousRequest := configRecord(before["request"])
			merged := shallowConfigMerge(previousRequest, request)
			for _, field := range []string{"headers", "body"} {
				merged[field] = shallowConfigMerge(configRecord(previousRequest[field]), configRecord(request[field]))
			}
			next["request"] = merged
		}
		permissions := append(append([]any{}, configArray(before["permissions"])...), expand(configArray(agent["permissions"]))...)
		if len(permissions) != 0 {
			next["permissions"] = permissions
		}
		agents[id] = next
	}
	if len(agents) != 0 {
		result["agents"] = agents
	}
	tools := newOrderedConfigObject()
	for _, name := range configKeys(overlay["tools"]) {
		value := configRecord(overlay["tools"])[name]
		if enabled, ok := value.(bool); ok {
			effect := "deny"
			if enabled {
				effect = "allow"
			}
			tools.set(name, effect)
		}
	}
	incomingPermissions := append(migratePermissions(tools), migratePermissions(overlay["permission"])...)
	incomingPermissions = append(incomingPermissions, configArray(overlay["permissions"])...)
	permissions := append(append([]any{}, configArray(previous["permissions"])...), expand(incomingPermissions)...)
	if len(permissions) != 0 {
		result["permissions"] = permissions
	}
	for _, key := range []string{"agent", "mode", "small_model", "permission", "tools"} {
		delete(result, key)
	}
	return result
}

func mergeProviderData(previous, overlay map[string]any) map[string]any {
	result := mergeOpenCodeConfig(previous, overlay)
	if _, ok := configObject(overlay["headers"]); ok {
		merged := make(map[string]any)
		caseKeys := make(map[string]string)
		for _, group := range []any{previous["headers"], overlay["headers"]} {
			for _, key := range configKeys(group) {
				lower := strings.ToLower(key)
				if old, exists := caseKeys[lower]; exists {
					delete(merged, old)
				}
				caseKeys[lower] = key
				merged[key] = configRecord(group)[key]
			}
		}
		result["headers"] = merged
	}
	return result
}

func substituteConfig(value any, environment map[string]string, directory string) (any, error) {
	switch value := value.(type) {
	case string:
		var output strings.Builder
		cursor := 0
		for _, match := range substitutionPattern.FindAllStringSubmatchIndex(value, -1) {
			output.WriteString(value[cursor:match[0]])
			kind, reference := value[match[2]:match[3]], value[match[4]:match[5]]
			if kind == "env" {
				output.WriteString(environment[reference])
			} else {
				path := reference
				if strings.HasPrefix(path, "~/") {
					home, err := environmentHome(environment)
					if err != nil {
						return nil, errors.New("Cannot resolve a file reference in native OpenCode provider configuration")
					}
					path = filepath.Join(home, path[2:])
				} else if !filepath.IsAbs(path) {
					path = filepath.Join(directory, path)
				}
				data, err := os.ReadFile(path)
				if err != nil {
					return nil, errors.New("Cannot resolve a file reference in native OpenCode provider configuration")
				}
				output.WriteString(strings.TrimSpace(string(data)))
			}
			cursor = match[1]
		}
		output.WriteString(value[cursor:])
		return output.String(), nil
	case []any:
		result := make([]any, len(value))
		for i, item := range value {
			var err error
			result[i], err = substituteConfig(item, environment, directory)
			if err != nil {
				return nil, err
			}
		}
		return result, nil
	case map[string]any:
		result := make(map[string]any, len(value))
		for key, item := range value {
			var err error
			result[key], err = substituteConfig(item, environment, directory)
			if err != nil {
				return nil, err
			}
		}
		return result, nil
	case *orderedConfigObject:
		result := newOrderedConfigObject()
		for _, key := range value.keys {
			item, err := substituteConfig(value.values[key], environment, directory)
			if err != nil {
				return nil, err
			}
			result.set(key, item)
		}
		return result, nil
	default:
		return value, nil
	}
}

// parseConfigObject accepts JSON with comments and trailing commas, as native
// OpenCode does. Comments are blanked without touching quoted strings.
func parseConfigObject(text, source string) (map[string]any, error) {
	clean, err := stripJSONComments(text)
	if err != nil {
		return nil, fmt.Errorf("Invalid OpenCode %s", source)
	}
	clean = stripJSONTrailingCommas(clean)
	decoder := json.NewDecoder(strings.NewReader(clean))
	parsed, err := decodeOrderedConfig(decoder)
	result, ok := configObject(parsed)
	if err != nil || !ok || decoder.More() {
		return nil, fmt.Errorf("Invalid OpenCode %s", source)
	}
	// Decode a second value to reject any trailing token or malformed suffix.
	if _, err := decoder.Token(); err != io.EOF {
		return nil, fmt.Errorf("Invalid OpenCode %s", source)
	}
	return result, nil
}

func stripJSONComments(text string) (string, error) {
	data := []byte(text)
	quoted, escaped := false, false
	for i := 0; i < len(data); i++ {
		if quoted {
			if escaped {
				escaped = false
			} else if data[i] == '\\' {
				escaped = true
			} else if data[i] == '"' {
				quoted = false
			}
			continue
		}
		if data[i] == '"' {
			quoted = true
			continue
		}
		if data[i] != '/' || i+1 == len(data) {
			continue
		}
		switch data[i+1] {
		case '/':
			data[i], data[i+1] = ' ', ' '
			i += 2
			for i < len(data) && data[i] != '\n' && data[i] != '\r' {
				data[i] = ' '
				i++
			}
			i--
		case '*':
			data[i], data[i+1] = ' ', ' '
			i += 2
			closed := false
			for i < len(data) {
				if i+1 < len(data) && data[i] == '*' && data[i+1] == '/' {
					data[i], data[i+1] = ' ', ' '
					i++
					closed = true
					break
				}
				if data[i] != '\n' && data[i] != '\r' {
					data[i] = ' '
				}
				i++
			}
			if !closed {
				return "", errors.New("Unclosed JSON comment")
			}
		}
	}
	return string(data), nil
}

func stripJSONTrailingCommas(text string) string {
	data := []byte(text)
	quoted, escaped := false, false
	for i := range data {
		if quoted {
			if escaped {
				escaped = false
			} else if data[i] == '\\' {
				escaped = true
			} else if data[i] == '"' {
				quoted = false
			}
			continue
		}
		if data[i] == '"' {
			quoted = true
		} else if data[i] == ',' {
			previous := i - 1
			for previous >= 0 && strings.ContainsRune(" \t\r\n", rune(data[previous])) {
				previous--
			}
			if previous < 0 || data[previous] == '[' || data[previous] == '{' || data[previous] == ',' {
				continue
			}
			next := i + 1
			for next < len(data) && strings.ContainsRune(" \t\r\n", rune(data[next])) {
				next++
			}
			if next < len(data) && (data[next] == ']' || data[next] == '}') {
				data[i] = ' '
			}
		}
	}
	return string(data)
}

func configObject(value any) (map[string]any, bool) {
	if object, ok := value.(*orderedConfigObject); ok && object != nil {
		return object.values, true
	}
	object, ok := value.(map[string]any)
	return object, ok && object != nil
}

func configRecord(value any) map[string]any {
	object, _ := configObject(value)
	return object
}

func copyConfigObject(value map[string]any) map[string]any {
	result := make(map[string]any, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}

func shallowConfigMerge(previous, overlay map[string]any) map[string]any {
	result := copyConfigObject(previous)
	for key, item := range overlay {
		result[key] = item
	}
	return result
}

func configArray(value any) []any {
	result, _ := configSlice(value)
	return result
}

func configSlice(value any) ([]any, bool) {
	switch value := value.(type) {
	case []any:
		return value, true
	case []map[string]any:
		result := make([]any, len(value))
		for i, item := range value {
			result[i] = item
		}
		return result, true
	case []string:
		result := make([]any, len(value))
		for i, item := range value {
			result[i] = item
		}
		return result, true
	default:
		return nil, false
	}
}

func configKeys(value any) []string {
	if object, ok := value.(*orderedConfigObject); ok && object != nil {
		return object.keys
	}
	object := configRecord(value)
	result := make([]string, 0, len(object))
	for key := range object {
		result = append(result, key)
	}
	sort.Strings(result)
	return result
}

func configTruthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case string:
		return value != ""
	case float64:
		return value != 0
	default:
		return true
	}
}

func configScalarEqual(left, right any) bool {
	switch left := left.(type) {
	case nil:
		return right == nil
	case string:
		value, ok := right.(string)
		return ok && left == value
	case float64:
		value, ok := right.(float64)
		return ok && left == value
	case bool:
		value, ok := right.(bool)
		return ok && left == value
	default:
		return false
	}
}
