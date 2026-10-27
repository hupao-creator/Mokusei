package maintenance

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const Usage = `Usage: mokusei-maintain [--repo PATH] COMMAND

  update-opencode-go-allowances [dev|COMMIT_SHA]
      [--output PATH] [--code FILE --docs FILE] [--verified-at YYYY-MM-DD]

Allowance updates parse official pinned data literals without executing source.
Local allowance inputs require a pinned SHA and make no network requests.
The default allowance output is internal/plugins/harness/opencode/accounttelemetry/assets/opencode-go-allowances.json.
`

func Run(ctx context.Context, args []string, output io.Writer) error {
	if output == nil {
		return errors.New("maintenance output writer is required")
	}
	repo := ""
	if len(args) > 0 && args[0] == "--repo" {
		if len(args) < 2 {
			return errors.New("--repo requires a path")
		}
		repo = args[1]
		args = args[2:]
	}
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		_, err := io.WriteString(output, Usage)
		return err
	}
	command, rest := args[0], args[1:]
	if len(rest) == 1 && (rest[0] == "--help" || rest[0] == "-h") {
		_, err := io.WriteString(output, Usage)
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	switch command {
	case "update-opencode-go-allowances":
		flags, positionals, err := maintenanceFlags(rest)
		if err != nil {
			return err
		}
		if repo == "" {
			repo, err = os.Getwd()
			if err != nil {
				return err
			}
		}
		repo, err = Repository(repo)
		if err != nil {
			return err
		}
		if len(positionals) > 1 {
			return errors.New("allowance update expects dev or one pinned SHA")
		}
		for flag := range flags {
			if flag != "output" && flag != "code" && flag != "docs" && flag != "verified-at" {
				return fmt.Errorf("unknown allowance update flag: --%s", flag)
			}
		}
		ref := "dev"
		if len(positionals) == 1 {
			ref = positionals[0]
		}
		result, err := UpdateAllowances(ctx, AllowanceOptions{Repository: repo, Ref: ref, Output: flags["output"], CodePath: flags["code"], DocsPath: flags["docs"], VerifiedAt: flags["verified-at"]})
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(output, "Updated %d Go model allowances from %s\n", result.Models, result.Revision)
		return err
	default:
		return fmt.Errorf("unknown maintenance command %q\n%s", command, Usage)
	}
}
func maintenanceFlags(args []string) (map[string]string, []string, error) {
	flags := map[string]string{}
	positionals := []string{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "--") {
			if strings.HasPrefix(arg, "-") {
				return nil, nil, fmt.Errorf("unknown flag: %s", arg)
			}
			positionals = append(positionals, arg)
			continue
		}
		name, value, inline := strings.Cut(strings.TrimPrefix(arg, "--"), "=")
		if name == "" {
			return nil, nil, errors.New("invalid maintenance flag")
		}
		if _, exists := flags[name]; exists {
			return nil, nil, fmt.Errorf("duplicate flag: --%s", name)
		}
		if !inline {
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
				return nil, nil, fmt.Errorf("--%s requires a value", name)
			}
			i++
			value = args[i]
		}
		if value == "" {
			return nil, nil, fmt.Errorf("--%s requires a nonempty value", name)
		}
		flags[name] = value
	}
	return flags, positionals, nil
}
