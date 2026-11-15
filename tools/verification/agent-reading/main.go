package main

import (
	"encoding/json"
	"flag"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"log"
	"os"

	"github.com/hupao-creator/Mokusei/tools/verification/agent-reading/agentreading"
)

func main() {
	output := flag.String("output", "-", "Agent reading fixture JSON path")
	input := flag.String("codex-input", "", "Project native Codex state and scope from this JSON file")
	flag.Parse()
	if *input != "" {
		data, err := os.ReadFile(*input)
		if err != nil {
			log.Fatal(err)
		}
		var request struct {
			State codex.Map `json:"state"`
			Scope codex.Map `json:"scope"`
		}
		if err := json.Unmarshal(data, &request); err != nil {
			log.Fatal(err)
		}
		data, err = json.Marshal(codex.ProjectRenderer(request.State, request.Scope))
		if err != nil {
			log.Fatal(err)
		}
		if err := os.WriteFile(*output, data, 0600); err != nil {
			log.Fatal(err)
		}
		return
	}
	if err := agentreading.Export(*output); err != nil {
		log.Fatal(err)
	}
}
