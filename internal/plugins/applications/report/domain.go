package report

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
)

const CollectionID = "report.records"
const ThreadTypeID = "report.document"
const SettingsID = "report.settings"

func typedContract[T any](id string, required []string, validate func(*T) error) plugin.ValueContract {
	return plugin.ValueContract{ID: id, SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		if required != nil {
			object, err := model.DecodeObject(raw)
			if err != nil {
				return nil, err
			}
			for _, key := range required {
				value, ok := object[key]
				if !ok || value == nil {
					return nil, fmt.Errorf("missing %s", key)
				}
			}
			for key, value := range object {
				if value == nil {
					return nil, fmt.Errorf("%s cannot be null", key)
				}
			}
		}
		var value T
		if err := appvalue.Decode(raw, &value); err != nil {
			return nil, err
		}
		if validate != nil {
			if err := validate(&value); err != nil {
				return nil, err
			}
		}
		return json.Marshal(value)
	}}
}
func operation(id string, input plugin.ValueContract, output plugin.ValueContract) plugin.Operation {
	return plugin.Operation{ID: id, OwnerPluginID: "report", Input: input, Output: output}
}
func summaryContract() plugin.ValueContract {
	return typedContract[Summary]("report.summary", []string{"id", "revision", "title", "createdAt", "updatedAt", "relatedThreadCount", "tagCount", "archived"}, func(s *Summary) error {
		if !validID(s.ID) || s.Revision < 0 || s.CreatedAt < 0 || s.UpdatedAt < 0 || s.RelatedThreadCount < 0 || s.TagCount < 0 {
			return errors.New("invalid report summary")
		}
		_, err := ParseTitle(s.Title)
		return err
	})
}
func identityContract(id string) plugin.ValueContract {
	return typedContract[IdentityInput](id, []string{"reportId"}, func(i *IdentityInput) error {
		if !validID(i.ReportID) {
			return errors.New("invalid reportId")
		}
		return nil
	})
}
func dataContract() plugin.ValueContract {
	return plugin.ValueContract{ID: "report.data", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		object, err := model.DecodeObject(raw)
		if err != nil {
			return nil, err
		}
		for _, key := range []string{"scope", "title", "html", "contentRevision", "archived", "relatedExecutions", "tagSources"} {
			if value, ok := object[key]; !ok || value == nil {
				return nil, fmt.Errorf("missing %s", key)
			}
		}
		value, err := ParseData(raw)
		if err != nil {
			return nil, err
		}
		return json.Marshal(value)
	}}
}

// RegisterDomain installs the complete Report record and user/background
// audiences. The host enforces durable batched writes before running reducers.
func RegisterDomain(registry plugin.Registry) error {
	if err := registry.Collection(plugin.CollectionDefinition{ID: CollectionID, OwnerPluginID: "report", Retention: "history", Contract: dataContract()}); err != nil {
		return err
	}
	readOutput := plugin.ValueContract{ID: "report.read.output", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		if model.IsNull(raw) {
			return json.RawMessage("null"), nil
		}
		var value contentOutput
		if err := appvalue.Decode(raw, &value); err != nil {
			return nil, err
		}
		return json.Marshal(value)
	}}
	if err := registry.Query(plugin.QueryDefinition{Operation: operation("report.read", identityContract("report.read.input"), readOutput), Audience: plugin.QueryAudience{Background: true}, Read: func(raw json.RawMessage, context plugin.ReadContext) (json.RawMessage, error) {
		scope, err := reportScope(context.Owner)
		if err != nil {
			return nil, err
		}
		var input IdentityInput
		if err := model.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
		record, err := context.Records.Get(CollectionID, input.ReportID)
		if err != nil {
			return nil, err
		}
		if record == nil {
			return json.RawMessage("null"), nil
		}
		value, err := ParseData(record.Value)
		if err != nil {
			return nil, err
		}
		if value.Scope != scope {
			return json.RawMessage("null"), nil
		}
		return json.Marshal(content(*record, value))
	}}); err != nil {
		return err
	}
	listInput := typedContract[ListInput]("report.list.input", []string{"limit", "includeArchived"}, func(input *ListInput) error {
		if input.Limit < 1 || input.Limit > MaxDocuments {
			return errors.New("invalid Report limit")
		}
		return nil
	})
	if err := registry.Query(plugin.QueryDefinition{Operation: operation("report.list", listInput, typedContract[Page]("report.list.output", []string{"items"}, nil)), Audience: plugin.QueryAudience{Background: true}, Read: func(raw json.RawMessage, context plugin.ReadContext) (json.RawMessage, error) {
		scope, err := reportScope(context.Owner)
		if err != nil {
			return nil, err
		}
		var input ListInput
		if err := model.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
		offset := int64(0)
		if input.Cursor != nil && *input.Cursor != "" {
			var err error
			offset, err = strconv.ParseInt(*input.Cursor, 10, 64)
			if err != nil || offset < 0 || offset > 9007199254740991 {
				return nil, errors.New("Invalid Report cursor")
			}
		}
		rows, err := context.Records.List(CollectionID)
		if err != nil {
			return nil, err
		}
		summaries := []Summary{}
		for _, record := range rows {
			value, err := ParseData(record.Value)
			if err != nil {
				return nil, err
			}
			if value.Scope == scope && (input.IncludeArchived || !value.Archived) {
				summaries = append(summaries, summarize(record, value))
			}
		}
		page := Page{Items: []Summary{}}
		if offset < int64(len(summaries)) {
			end := offset + int64(input.Limit)
			if end > int64(len(summaries)) {
				end = int64(len(summaries))
			}
			page.Items = summaries[int(offset):int(end)]
			if end < int64(len(summaries)) {
				page.NextCursor = strconv.FormatInt(end, 10)
			}
		}
		return json.Marshal(page)
	}}); err != nil {
		return err
	}
	type htmlOutput struct {
		HTML            string `json:"html"`
		ContentRevision string `json:"contentRevision"`
	}
	if err := registry.Query(plugin.QueryDefinition{Operation: operation("report.html", identityContract("report.html.input"), typedContract[htmlOutput]("report.html.output", []string{"html", "contentRevision"}, nil)), Audience: plugin.QueryAudience{User: true}, Read: func(raw json.RawMessage, context plugin.ReadContext) (json.RawMessage, error) {
		var input IdentityInput
		if err := model.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
		_, value, err := requireRecord(input.ReportID, context.Records)
		if err != nil {
			return nil, err
		}
		return json.Marshal(htmlOutput{value.HTML, value.ContentRevision})
	}}); err != nil {
		return err
	}
	createInput := typedContract[CreateInput]("report.create.input", []string{"title", "html", "relatedExecutions"}, func(input *CreateInput) error {
		var err error
		if input.Title, err = ParseTitle(input.Title); err != nil {
			return err
		}
		if input.HTML, err = ParseHTML(input.HTML); err != nil {
			return err
		}
		return validateReferences(input.RelatedExecutions)
	})
	requires := []plugin.CapabilityKey{plugin.OrdinaryTaskSnapshotCapabilityKey, plugin.SemanticTagsSnapshotCapabilityKey}
	if err := registry.Command(plugin.CommandDefinition{Operation: operation("report.create", createInput, summaryContract()), Audience: plugin.CommandAudience{Background: "batch-required"}, Requires: requires,
		Plan: func(raw json.RawMessage, context plugin.ReadContext) ([]plugin.MutationScope, error) {
			var input CreateInput
			if err := model.Unmarshal(raw, &input); err != nil {
				return nil, err
			}
			return plan(input.RelatedExecutions, context)
		},
		Reduce: func(raw json.RawMessage, context plugin.TransactionContext) (json.RawMessage, error) {
			var input CreateInput
			if err := model.Unmarshal(raw, &input); err != nil {
				return nil, err
			}
			rows, err := context.Records.List(CollectionID)
			if err != nil {
				return nil, err
			}
			if len(rows) >= MaxDocuments {
				return nil, errors.New("Report Thread 数量过多")
			}
			scope, err := reportScope(context.Owner)
			if err != nil {
				return nil, err
			}
			sources, err := tagSources(input.RelatedExecutions, context.Capabilities, scope)
			if err != nil {
				return nil, err
			}
			value := Data{Scope: scope, Title: input.Title, HTML: input.HTML, ContentRevision: context.AllocateID("content"), RelatedExecutions: input.RelatedExecutions, TagSources: sources}
			encoded, err := json.Marshal(value)
			if err != nil {
				return nil, err
			}
			record, err := context.Records.Put(CollectionID, context.AllocateID("report"), encoded, plugin.RecordWriteOptions{TouchUpdatedAt: true})
			if err != nil {
				return nil, err
			}
			return json.Marshal(summarize(record, value))
		},
	}); err != nil {
		return err
	}
	updateInput := typedContract[UpdateInput]("report.update.input", []string{"reportId"}, func(input *UpdateInput) error {
		if !validID(input.ReportID) {
			return errors.New("invalid reportId")
		}
		if input.Title == nil && input.HTML == nil && input.RelatedExecutions == nil {
			return errors.New("Report update must change at least one field")
		}
		if input.Title != nil {
			value, err := ParseTitle(*input.Title)
			if err != nil {
				return err
			}
			input.Title = &value
		}
		if input.HTML != nil {
			value, err := ParseHTML(*input.HTML)
			if err != nil {
				return err
			}
			input.HTML = &value
		}
		if input.RelatedExecutions != nil {
			return validateReferences(*input.RelatedExecutions)
		}
		return nil
	})
	if err := registry.Command(plugin.CommandDefinition{Operation: operation("report.update", updateInput, summaryContract()), Audience: plugin.CommandAudience{Background: "batch-required"}, Requires: requires,
		Plan: func(raw json.RawMessage, context plugin.ReadContext) ([]plugin.MutationScope, error) {
			var input UpdateInput
			if err := model.Unmarshal(raw, &input); err != nil {
				return nil, err
			}
			if _, _, err := requireScopedRecord(input.ReportID, context.Records, context.Owner); err != nil {
				return nil, err
			}
			refs := []model.ExecutionRef{}
			if input.RelatedExecutions != nil {
				refs = *input.RelatedExecutions
			}
			return plan(refs, context)
		},
		Reduce: func(raw json.RawMessage, context plugin.TransactionContext) (json.RawMessage, error) {
			var input UpdateInput
			if err := model.Unmarshal(raw, &input); err != nil {
				return nil, err
			}
			record, value, err := requireScopedRecord(input.ReportID, context.Records, context.Owner)
			if err != nil {
				return nil, err
			}
			if input.Title != nil {
				value.Title = *input.Title
			}
			if input.HTML != nil && *input.HTML != value.HTML {
				value.HTML = *input.HTML
				value.ContentRevision = context.AllocateID("content")
			}
			if input.RelatedExecutions != nil {
				sources, err := tagSources(*input.RelatedExecutions, context.Capabilities, value.Scope)
				if err != nil {
					return nil, err
				}
				value.RelatedExecutions = *input.RelatedExecutions
				value.TagSources = sources
			}
			encoded, err := json.Marshal(value)
			if err != nil {
				return nil, err
			}
			saved, err := context.Records.Put(CollectionID, record.ID, encoded, plugin.RecordWriteOptions{ExpectedRevision: &record.Revision, TouchUpdatedAt: true})
			if err != nil {
				return nil, err
			}
			return json.Marshal(summarize(saved, value))
		},
	}); err != nil {
		return err
	}
	extensions := threadExtensions{}
	return registry.ThreadType(plugin.ThreadTypeDefinition{ID: ThreadTypeID, OwnerPluginID: "report", DisplayName: "Report", CollectionID: CollectionID, Contract: typedContract[View]("report.view", []string{"previewText", "contentRevision", "relatedExecutions"}, nil), Project: func(record model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
		value, err := ParseData(record.Value)
		if err != nil {
			return plugin.ThreadProjection{}, err
		}
		view, err := json.Marshal(View{HTMLPreview(value.HTML, value.Title), value.ContentRevision, value.RelatedExecutions})
		return plugin.ThreadProjection{Scope: value.Scope, Title: value.Title, View: view}, err
	}, SearchText: func(record model.ApplicationThreadRecord) (string, error) {
		value, err := ParseData(record.Value)
		if err != nil {
			return "", err
		}
		return HTMLSearchText(value.HTML), nil
	}, Tags: extensions, Archive: extensions, Overview: extensions})
}

// Scope comes only from the host's trusted background owner, never tool input.
func reportScope(owner plugin.BackgroundAgentRef) (string, error) {
	if owner.PluginID != "report" || owner.AgentID == "" || owner.Binding.Kind != plugin.DirectoryScopeKind || owner.Binding.Validate() != nil {
		return "", errors.New("report requires a scoped background owner")
	}
	return owner.Binding.Scope, nil
}
func requireScopedRecord(id string, records plugin.RecordsReader, owner plugin.BackgroundAgentRef) (model.VersionedRecord, Data, error) {
	scope, err := reportScope(owner)
	if err != nil {
		return model.VersionedRecord{}, Data{}, err
	}
	record, value, err := requireRecord(id, records)
	if err != nil {
		return record, value, err
	}
	if value.Scope != scope {
		return model.VersionedRecord{}, Data{}, errors.New("Report Thread unavailable in this scope")
	}
	return record, value, nil
}

func requireRecord(id string, records plugin.RecordsReader) (model.VersionedRecord, Data, error) {
	record, err := records.Get(CollectionID, id)
	if err != nil {
		return model.VersionedRecord{}, Data{}, err
	}
	if record == nil {
		return model.VersionedRecord{}, Data{}, fmt.Errorf("Report Thread 不存在: %s", id)
	}
	value, err := ParseData(record.Value)
	return *record, value, err
}
func plan(refs []model.ExecutionRef, context plugin.ReadContext) ([]plugin.MutationScope, error) {
	if _, err := reportScope(context.Owner); err != nil {
		return nil, err
	}
	tasks, err := plugin.Require[plugin.OrdinaryTaskSnapshotCapability](context.Capabilities, plugin.OrdinaryTaskSnapshotCapabilityKey)
	if err != nil {
		return nil, err
	}
	tags, err := plugin.Require[plugin.SemanticTagsSnapshotCapability](context.Capabilities, plugin.SemanticTagsSnapshotCapabilityKey)
	if err != nil {
		return nil, err
	}
	collection, err := context.Records.Scope(CollectionID, "")
	if err != nil {
		return nil, err
	}
	tagScope, err := tags.Scope()
	if err != nil {
		return nil, err
	}
	scopes := []plugin.MutationScope{collection, tagScope}
	for _, ref := range refs {
		scope, err := tasks.Scope(ref.Thread)
		if err != nil {
			return nil, err
		}
		scopes = append(scopes, scope)
	}
	return scopes, nil
}
func tagSources(refs []model.ExecutionRef, access plugin.CapabilityAccess, scope string) (map[string]TagSource, error) {
	tasks, err := plugin.Require[plugin.OrdinaryTaskSnapshotCapability](access, plugin.OrdinaryTaskSnapshotCapabilityKey)
	if err != nil {
		return nil, err
	}
	tags, err := plugin.Require[plugin.SemanticTagsSnapshotCapability](access, plugin.SemanticTagsSnapshotCapabilityKey)
	if err != nil {
		return nil, err
	}
	sources := map[string]TagSource{}
	for _, ref := range refs {
		task, err := tasks.Get(ref.Thread)
		if err != nil {
			return nil, err
		}
		if task == nil || task.Scope != scope {
			return nil, errors.New("report execution reference is outside its scope")
		}
		execution, err := tasks.ResolveExecution(ref)
		if err != nil {
			return nil, err
		}
		if execution == nil || execution.ExecutionID != ref.ExecutionID || execution.Status != "completed" {
			return nil, errors.New("报告只能关联普通 Thread 的 completed Execution")
		}
		source, err := tags.ReadThreadTags(ref.Thread)
		if err != nil {
			return nil, err
		}
		sources[ref.Thread.ThreadID] = TagSource{SemanticTags: append([]string{}, source.SemanticTags...), DirectoryTags: append([]string{}, source.DirectoryTags...), TagEmojis: source.TagEmojis}
	}
	return sources, nil
}

type contentOutput struct {
	ID                string               `json:"id"`
	Revision          int64                `json:"revision"`
	CreatedAt         int64                `json:"createdAt"`
	UpdatedAt         int64                `json:"updatedAt"`
	Title             string               `json:"title"`
	HTML              string               `json:"html"`
	ContentRevision   string               `json:"contentRevision"`
	RelatedExecutions []model.ExecutionRef `json:"relatedExecutions"`
	Archived          bool                 `json:"archived"`
	model.TagProjection
}

func content(record model.VersionedRecord, value Data) contentOutput {
	return contentOutput{record.ID, record.Revision, record.CreatedAt, record.UpdatedAt, value.Title, value.HTML, value.ContentRevision, value.RelatedExecutions, value.Archived, ProjectTags(value)}
}

type threadExtensions struct{}

func (threadExtensions) Project(record model.ApplicationThreadRecord) (model.TagProjection, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return model.TagProjection{}, err
	}
	return ProjectTags(value), nil
}
func (threadExtensions) Sources(record model.ApplicationThreadRecord) ([]model.ThreadRef, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return nil, err
	}
	refs := []model.ThreadRef{}
	for _, ref := range value.RelatedExecutions {
		refs = append(refs, ref.Thread)
	}
	return refs, nil
}
func (threadExtensions) Apply(record model.ApplicationThreadRecord, effect plugin.SemanticTagEffect) (plugin.ThreadStateChange, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return plugin.ThreadStateChange{}, err
	}
	for _, ref := range value.RelatedExecutions {
		source := value.TagSources[ref.Thread.ThreadID]
		live := false
		for _, current := range effect.SourceThreads {
			if current.Thread == ref.Thread {
				live = true
				source.TagEmojis = current.Tags.TagEmojis
				source.SemanticTags = append([]string{}, current.Tags.SemanticTags...)
				source.DirectoryTags = append([]string{}, current.Tags.DirectoryTags...)
			}
		}
		if !live {
			// A deleted source thread no longer has a directory. Drop the
			// persisted host-derived label so a stale task-… name cannot survive
			// forever; semantic labels remain report-authored history.
			source.DirectoryTags = []string{}
			source.SemanticTags = uniqueTags(source.SemanticTags)
		}
		value.TagSources[ref.Thread.ThreadID] = source
	}
	encoded, err := json.Marshal(value)
	return plugin.ThreadStateChange{Value: encoded}, err
}
func (threadExtensions) Archived(record model.ApplicationThreadRecord) bool {
	value, err := ParseData(record.Value)
	return err == nil && value.Archived
}
func (threadExtensions) Change(record model.ApplicationThreadRecord, archived bool) (plugin.ThreadStateChange, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return plugin.ThreadStateChange{}, err
	}
	value.Archived = archived
	encoded, err := json.Marshal(value)
	return plugin.ThreadStateChange{Value: encoded}, err
}
func (threadExtensions) RelatedLatestExecutions(record model.ApplicationThreadRecord, archived bool) ([]model.ExecutionRef, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return nil, err
	}
	if !archived {
		return []model.ExecutionRef{}, nil
	}
	return value.RelatedExecutions, nil
}
func (threadExtensions) Presentation(record model.ApplicationThreadRecord) (plugin.OverviewPresentation, error) {
	value, err := ParseData(record.Value)
	if err != nil {
		return plugin.OverviewPresentation{}, err
	}
	return plugin.OverviewPresentation{CoversExecutions: value.RelatedExecutions}, nil
}
