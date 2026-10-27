package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type O = map[string]any

func str(v any) string { s, _ := v.(string); return s }
func obj(v any) O      { o, _ := v.(map[string]any); return o }
func list(v any) []any { a, _ := v.([]any); return a }

var mu sync.Mutex
var sessions = map[string]O{}
var transcripts = map[string][]any{}
var credentials = map[string]O{}
var active = map[string]chan struct{}{}
var subscribers = map[chan O]bool{}
var seq int
var durableLog []O

func log(line string) {
	f, e := os.OpenFile(filepath.Join(os.Getenv("FIXTURE_ROOT"), "operations.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if e == nil {
		fmt.Fprintf(f, "%d %s %s\n", time.Now().UnixNano(), os.Getenv("OPENCODE_DB"), line)
		f.Close()
	}
}
func profile() O {
	if os.Getenv("FIXTURE_CONSOLE") != "" {
		return O{"providers": []any{O{"id": "opencode-go", "integrationID": "opencode", "name": "Go fixture", "package": "@opencode/ai/providers/openai-compatible", "activation": "enabled", "settings": O{"baseURL": os.Getenv("FIXTURE_CONSOLE")}}}, "models": []any{O{"id": "fixture-model", "providerID": "opencode-go", "name": "Go fixture", "enabled": true, "capabilities": O{"input": []any{"text"}, "output": []any{"text"}, "tools": true}, "limits": O{"context": 32000, "output": 4000}, "variants": []any{}}}, "agents": []any{O{"id": "build", "name": "build", "mode": "primary", "model": O{"providerID": "opencode-go", "id": "fixture-model"}}}}
	}

	if os.Getenv("FIXTURE_SETTINGS") == "1" {
		return O{"providers": []any{O{"id": "fixture", "package": "@opencode/ai/providers/openai-compatible", "settings": O{"baseURL": "http://127.0.0.1:1/v1", "apiKey": "synthetic-secret"}}}, "models": []any{O{"id": "fixture-model", "modelID": "fixture-wire", "providerID": "fixture", "name": "Fixture model", "enabled": true, "capabilities": O{"input": []any{"text"}, "output": []any{"text"}, "tools": true}, "variants": []any{O{"id": "low", "body": O{"reasoning_effort": "low"}}, O{"id": "off", "body": O{"thinking": O{"type": "disabled"}}}}}}, "agents": []any{O{"id": "native-primary", "name": "Native primary", "mode": "primary", "hidden": false, "model": O{"providerID": "fixture", "id": "fixture-model", "variant": "low"}}, O{"id": "build", "name": "Build", "mode": "primary"}}}

	}
	return O{"providers": []any{O{"id": "fixture", "integrationID": "fixture", "name": "Fixture", "package": "@opencode/ai/providers/openai-compatible", "activation": "enabled", "settings": O{"baseURL": "http://127.0.0.1:1/v1"}}, O{"id": "fixture-key", "integrationID": "fixture-key", "name": "Key fixture", "package": "@opencode/ai/providers/openai-compatible"}}, "models": []any{O{"id": "fixture-model", "providerID": "fixture", "name": "Fixture model", "capabilities": O{"input": []any{"text/plain"}, "output": []any{"text/plain"}, "toolcall": true}, "limits": O{"context": 32000, "output": 4000}, "variants": []any{}}}, "agents": []any{O{"id": "build", "name": "build", "mode": "primary", "model": O{"providerID": "fixture", "id": "fixture-model"}}}, "defaultAgent": "build", "defaultModel": O{"providerID": "fixture", "id": "fixture-model"}}
}
func emit(typ string, data O) {
	encoded, _ := json.Marshal(data)
	var frozen O
	_ = json.Unmarshal(encoded, &frozen)
	data = frozen
	mu.Lock()
	defer mu.Unlock()
	seq++
	event := O{"id": fmt.Sprintf("ev_%d", seq), "type": typ, "data": data, "created": time.Now().UnixMilli(), "durable": O{"aggregateID": str(data["sessionID"]), "seq": seq}}
	if !strings.HasSuffix(typ, ".delta") {
		durableLog = append(durableLog, event)
	}
	for c := range subscribers {
		select {
		case c <- event:
		default:
		}
	}
}
func send(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(O{"data": v})
}
func config() O {
	var c O
	json.Unmarshal([]byte(os.Getenv("OPENCODE_CONFIG_CONTENT")), &c)
	plugins := list(c["plugins"])
	if len(plugins) == 0 {
		return O{}
	}
	b, _ := os.ReadFile(filepath.Join(str(plugins[len(plugins)-1]), "transport.json"))
	var transport O
	json.Unmarshal(b, &transport)
	data, _ := json.Marshal(O{})
	req, _ := http.NewRequest("POST", str(transport["endpoint"])+"/configuration", strings.NewReader(string(data)))
	req.Header.Set("Authorization", "Bearer "+str(transport["token"]))
	res, e := http.DefaultClient.Do(req)
	if e != nil {
		return O{}
	}
	defer res.Body.Close()
	var out O
	json.NewDecoder(res.Body).Decode(&out)
	return out
}
func rpc(w http.ResponseWriter, r *http.Request, method string) {
	var envelope O
	json.NewDecoder(r.Body).Decode(&envelope)
	var result any = O{}
	switch method {
	case "refresh":
		if delay, err := strconv.Atoi(os.Getenv("FIXTURE_STARTUP_DELAY_MS")); err == nil {
			select {
			case <-time.After(time.Duration(delay) * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		revisions := O{}
		for _, s := range list(config()["sessions"]) {
			v := obj(s)
			revisions[str(v["sessionID"])] = v["revision"]
		}
		result = O{"revisions": revisions}
	case "credential":
		result = O{"authentication": "oauth", "baseUrl": "http://127.0.0.1:1/v1"}
		if os.Getenv("FIXTURE_CONSOLE") != "" {
			result.(O)["baseUrl"] = os.Getenv("FIXTURE_CONSOLE")
		}
	case "consoleAccount":
		result = O{}
		if os.Getenv("FIXTURE_CONSOLE") != "" {
			input := obj(envelope["input"])
			if input["phase"] == "lease" {
				result = O{"lease": O{"type": "oauth", "methodID": "console", "access": "synthetic-console-access", "expires": time.Now().Add(time.Hour).UnixMilli(), "metadata": O{"orgID": "org_fixture"}}, "configuration": O{}}
			} else {
				result = O{"provider": list(profile()["providers"])[0], "model": list(profile()["models"])[0], "variant": O{}, "sourceCredentialID": "console-fixture"}
			}
		}
	default:
		http.Error(w, "unknown fixture rpc", 404)
		return
	}
	json.NewEncoder(w).Encode(O{"output": result})
}
func serve(w http.ResponseWriter, r *http.Request) {
	user, password, ok := r.BasicAuth()
	if !ok || user != "opencode" || password != os.Getenv("OPENCODE_PASSWORD") {
		http.Error(w, "unauthorized", 401)
		return
	}
	p := r.URL.Path
	log(r.Method + " " + p + " location=" + r.URL.Query().Get("location[directory]"))
	if strings.HasPrefix(p, "/api/rpc/mokusei.harness/") {
		rpc(w, r, strings.TrimPrefix(p, "/api/rpc/mokusei.harness/"))
		return
	}
	if p == "/api/event" {
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		b, _ := json.Marshal(O{"id": "connected", "type": "server.connected", "data": O{}, "created": time.Now().UnixMilli()})
		fmt.Fprintf(w, "data: %s\n\n", b)
		f.Flush()
		c := make(chan O, 32)
		mu.Lock()
		subscribers[c] = true
		mu.Unlock()
		defer func() { mu.Lock(); delete(subscribers, c); mu.Unlock() }()
		for {
			select {
			case e := <-c:
				b, _ := json.Marshal(e)
				fmt.Fprintf(w, "data: %s\n\n", b)
				f.Flush()
			case <-r.Context().Done():
				return
			}
		}
	}
	if p == "/api/location/reload" {
		send(w, O{})
		return
	}
	if p == "/api/provider" {
		send(w, profile()["providers"])
		return
	}
	if p == "/api/config" {
		if os.Getenv("FIXTURE_CONSOLE") != "" {
			send(w, []any{O{"type": "document", "info": O{"default_agent": "build", "model": "opencode-go/fixture-model"}}})
			return
		}
		send(w, []any{O{"type": "document", "info": O{"model": "fixture/fixture-model#low"}}})
		return
	}
	if p == "/api/model" {
		if os.Getenv("FIXTURE_SETTINGS") == "1" {
			time.Sleep(80 * time.Millisecond)
		}
		send(w, profile()["models"])
		return
	}
	if p == "/api/model/default" {
		send(w, list(profile()["models"])[0])
		return
	}
	if p == "/api/agent" {
		send(w, profile()["agents"])
		return
	}
	if p == "/api/credential" {
		mu.Lock()
		defer mu.Unlock()
		if r.Method == "POST" {
			var c O
			json.NewDecoder(r.Body).Decode(&c)
			credentials[str(c["id"])] = c
			send(w, c)
			return
		}
		items := []any{}
		for _, c := range credentials {
			items = append(items, c)
		}
		send(w, items)
		return
	}
	if strings.HasPrefix(p, "/api/credential/") {
		mu.Lock()
		delete(credentials, strings.TrimPrefix(p, "/api/credential/"))
		mu.Unlock()
		send(w, O{})
		return
	}
	if p == "/api/session/active" {
		mu.Lock()
		out := O{}
		for id := range active {
			out[id] = O{"status": "running"}
		}
		mu.Unlock()
		send(w, out)
		return
	}
	if p == "/api/session" {
		if r.Method == "GET" {
			mu.Lock()
			items := []any{}
			parent := r.URL.Query().Get("parentID")
			for _, item := range sessions {
				if str(item["parentID"]) == parent {
					items = append(items, item)
				}
			}
			mu.Unlock()
			json.NewEncoder(w).Encode(O{"data": items, "cursor": O{}})
			return
		}
		var body O
		json.NewDecoder(r.Body).Decode(&body)
		id := str(body["id"])
		if id == "" {
			id = "ses_fixture"
		}
		body["id"] = id
		if body["model"] == nil {
			body["model"] = profile()["defaultModel"]
		}
		if body["agent"] == nil {
			body["agent"] = "build"
		}
		body["time"] = O{"created": time.Now().UnixMilli(), "updated": time.Now().UnixMilli()}
		mu.Lock()
		sessions[id] = body
		transcripts[id] = []any{}
		mu.Unlock()
		send(w, body)
		return
	}
	if p == "/api/experimental/session/import" {
		var body O
		json.NewDecoder(r.Body).Decode(&body)
		info := obj(body["info"])
		id := str(info["id"])
		mu.Lock()
		sessions[id] = info
		transcripts[id] = list(body["messages"])
		mu.Unlock()
		send(w, info)
		return
	}
	if strings.HasPrefix(p, "/api/experimental/session/") {
		tail := strings.TrimPrefix(p, "/api/experimental/session/")
		id, action, _ := strings.Cut(tail, "/")
		mu.Lock()
		info := sessions[id]
		messages := transcripts[id]
		done := active[id]
		mu.Unlock()
		if info == nil {
			http.NotFound(w, r)
			return
		}
		if action == "log" {
			after, _ := strconv.Atoi(r.URL.Query().Get("after"))
			w.Header().Set("Content-Type", "text/event-stream")
			mu.Lock()
			events := append([]O{}, durableLog...)
			mu.Unlock()
			for _, event := range events {
				durable := obj(event["durable"])
				sequence, _ := durable["seq"].(int)
				if durable["aggregateID"] == id && sequence > after {
					b, _ := json.Marshal(event)
					fmt.Fprintf(w, "data: %s\n\n", b)
				}
			}
			fmt.Fprint(w, "data: {\"type\":\"log.synced\",\"data\":{}}\n\n")
			return
		}
		if action == "wait" {
			if done != nil {
				select {
				case <-done:
				case <-r.Context().Done():
					return
				}
			}
			send(w, O{})
			return
		}
		if action == "export" {
			send(w, O{"info": info, "messages": messages})
			return
		}
	}
	if strings.HasPrefix(p, "/api/session/") {
		tail := strings.TrimPrefix(p, "/api/session/")
		id, action, _ := strings.Cut(tail, "/")
		mu.Lock()
		info := sessions[id]
		mu.Unlock()
		if info == nil {
			http.NotFound(w, r)
			return
		}
		if action == "" {
			if r.Method == "PATCH" {
				var overlay O
				json.NewDecoder(r.Body).Decode(&overlay)
				mu.Lock()
				for k, v := range overlay {
					info[k] = v
				}
				mu.Unlock()
			}
			send(w, info)
			return
		}
		switch action {
		case "model", "agent":
			var body O
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			info[action] = body[action]
			mu.Unlock()
			send(w, O{})
			return
		case "permission", "form", "inbox":
			send(w, []any{})
			return
		case "interrupt":
			mu.Lock()
			if done := active[id]; done != nil {
				delete(active, id)
				close(done)
			}
			info["outcome"] = "interrupted"
			obj(info["time"])["idle"] = time.Now().UnixMilli()
			mu.Unlock()
			emit("session.execution.interrupted", O{"sessionID": id})
			send(w, O{})
			return
		case "prompt":
			var body O
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			done := make(chan struct{})
			active[id] = done
			transcripts[id] = append(transcripts[id], O{"id": body["id"], "type": "user", "text": body["text"], "time": O{"created": time.Now().UnixMilli()}})
			mu.Unlock()
			emit("session.execution.started", O{"sessionID": id})
			go func() {
				time.Sleep(50 * time.Millisecond)
				assistant := "msg_fixture_assistant"
				data := O{"sessionID": id, "assistantMessageID": assistant, "model": profile()["defaultModel"], "ordinal": 0}
				emit("session.step.started", data)
				data["delta"] = "Fixture reply"
				emit("session.text.delta", data)
				time.Sleep(30 * time.Millisecond)
				now := time.Now().UnixMilli()
				tokens := O{"input": 10, "output": 3, "reasoning": 0, "cache": O{"read": 0, "write": 0}}
				emit("session.text.ended", O{"sessionID": id, "assistantMessageID": assistant, "ordinal": 0, "text": "Fixture reply"})
				emit("session.step.ended", O{"sessionID": id, "assistantMessageID": assistant, "tokens": tokens, "cost": 0})
				mu.Lock()
				if active[id] != done {
					mu.Unlock()
					return
				}
				transcripts[id] = append(transcripts[id], O{"id": assistant, "type": "assistant", "model": profile()["defaultModel"], "time": O{"created": now - 50, "completed": now}, "tokens": tokens, "cost": 0, "content": []any{O{"type": "text", "text": "Fixture reply"}}})
				info["outcome"] = "completed"
				obj(info["time"])["idle"] = now
				delete(active, id)
				close(done)
				mu.Unlock()
				emit("session.execution.succeeded", O{"sessionID": id})
			}()
			send(w, O{})
			return
		}
		send(w, O{})
		return
	}
	http.NotFound(w, r)
}
func main() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println("opencode v2.0.25")
		return
	}
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		panic("fixture expects serve")
	}
	log("process-start")
	defer log("process-exit")
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(serve)}
	go func() { io.Copy(io.Discard, os.Stdin); server.Close() }()
	fmt.Printf("{\"url\":\"http://%s\"}\n", listener.Addr())
	server.Serve(listener)
}
