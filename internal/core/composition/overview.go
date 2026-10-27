package composition

import (
	"context"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"math"
)

type overviewControl struct{ broker *transport.OverviewBroker }

func (c overviewControl) ReadClients(ctx context.Context) ([]plugin.OverviewClientSnapshot, error) {
	value, err := c.broker.ReadClients(ctx)
	if err != nil {
		return nil, err
	}
	clients, ok := value.([]transport.OverviewSnapshot)
	if !ok {
		return nil, fmt.Errorf("invalid overview broker snapshot")
	}
	result := make([]plugin.OverviewClientSnapshot, 0, len(clients))
	for _, client := range clients {
		converted, err := convertOverview(client)
		if err != nil {
			return nil, err
		}
		result = append(result, converted)
	}
	return result, nil
}
func (c overviewControl) SelectFilter(ctx context.Context, input plugin.OverviewFilterSelection) (plugin.OverviewFilterResult, error) {
	var scope *string
	if input.Scope != "" {
		value := input.Scope
		scope = &value
	}
	result, err := c.broker.SelectFilter(ctx, transport.OverviewSelection{ClientID: input.ClientID, ContextID: input.ContextID, Revision: input.Revision, Scope: scope, Tag: input.Tag})
	if err != nil {
		return plugin.OverviewFilterResult{}, err
	}
	output := plugin.OverviewFilterResult{Status: result.Status}
	if result.Context != nil {
		value, err := convertOverview(*result.Context)
		if err != nil {
			return output, err
		}
		output.Context = &value
	}
	return output, nil
}
func convertOverview(value transport.OverviewSnapshot) (plugin.OverviewClientSnapshot, error) {
	reference := func(source *transport.OverviewThread) *model.ThreadRef {
		if source == nil {
			return nil
		}
		return &model.ThreadRef{ThreadID: source.ThreadID, TypeID: source.TypeID}
	}
	output := plugin.OverviewClientSnapshot{ClientID: value.ClientID, OverviewClientContext: plugin.OverviewClientContext{ContextID: value.ContextID, Revision: value.Revision, OverviewVisible: value.OverviewVisible, Focused: value.Focused, DocumentVisible: value.DocumentVisible, MokuOpen: value.MokuOpen, SettingsOpen: value.SettingsOpen, SelectedThread: reference(value.SelectedThread), FollowUpThread: reference(value.FollowUpThread), View: value.View, SelectedTag: value.SelectedTag, SelectedScope: value.SelectedScope, Filters: []plugin.OverviewFilter{}, RecentActions: []plugin.OverviewUserAction{}}}
	for _, filter := range value.Filters {
		if filter.Count < 0 || filter.Count > 9007199254740991 || math.Trunc(filter.Count) != filter.Count {
			return output, fmt.Errorf("invalid overview filter count")
		}
		row := plugin.OverviewFilter{Tag: filter.Tag, Scope: filter.Scope, Kind: filter.Kind, Aliases: append([]string{}, filter.Aliases...), Count: int(filter.Count), Threads: []model.ThreadRef{}}
		for _, thread := range filter.Threads {
			row.Threads = append(row.Threads, model.ThreadRef{ThreadID: thread.ThreadID, TypeID: thread.TypeID})
		}
		output.Filters = append(output.Filters, row)
	}
	for _, action := range value.RecentActions {
		row := plugin.OverviewUserAction{Kind: action.Kind, At: action.At, Thread: reference(action.Thread), Text: action.Text}
		if action.View != nil {
			row.View = *action.View
		}
		row.Tag = model.CloneRaw(action.Tag)
		output.RecentActions = append(output.RecentActions, row)
	}
	return output, nil
}

var _ plugin.OverviewControl = overviewControl{}
