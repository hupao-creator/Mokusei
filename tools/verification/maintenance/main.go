package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/tooling/maintenance"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func main() {
	models := []any{}
	plus := map[string]any{}
	docs := "## Endpoints\n"
	for i := 0; i < 10; i++ {
		id := fmt.Sprintf("model-%d", i)
		name := fmt.Sprintf("Model %d", i)
		models = append(models, map[string]any{"id": id, "name": name, "allowance": float64(i + 1)})
		plus[id] = []any{0, float64((i + 1) * 3)}
		docs += fmt.Sprintf("| %s | `%s` | https://opencode.ai/zen/go/v1/messages | text |\n", name, id)
	}
	modelsJSON, _ := json.Marshal(models)
	plusJSON, _ := json.Marshal(plus)
	code := "export const goModels = " + string(modelsJSON) + ";\nexport const plusLimits = " + string(plusJSON) + ";"
	snapshot, err := maintenance.ExtractAllowances(code, docs, strings.Repeat("a", 40), "2026-10-18")
	must(err)
	check(len(snapshot.Models) == 10 && snapshot.Models[0].MonthlyUSD.GoPlus == 3, "allowance extraction/provenance")
	_, err = maintenance.ExtractAllowances(strings.Replace(code, "goModels = [", "goModels = execute([", 1), docs, strings.Repeat("a", 40), "2026-10-18")
	check(err != nil, "executable expression accepted as data")
	fmt.Println("PASS maintenance: pinned allowance literals without code execution")
}
