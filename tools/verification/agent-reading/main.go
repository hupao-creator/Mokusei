package main

import (
	"flag"
	"log"

	"github.com/hupao-creator/Mokusei/tools/verification/agent-reading/agentreading"
)

func main() {
	output := flag.String("output", "-", "Agent reading fixture JSON path")
	flag.Parse()
	if err := agentreading.Export(*output); err != nil {
		log.Fatal(err)
	}
}
