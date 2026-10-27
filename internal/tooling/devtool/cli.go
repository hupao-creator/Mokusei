package devtool

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func Usage() {
	fmt.Println(`mokusei-dev [--repo PATH] COMMAND [OPTIONS]

build       Build the Go runtime and native Swift product (--configuration debug|release)
runtime     Build .build/go/mokusei-runtime
bundle      Create and verify a signed bundle (--channel production|development, --zip)
smoke       Verify a signed bundle and its isolated runtime lifecycle (--app PATH)
dev         Build, package and launch the isolated development channel (--fresh)
fast        Incremental Go/Swift build into an immutable development bundle (--no-open)
watch-main  Rebuild each clean local main commit (--no-open)
install     Install a signed production bundle; refuses to replace a running app
open        Open the installed production app (--app PATH)

Requires Go, Xcode/macOS 26, and an Apple Development identity for packaging.
Node is needed only by external harnesses that independently require it.`)
}
func Run(ctx context.Context, repo string, args []string) error {
	if needsBuildLease(args) && ctx.Value(buildLeaseKey{}) != repo {
		return withBuildLease(ctx, repo, func(leased context.Context) error { return Run(leased, repo, args) })
	}
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		Usage()
		return nil
	}
	command, args := args[0], args[1:]
	switch command {
	case "runtime":
		if len(args) > 0 {
			return fmt.Errorf("runtime takes no arguments")
		}
		return BuildRuntime(ctx, repo)
	}
	f := flag.NewFlagSet(command, flag.ContinueOnError)
	configurationDefault := "release"
	if command == "dev" || command == "fast" {
		configurationDefault = "debug"
	}
	configuration := f.String("configuration", configurationDefault, "Swift build configuration")
	channelDefault := "production"
	if command == "dev" || command == "fast" {
		channelDefault = "development"
	}
	channel := f.String("channel", channelDefault, "bundle channel")
	skipBuild := f.Bool("skip-build", false, "package existing build products")
	skipRuntime := f.Bool("skip-runtime", false, "reuse existing Go runtime")
	output := f.String("output", "", "bundle output directory")
	zip := f.Bool("zip", false, "also archive the signed bundle")
	product := f.String("product", "Mokusei", "Swift product")
	app := f.String("app", "", "application path")
	report := f.String("report", "", "smoke JSON report")
	destination := f.String("destination", "", "install destination")
	noOpen := f.Bool("no-open", false, "build without launching")
	fresh := f.Bool("fresh", false, "start with a clean development data directory; previous data moves to <data>.previous")
	rebuild := f.Bool("rebuild", false, "force packaging (all fast runs package fresh artifacts)")
	if err := f.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if f.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %v", f.Args())
	}
	if *fresh && command != "dev" && command != "fast" {
		return fmt.Errorf("--fresh requires the dev or fast command")
	}
	_ = rebuild
	switch command {
	case "build":
		_, err := Build(ctx, repo, *configuration, *product, *skipRuntime)
		return err
	case "bundle", "dev", "fast", "install":
		if command == "dev" || command == "fast" {
			if *channel != "development" {
				return fmt.Errorf("development commands require the development channel")
			}
		}
		if command == "install" && *channel != "production" {
			return fmt.Errorf("install requires production channel")
		}
		generation := ""
		keep := false
		if command == "fast" {
			root := filepath.Join(repo, "app/macos/dist/fast")
			if err := os.MkdirAll(root, 0755); err != nil {
				return err
			}
			var err error
			generation, err = os.MkdirTemp(root, "generation-")
			if err != nil {
				return err
			}
			*output = generation
			defer func() {
				if !keep {
					_ = os.RemoveAll(generation)
				}
			}()
		}
		application, err := Bundle(ctx, repo, BundleOptions{Channel: *channel, Configuration: *configuration, Output: *output, SkipBuild: *skipBuild, SkipRuntime: *skipRuntime, Zip: *zip})
		if err != nil {
			return err
		}
		keep = true
		if command == "install" {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			p, _ := ProductConfiguration("production")
			if *destination == "" {
				*destination = filepath.Join(home, "Applications", p.AppName)
			}
			installed, err := Install(ctx, application, *destination)
			if err == nil {
				fmt.Println("Installed", installed)
			}
			return err
		}
		if (command == "dev" || command == "fast") && !*noOpen {
			if *fresh {
				previous, err := FreshDevelopmentData()
				if err != nil {
					return err
				}
				if previous != "" {
					fmt.Println("Previous development data moved to", previous)
				}
			}
			_, err = LaunchDevelopment(ctx, application)
		}
		return err
	case "watch-main":
		return WatchMain(ctx, repo, *noOpen)
	case "open":
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		p, _ := ProductConfiguration("production")
		if *app == "" {
			*app = filepath.Join(home, "Applications", p.AppName)
		}
		if !exists(*app) {
			return fmt.Errorf("installed application not found: %s", *app)
		}
		_, err = run(ctx, repo, nil, "/usr/bin/open", *app)
		return err
	case "smoke":
		p, err := ProductConfiguration(*channel)
		if err != nil {
			return err
		}
		if *app == "" {
			*app = filepath.Join(repo, "app/macos/dist", p.AppName)
		}
		return Smoke(ctx, repo, *app, *channel, *report)
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}
