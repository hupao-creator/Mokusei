package main

import (
	"flag"
	"github.com/hupao-creator/Mokusei/tools/verification/firstresponse"
	"log"
)

func main() {
	output := flag.String("output", "/private/tmp/mokusei-initial-response.json", "actual Go renderer fixtures for native replay")
	flag.Parse()
	if err := firstresponse.Export(*output); err != nil {
		log.Fatal(err)
	}
}
