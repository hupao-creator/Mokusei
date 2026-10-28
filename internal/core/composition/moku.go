package composition

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

func (b *Bootstrap) mokuConfiguration(cwd, data string) moku.Configuration {
	r := b.runtime
	config := moku.Configuration{
		Workspace: cwd, DataDir: data, Harnesses: b.harnesses,
		HarnessEnabled: func(id string) bool { return b.disabled[id] == "" }, IsDeleting: r.IsDeleting,
		WithSettingsAdmission: r.WithConfigurationAdmission, PrepareSettings: r.PrepareSettings,
		Settings: r.Settings, Threads: r.Threads, Thread: r.Thread, UpdateThread: r.UpdateThread, UpdateNote: r.UpdateMokuNote,
		ReadSessionConfiguration: func() (moku.SessionConfiguration, error) {
			value, err := r.ReadMokuConfiguration()
			return moku.SessionConfiguration{Unapplied: value.Unapplied, HarnessID: value.HarnessID, Settings: value.Settings, AppliedSettings: value.AppliedSettings, SettingsRevision: value.SettingsRevision, Cwd: value.Cwd}, err
		},
		EnsureSession: func(ctx context.Context, value moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.EnsureConfiguredMokuThread(ctx, core.MokuConfiguration{Unapplied: value.Unapplied, HarnessID: value.HarnessID, Settings: value.Settings, Cwd: value.Cwd, AppliedSettings: value.AppliedSettings, SettingsRevision: value.SettingsRevision})
		},
		ReplaceSession: func(ctx context.Context, id string, value moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.ReplaceConfiguredMokuThread(ctx, id, core.MokuConfiguration{Unapplied: value.Unapplied, HarnessID: value.HarnessID, Settings: value.Settings, Cwd: value.Cwd, AppliedSettings: value.AppliedSettings, SettingsRevision: value.SettingsRevision, PreserveNote: value.PreserveNote, PreserveHistory: value.PreserveHistory})
		},
		ConfigureSession: func(ctx context.Context, id string, revision int64, value moku.SessionConfiguration) error {
			return r.ConfigureMokuThread(ctx, id, revision, value.HarnessID, value.Settings, value.AppliedSettings, value.SettingsRevision, value.Cwd)
		},
		OpenSession: r.OpenMokuThread, SetNativeAdmission: r.SetMokuNativeAdmission, CloseSession: r.CloseMokuThread, SendSession: r.SendMokuThread,
		PendingDeliveries: r.PendingMokuDeliveries, SendDelivery: r.SendMokuDelivery,
		SubscribeCommitted: r.OnThreadCommitted, SubscribeDiagnostics: b.subscribeDiagnostics,
		SubscribeUserThreadInputs: r.SubscribeUserThreadInputs,
		CreateThread: func(ctx context.Context, request moku.CreateThreadRequest) (moku.CreatedThread, error) {
			result, err := r.CreateThread(ctx, core.CreateThreadRequest{ResolveSettings: request.ResolveSettings, HarnessID: request.HarnessID, Input: request.Input, Cwd: request.Cwd, Settings: request.Settings, Worktree: request.Worktree})
			return moku.CreatedThread{Record: result.Record, Execution: result.Execution, Acknowledgement: result.Acknowledgement, WorktreeName: result.WorktreeName, WorktreeNameAdjusted: result.WorktreeNameAdjusted, WorktreeNameNotice: result.WorktreeNameNotice}, err
		},
		SendThread: r.SendThread, ReadThread: r.ReadThread, InterruptThread: r.InterruptThread, InterruptThreadTarget: r.InterruptThreadTarget, ClaimThreadInput: r.ClaimThreadInput, RespondThread: r.RespondThread,
		CanonicalizeInput: b.attachments.CanonicalizeInput,
		StageAttachments: func(ctx context.Context, raw json.RawMessage) (any, error) {
			var imports []attachments.Import
			if err := model.Unmarshal(raw, &imports); err != nil {
				return nil, err
			}
			return b.attachments.Stage(ctx, imports)
		},
		CollectContext: func(ctx context.Context, phase string, settings model.Settings) ([]plugin.ContextEntry, error) {
			catalogs := []plugin.BoundModelCatalog{}
			for _, id := range []string{"codex", "claude", "pi", "opencode"} {
				h := b.harnesses[id]
				if b.disabled[id] != "" {
					continue
				}
				source, ok := h.(plugin.ModelCatalogSource)
				if !ok {
					continue
				}
				raw := settings.Harnesses[id]
				if len(raw) == 0 {
					raw = h.DefaultSettings()
				}
				catalogs = append(catalogs, plugin.BoundModelCatalog{ID: id, DisplayName: h.Descriptor().DisplayName, Load: func(ctx context.Context) (json.RawMessage, error) {
					if cached, ok := h.(plugin.CachedModelCatalogSource); ok {
						return cached.CachedModelCatalog(ctx, plugin.SettingsRequest{Settings: raw, Cwd: cwd})
					}
					return source.ModelCatalog(ctx, plugin.SettingsRequest{Settings: raw, Cwd: cwd})
				}})
			}
			return b.contexts.CollectMokuContexts(ctx, phase, catalogs)
		},
		Ledger:             b.ledger,
		PrepareNativeVoice: r.PrepareMokuVoice, CompletedReply: r.CompletedReply, ReportFailure: b.log,
	}
	for _, id := range []string{"codex", "claude", "pi", "opencode"} {
		if b.disabled[id] != "" {
			continue
		}
		if voice, ok := b.harnesses[id].(plugin.VoiceCapability); ok {
			config.Voice = voice
			break
		}
	}
	return config
}

// readOutputLocale is called at every background batch boundary, including
// reused native sessions; interface locale is not execution-language authority.
func readOutputLocale(ctx context.Context, p profile.Profile) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var value struct {
		Locale string `json:"locale"`
	}
	if err := profile.ReadPrivateJSON(filepath.Join(p.DataDir, "runtime", "output-locale.json"), &value); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "zh-CN", nil
		}
		return "", err
	}
	if value.Locale != "zh-CN" && value.Locale != "en-US" {
		return "", model.NewError("INVALID_OUTPUT_LOCALE", "Output locale must be zh-CN or en-US")
	}
	return value.Locale, nil
}
