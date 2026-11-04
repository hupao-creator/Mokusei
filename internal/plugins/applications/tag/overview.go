package tag

import (
	"context"
	"encoding/json"
	"errors"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
)

func overviewContextTool(overview plugin.OverviewControl, lifetime context.Context, scope string) plugin.ToolBinding {
	return background.JSONPage(lifetime, "read_overview_context", "Read live desktop clients as read-only classification evidence: current page, visibility/focus, selected thread and active follow-up composer, current/archive view, selected filter, visible filters with member thread references, and recent user actions including submitted requests. An empty list means no connected overview. Offset/limit paginate a stable JSON snapshot.", model.Object{}, nil, func(ctx context.Context, _ model.Object, _ string) (any, error) {
		return observeOverview(ctx, overview, scope)
	})
}

func observeOverview(ctx context.Context, overview plugin.OverviewControl, scope string) (any, error) {
	clients, err := overview.ReadClients(ctx)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	observations := []model.Object{}
	for _, client := range clients {
		filters := []plugin.OverviewFilter{}
		scoped := false
		for _, filter := range client.Filters {
			if filter.Scope != "" && filter.Scope != scope {
				continue
			}
			filters = append(filters, filter)
			if filter.Scope == scope {
				scoped = true
			}
		}
		// Include only clients displaying this agent's scope.
		if scope != "" && !scoped {
			continue
		}
		client.Filters = filters
		// Thread references outside this scope's filters would let a scope agent
		// act on another workspace; classifiable would then reject the whole
		// assignment batch. Keep only refs backed by this scope's visible members.
		members := map[model.ThreadRef]bool{}
		for _, filter := range filters {
			for _, ref := range filter.Threads {
				members[ref] = true
			}
		}
		if client.SelectedThread != nil && !members[*client.SelectedThread] {
			client.SelectedThread = nil
		}
		if client.FollowUpThread != nil && !members[*client.FollowUpThread] {
			client.FollowUpThread = nil
		}
		actions := []plugin.OverviewUserAction{}
		for _, action := range client.RecentActions {
			if action.Thread != nil && !members[*action.Thread] {
				continue
			}
			actions = append(actions, action)
		}
		client.RecentActions = actions
		encoded, encodeErr := json.Marshal(client.OverviewClientContext)
		if encodeErr != nil {
			return nil, encodeErr
		}
		public, decodeErr := model.DecodeObject(encoded)
		if decodeErr != nil {
			return nil, decodeErr
		}
		delete(public, "contextId")
		delete(public, "revision")
		observations = append(observations, public)
	}

	encoded, err := json.Marshal(observations)
	if err != nil {
		return nil, err
	}
	if len(utf16.Encode([]rune(string(encoded)))) > 64*1024*1024 {
		return nil, errors.New("Overview observation is too large to capture")
	}
	return observations, nil
}
