package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func sessionPath(id, suffix string) string { return "/api/session/" + url.PathEscape(id) + suffix }
func frozenTranscript(transcript Object) Object {
	out := clone(transcript)
	settled := []any{}
	for _, raw := range array(out["messages"]) {
		m := object(raw)
		kind := str(m["type"])
		if kind == "assistant" && object(m["time"])["completed"] == nil {
			continue
		}
		if (kind == "shell" || kind == "compaction") && m["status"] == "running" {
			continue
		}
		settled = append(settled, m)
	}
	out["messages"] = settled
	return out
}
func importTranscript(transcript Object, id, cwd string, settings Settings) Object {
	previous := object(transcript["info"])
	now := time.Now().UnixMilli()
	project := str(previous["projectID"])
	if project == "" {
		project = "global"
	}
	info := Object{"id": id, "projectID": project, "location": Object{"directory": cwd}, "cost": 0, "tokens": Object{"input": 0, "output": 0, "reasoning": 0, "cache": Object{"read": 0, "write": 0}}, "time": Object{"created": now, "updated": now}}
	if title := str(previous["title"]); title != "" {
		info["title"] = title
	}
	if settings.Agent != "" {
		info["agent"] = settings.Agent
	}
	if native := settings.NativeModel(); native != nil {
		info["model"] = native
	}
	messages := clone(array(transcript["messages"]))
	for i, raw := range messages {
		object(raw)["id"] = importedMessageID(id, i)
	}
	return Object{"info": info, "messages": messages, "location": Object{"directory": cwd}}
}
func importedMessageID(id string, index int) string {
	return fmt.Sprintf("msg_%s_fork_%d", strings.TrimPrefix(id, "ses_"), index)
}
func (r *Runtime) Snapshot(ctx context.Context, id string) (Object, error) {
	var result Object
	err := r.Request(ctx, "GET", "/api/experimental/session/"+url.PathEscape(id)+"/export", nil, &result)
	if err == nil {
		if object(result["info"])["id"] != id || result["messages"] == nil {
			return nil, errors.New("invalid native OpenCode transcript")
		}
	}
	return result, err
}
func (r *Runtime) Descendants(ctx context.Context, root string) ([]string, error) {
	seen := map[string]bool{root: true}
	queue := []string{root}
	out := []string{root}
	for len(queue) > 0 {
		parent := queue[0]
		queue = queue[1:]
		cursor := ""
		for {
			q := url.Values{"parentID": {parent}, "limit": {"1000"}}
			if cursor != "" {
				q.Set("cursor", cursor)
			}
			var raw RawResponse
			if err := r.Request(ctx, "GET", "/api/session?"+q.Encode(), nil, &raw); err != nil {
				return nil, err
			}
			var page struct {
				Data   []Object `json:"data"`
				Cursor struct {
					Next string `json:"next"`
				} `json:"cursor"`
			}
			if err := decodeJSON(raw, &page); err != nil {
				return nil, err
			}
			for _, info := range page.Data {
				id := str(info["id"])
				if id != "" && !seen[id] {
					if str(info["parentID"]) != parent || !r.bridge.TrackChild(id, parent) {
						return nil, errors.New("OpenCode returned an unrelated descendant")
					}
					seen[id] = true
					queue = append(queue, id)
					out = append(out, id)
				}
			}
			if page.Cursor.Next == "" || page.Cursor.Next == cursor {
				break
			}
			cursor = page.Cursor.Next
		}
	}
	return out, nil
}

// ReplayLog follows the native durable aggregate sequence, never volatile text
// deltas. A log.synced marker proves the finite reconciliation boundary.
func (r *Runtime) ReplayLog(ctx context.Context, id string, after int64, consume func(Event) error) error {
	if !r.bridge.Owns(id) {
		return errors.New("OpenCode session is not owned by this Mokusei runtime")
	}
	query := url.Values{"follow": {"false"}}
	if after >= 0 {
		query.Set("after", fmt.Sprint(after))
	}
	requestCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(r.ctx, cancel)
	defer stop()
	req, err := http.NewRequestWithContext(requestCtx, "GET", r.URL+"/api/experimental/session/"+url.PathEscape(id)+"/log?"+query.Encode(), nil)
	if err != nil {
		return err
	}
	req.SetBasicAuth("opencode", r.password)
	req.Header.Set("Accept", "text/event-stream")
	res, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return &RequestError{res.StatusCode, "GET", req.URL.Path}
	}
	synced := false
	err = readSSE(res.Body, func(raw []byte) error {
		var event Event
		if err := json.Unmarshal(raw, &event); err != nil {
			return err
		}
		if event.Type == "log.synced" {
			synced = true
			return nil
		}
		return consume(event)
	})
	if errors.Is(err, io.EOF) && synced {
		return nil
	}
	if err == nil || errors.Is(err, io.EOF) {
		return errors.New("OpenCode durable log ended without synchronization marker")
	}
	return err
}
