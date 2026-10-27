package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

func verifyConfigurationCancellation() {
	r, _, cleanup := setup("normal")
	defer cleanup()
	entered, release := make(chan struct{}), make(chan struct{})
	holder := make(chan error, 1)
	go func() {
		holder <- r.WithConfigurationAdmission(context.Background(), func(ctx context.Context) error {
			// Nested admission shares the same owner and must not deadlock.
			if err := r.WithConfigurationAdmission(ctx, func(context.Context) error { return nil }); err != nil {
				return err
			}
			close(entered)
			<-release
			return nil
		})
	}()
	defer func() { close(release); must(receive(holder)) }()
	receive(entered)
	settings, revision, err := r.Settings()
	must(err)
	expiring, stopDeadline := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer stopDeadline()
	expired := make(chan error, 1)
	go func() {
		expired <- r.WithConfigurationAdmission(expiring, func(context.Context) error {
			return errors.New("expired admission entered its operation")
		})
	}()
	assert(errors.Is(receive(expired), context.DeadlineExceeded), "waiting admission ignored its deadline")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	results := make(chan error, 19)
	for i := 0; i < 16; i++ {
		go func() {
			_, err := r.SettingsPresentation(ctx, raw(model.Object{"scope": "global", "harnessId": "fixture", "executionOwner": "moku"}))
			results <- err
		}()
	}
	go func() {
		results <- r.WithConfigurationAdmission(ctx, func(context.Context) error {
			return errors.New("cancelled admission entered its operation")
		})
	}()
	go func() { _, _, err := r.PrepareSettings(ctx, "fixture"); results <- err }()
	go func() { _, err := r.UpdateSettings(ctx, revision, settings); results <- err }()
	cancel()
	for i := 0; i < 19; i++ {
		assert(errors.Is(receive(results), context.Canceled), "abandoned configuration request did not cancel before native discovery finished")
	}
	fmt.Println("PASS cancelled settings presentation/admission/save waiters leave an occupied configuration gate without entering it")
}

type delayedSettings struct {
	settings
	entered chan struct{}
	release chan struct{}
}

func (s delayedSettings) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	close(s.entered)
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.release:
		return raw(model.Object{"model": "captured"}), nil
	}
}

func verifySettingsDiscoveryIsolation() {
	func() {
		r, _, cleanup := setup("normal")
		defer cleanup()
		_, err := r.EnsureExecutionSettings(context.Background(), "fixture", "")
		must(err)
		current, revision, err := r.Settings()
		must(err)
		independent := model.Object{"harnessPreference": "fixture", "harnesses": model.Object{"fixture": model.Object{}}}
		current.PluginSettings = []model.PluginSettings{{ID: "report.settings", SchemaVersion: 1,
			Value: raw(model.Object{"mode": "inherit", "independent": independent})}}
		saved, err := r.UpdateSettings(context.Background(), revision, current)
		must(err)
		assert(saved.Status == "saved", "seed inherited application with retained independent profile")
		for i := 0; i < 3; i++ {
			_, err = r.SettingsPresentation(context.Background(), raw(model.Object{"scope": "global", "harnessId": "fixture", "applicationSettings": "report.settings"}))
			must(err)
			observed, revision, err := r.Settings()
			must(err)
			assert(revision == saved.SettingsRevision, "read-only inherited presentation advanced settings revision")
			assert(string(observed.PluginSettings[0].Value) == string(saved.Settings.PluginSettings[0].Value), "presentation rewrote retained independent configuration")
		}
		current = saved.Settings
		guidance := "saved after repeated application presentation"
		current.Moku.RoutingGuidance = &guidance
		restored, err := r.UpdateSettings(context.Background(), saved.SettingsRevision, current)
		must(err)
		assert(restored.Status == "saved", "read-only presentation caused subsequent save CAS conflict")
		stale, err := r.UpdateSettings(context.Background(), saved.SettingsRevision, current)
		must(err)
		assert(stale.Status == "conflict", "real stale save bypassed CAS")
		fmt.Println("PASS repeated initialized application presentation preserves revision and retained choices; subsequent saves do not hide real CAS conflicts")
	}()
	func() {
		r, _, cleanup := setup("normal")
		defer cleanup()
		draft, revision, err := r.Settings()
		must(err)
		guidance := "dirty text whose debounce has not submitted"
		draft.Moku.RoutingGuidance = &guidance
		_, err = r.EnsureExecutionSettings(context.Background(), "fixture", "")
		must(err)
		result, err := r.UpdateSettings(context.Background(), revision, draft)
		must(err)
		assert(result.Status == "conflict" && result.SettingsRevision == revision+1, "initialization-first save must return the current CAS base")
		assert(result.Settings.Moku.RoutingGuidance == nil, "unsubmitted dirty text was silently persisted")
	}()
	for _, owner := range []string{"moku", "report.settings"} {
		func() {
			r, h, cleanup := setup("normal")
			defer cleanup()
			initial, revision, err := r.Settings()
			must(err)
			if owner != "moku" {
				initial.PluginSettings = []model.PluginSettings{{ID: owner, SchemaVersion: 1, Value: raw(model.Object{"mode": "inherit"})}}
				seeded, err := r.UpdateSettings(context.Background(), revision, initial)
				must(err)
				assert(seeded.Status == "saved", "seed background settings")
				initial, revision = seeded.Settings, seeded.SettingsRevision
			}
			entered, release := make(chan struct{}), make(chan struct{})
			h.settingsAPI = delayedSettings{entered: entered, release: release}
			request := model.Object{"scope": "global", "harnessId": "fixture", "executionOwner": "moku"}
			if owner != "moku" {
				delete(request, "executionOwner")
				request["applicationSettings"] = owner
			}
			presentation := make(chan error, 1)
			go func() { _, err := r.SettingsPresentation(context.Background(), raw(request)); presentation <- err }()
			receive(entered)
			guidance := "routing guidance saved while native catalog is blocked"
			independent := model.Object{"harnessPreference": "fixture", "harnesses": model.Object{"fixture": model.Object{"model": "independent"}}}
			if owner == "moku" {
				initial.Moku.RoutingGuidance = &guidance
			} else {
				initial.PluginSettings[0].Value = raw(model.Object{"mode": "inherit", "independent": independent})
			}
			saved := make(chan core.SettingsResult, 1)
			failures := make(chan error, 1)
			go func() {
				result, err := r.UpdateSettings(context.Background(), revision, initial)
				failures <- err
				saved <- result
			}()
			must(receive(failures))
			result := receive(saved)
			assert(result.Status == "saved", "settings save waited for or conflicted with native discovery")
			close(release)
			must(receive(presentation))
			current, latest, err := r.Settings()
			must(err)
			assert(latest == result.SettingsRevision+1 && current.Moku.HostHarnessPreference == "fixture", "native initialization did not follow the settings save")
			assert(string(current.Moku.ExecutionHarnesses["fixture"]) == string(raw(model.Object{"model": "captured"})), "captured profile missing")
			if owner == "moku" {
				assert(current.Moku.RoutingGuidance != nil && *current.Moku.RoutingGuidance == guidance, "late capture lost Moku routing guidance")
			} else {
				var background map[string]any
				must(json.Unmarshal(current.PluginSettings[0].Value, &background))
				assert(string(raw(background["independent"])) == string(raw(independent)), "late capture lost saved independent application configuration")
			}
			stale, err := r.UpdateSettings(context.Background(), revision, initial)
			must(err)
			assert(stale.Status == "conflict", "native initialization bypassed a real user-save CAS conflict")
		}()
	}
	func() {
		r, h, cleanup := setup("normal")
		defer cleanup()
		entered, release := make(chan struct{}), make(chan struct{})
		h.settingsAPI = delayedSettings{entered: entered, release: release}
		presentation := make(chan any, 1)
		failures := make(chan error, 1)
		go func() {
			value, err := r.SettingsPresentation(context.Background(), raw(model.Object{"scope": "global", "harnessId": "fixture", "executionOwner": "moku"}))
			failures <- err
			presentation <- value
		}()
		receive(entered)
		current, revision, err := r.Settings()
		must(err)
		current.Harnesses["fixture"] = raw(model.Object{"model": "new source"})
		saved := make(chan core.SettingsResult, 1)
		go func() {
			value, err := r.UpdateSettings(context.Background(), revision, current)
			failures <- err
			saved <- value
		}()
		must(receive(failures))
		assert(receive(saved).Status == "saved", "native source edit blocked by presentation")
		close(release)
		must(receive(failures))
		assert(receive(presentation).(map[string]any)["executionSnapshotError"] != nil, "late capture did not reject changed native source")
		current, _, err = r.Settings()
		must(err)
		assert(len(current.Moku.ExecutionHarnesses) == 0 && current.Moku.HostHarnessPreference == "auto", "late discovery overwrote a changed native source")
	}()
	fmt.Println("PASS slow Settings discovery leaves prompt and independent application settings saves responsive, retains them on capture, and fences newer native sources and stale user saves")
}
