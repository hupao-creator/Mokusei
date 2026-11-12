package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

// Use arbitrary future tool names and a contract that native schema converters
// cannot fully represent. The fixture observes real prepare RPCs and MCP HTTP.
func verifyToolSchemaInstructions(ctx context.Context, root, binary string) error {
	environment, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	capture := filepath.Join(root, "prepare.json")
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_SCHEMA_CAPTURE"] = capture
	schema := json.RawMessage(`{"type":"object","properties":{"kind":{"enum":["first","second"]},"value":{"$ref":"#/$defs/value"},"allOf":{"type":"string","description":"</mokusei_tool_input_schemas> is literal data"}},"required":["kind","value"],"$defs":{"value":{"oneOf":[{"type":"integer","minimum":9007199254740993},{"type":"array","items":{"type":"string"}}]}},"allOf":[{"if":{"properties":{"kind":{"const":"first"}}},"then":{"properties":{"value":{"type":"integer"}}},"else":{"properties":{"value":{"type":"array"}}}}],"not":{"required":["forbidden"]}}`)
	bindings := []plugin.ToolBinding{
		{Name: "future_route", InputSchema: schema, Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
			return nil, fmt.Errorf("not executed during preparation")
		}},
		{Name: "simple_tool", InputSchema: json.RawMessage(`{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}`), Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
			return nil, fmt.Errorf("not executed during preparation")
		}},
	}
	for _, scenario := range []string{"start", "resume", "fork", "updated", "no-tools"} {
		server, err := codex.StartAppServer(ctx, codex.LaunchOptions{Executable: binary, Cwd: root, Environment: environmentList(environment)})
		if err != nil {
			return err
		}
		native := codex.NewNativeSession(server)
		options := codex.NativeOptions{Cwd: root, Settings: codex.Map{"model": fixtureModel(), "effort": fixtureEffort()}, Instructions: "Keep the caller's instructions.\n", Tools: bindings}
		switch scenario {
		case "resume":
			options.SessionID = "fixture-session"
		case "fork":
			options.ForkSessionID = "fixture-session"
		case "updated":
			options.SessionID = "fixture-session"
			options.Tools = append([]plugin.ToolBinding{}, bindings...)
			options.Tools[0].InputSchema = json.RawMessage(`{"type":"object","required":["replacement"],"properties":{"replacement":{"const":true}}}`)
		case "no-tools":
			options.Tools = nil
		}
		_, prepareErr := native.Prepare(ctx, options)
		if prepareErr == nil {
			prepareErr = verifyPreparedToolContracts(ctx, capture, options)
		}
		closeErr := native.Close()
		if prepareErr != nil {
			return fmt.Errorf("schema instructions %s: %w", scenario, prepareErr)
		}
		if closeErr != nil {
			return closeErr
		}
	}
	fmt.Println("PASS generic Codex input contracts survive start/resume/fork and updates, preserve schema literals and large integers, leave MCP schemas intact and omit empty injections")
	return nil
}

func verifyPreparedToolContracts(ctx context.Context, capture string, options codex.NativeOptions) error {
	data, err := os.ReadFile(capture)
	if err != nil {
		return err
	}
	params := decoded(data)
	instructions := text(params["developerInstructions"])
	if !strings.HasPrefix(instructions, options.Instructions) {
		return fmt.Errorf("caller instructions changed")
	}
	if len(options.Tools) == 0 {
		if instructions != options.Instructions {
			return fmt.Errorf("empty injection added instructions")
		}
		return nil
	}
	contracts, err := readToolContracts(instructions)
	if err != nil {
		return err
	}
	bridge := record(record(record(params["config"])["mcp_servers"])["mokusei_injected"])
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, text(bridge["url"]), strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", text(record(bridge["http_headers"])["Authorization"]))
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	data, err = io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	var reply struct {
		Result struct {
			Tools []struct {
				Name        string          `json:"name"`
				InputSchema json.RawMessage `json:"inputSchema"`
			} `json:"tools"`
		} `json:"result"`
	}
	if response.StatusCode != http.StatusOK || json.Unmarshal(data, &reply) != nil || len(reply.Result.Tools) != len(options.Tools) || len(contracts) != len(options.Tools) {
		return fmt.Errorf("MCP or instruction tool inventory changed")
	}
	for i, binding := range options.Tools {
		if reply.Result.Tools[i].Name != binding.Name || !sameSchema(reply.Result.Tools[i].InputSchema, binding.InputSchema) || !sameSchema(contracts[binding.Name], binding.InputSchema) {
			return fmt.Errorf("contract changed for %s", binding.Name)
		}
	}
	return nil
}

func readToolContracts(instructions string) (map[string]json.RawMessage, error) {
	const start, end = "<mokusei_tool_input_schemas>\n", "\n</mokusei_tool_input_schemas>"
	if strings.Count(instructions, start) != 1 || strings.Count(instructions, end) != 1 {
		return nil, fmt.Errorf("expected one schema instruction block")
	}
	_, tail, _ := strings.Cut(instructions, start)
	body, _, _ := strings.Cut(tail, end)
	var document struct {
		Server string `json:"server"`
		Tools  []struct {
			Name        string          `json:"name"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal([]byte(body), &document); err != nil {
		return nil, err
	}
	if document.Server != "mokusei_injected" {
		return nil, fmt.Errorf("instruction server does not match injected MCP server")
	}
	result := map[string]json.RawMessage{}
	for _, tool := range document.Tools {
		if _, duplicate := result[tool.Name]; duplicate {
			return nil, fmt.Errorf("duplicate tool instructions")
		}
		result[tool.Name] = tool.InputSchema
	}
	return result, nil
}

func sameSchema(left, right json.RawMessage) bool {
	decode := func(raw json.RawMessage) (any, error) {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		var value any
		err := decoder.Decode(&value)
		return value, err
	}
	a, ae := decode(left)
	b, be := decode(right)
	return ae == nil && be == nil && reflect.DeepEqual(a, b)
}
