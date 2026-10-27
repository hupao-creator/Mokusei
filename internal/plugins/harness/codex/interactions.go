package codex

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

func approvalActions() []any {
	return []any{Map{"id": "allow-once", "intent": "allow", "label": "允许一次"}, Map{"id": "allow-session", "intent": "allow", "label": "本会话允许"}, Map{"id": "deny", "intent": "deny", "label": "拒绝"}, Map{"id": "cancel", "intent": "cancel", "label": "取消"}}
}
func ParseInteraction(method string, p Map) (Map, error) {
	id := first(str(p["interactionId"]), str(p["elicitationId"]), uid())
	r := Map{"id": id, "blocksTurn": true, "status": "pending", "questions": []any{}, "actions": approvalActions()}
	switch method {
	case "item/commandExecution/requestApproval":
		r["kind"] = "command-approval"
		r["title"] = first(str(p["reason"]), "Codex 请求运行命令")
		r["detail"] = first(str(p["command"]), compact(p["commandActions"]))
	case "item/fileChange/requestApproval":
		r["kind"] = "file-approval"
		r["title"] = first(str(p["reason"]), "Codex 请求修改文件")
		r["detail"] = str(p["grantRoot"])
	case "item/permissions/requestApproval":
		r["kind"] = "permissions"
		r["title"] = first(str(p["reason"]), "Codex 请求额外权限")
		r["detail"] = compact(p["permissions"])
		r["actions"] = approvalActions()[:3]
	case "item/tool/requestUserInput":
		if _, ok := p["isBlocking"].(bool); !ok {
			return nil, errors.New("Codex requestUserInput 缺少 isBlocking")
		}
		r["blocksTurn"] = p["isBlocking"]
		if _, ok := p["questions"].([]any); !ok {
			return nil, errors.New("Codex requestUserInput questions 必须是数组")
		}
		r["kind"] = "user-input"
		r["title"] = "Codex 需要补充信息"
		r["actions"] = []any{Map{"id": "submit", "intent": "submit", "label": "提交"}, Map{"id": "cancel", "intent": "cancel", "label": "取消"}}
		questions := []any{}
		seen := map[string]bool{}
		for _, v := range arr(p["questions"]) {
			q := obj(v)
			id := str(q["id"])
			if id == "" || seen[id] {
				return nil, errors.New("Codex question ID 缺失或重复")
			}
			seen[id] = true
			options := []any{}
			if q["options"] != nil {
				if _, ok := q["options"].([]any); !ok {
					return nil, errors.New("Codex question options 必须是数组")
				}
			}
			for i, v := range arr(q["options"]) {
				o := obj(v)
				if str(o["label"]) == "" {
					return nil, errors.New("Codex option 缺少 label")
				}
				option := Map{"id": fmt.Sprintf("%s:option:%d", id, i), "label": o["label"]}
				if o["description"] != nil {
					option["description"] = o["description"]
				}
				options = append(options, option)
			}
			n := Map{"id": id, "prompt": first(str(q["question"]), "Codex question"), "secret": q["isSecret"] == true, "allowOther": q["isOther"] == true, "options": options}
			if str(q["header"]) != "" {
				n["header"] = q["header"]
			}
			questions = append(questions, n)
		}
		r["questions"] = questions
	case "mcpServer/elicitation/request":
		mode := str(p["mode"])
		if mode != "" && mode != "form" && mode != "openai/form" && mode != "url" {
			return nil, nil
		}
		r["kind"] = "mcp-elicitation"
		r["title"] = first(str(p["message"]), str(p["serverName"])+" 请求输入")
		intent, label := "submit", "提交"
		if mode == "url" {
			if str(p["url"]) == "" {
				return nil, errors.New("MCP elicitation 缺少 URL")
			}
			r["elicitation"] = Map{"mode": "url", "url": p["url"]}
		} else {
			schema := obj(p["requestedSchema"])
			r["elicitation"] = Map{"mode": "form", "requestedSchema": schema, "questionId": "values"}
			r["questions"] = []any{Map{"id": "values", "prompt": "JSON form values", "secret": false, "allowOther": true, "options": []any{}}}
			if confirmationSchema(schema) {
				intent, label = "allow", "允许"
			}
		}
		r["actions"] = []any{Map{"id": "submit", "intent": intent, "label": label}, Map{"id": "deny", "intent": "deny", "label": "拒绝"}, Map{"id": "cancel", "intent": "cancel", "label": "取消"}}
	default:
		return nil, nil
	}
	if err := ValidateInteraction(r); err != nil {
		return nil, err
	}
	return r, nil
}
func compact(v any) string {
	if v == nil {
		return ""
	}
	return tail(jsonText(v), 32*1024)
}
func confirmationSchema(schema Map) bool { return stConfirmationSchema(schema) }

func EncodeInteractionResponse(method string, p, interaction, response Map) (Map, string, error) {
	a := str(response["actionId"])
	valid := false
	for _, v := range arr(interaction["actions"]) {
		if obj(v)["id"] == a {
			valid = true
		}
	}
	if !valid {
		return nil, "", fmt.Errorf("Codex interaction action 不可用: %s", a)
	}
	resolution := map[string]string{"allow-once": "accept", "allow-session": "acceptForSession", "deny": "decline", "cancel": "cancel", "submit": "submit"}[a]
	switch str(interaction["kind"]) {
	case "mcp-elicitation":
		if a == "deny" || a == "cancel" {
			action := "decline"
			if a == "cancel" {
				action = "cancel"
			}
			return Map{"action": action, "content": nil, "_meta": nil}, resolution, nil
		}
		e := obj(interaction["elicitation"])
		if e["mode"] == "url" {
			return Map{"action": "accept", "content": Map{}, "_meta": nil}, resolution, nil
		}
		values := Map{}
		if !confirmationSchema(obj(e["requestedSchema"])) {
			encoded := str(obj(response["answers"])[str(e["questionId"])])
			if json.Unmarshal([]byte(encoded), &values) != nil || values == nil {
				return nil, "", errors.New("MCP form values 必须是 JSON 对象")
			}
		} else {
			resolution = "accept"
		}
		if grant := computerApproval(p); grant != nil {
			return grant, resolution, nil
		}
		return Map{"action": "accept", "content": values, "_meta": p["_meta"]}, resolution, nil
	case "user-input":
		answers := Map{}
		known := map[string]Map{}
		for _, v := range arr(interaction["questions"]) {
			q := obj(v)
			known[str(q["id"])] = q
		}
		for id, v := range obj(response["answers"]) {
			q, ok := known[id]
			if !ok {
				return nil, "", fmt.Errorf("unknown Codex question: %s", id)
			}
			vv := []any{}
			if s, ok := v.(string); ok {
				vv = []any{s}
			} else {
				vv = arr(v)
			}
			native := []string{}
			for _, x := range vv {
				s, ok := x.(string)
				if !ok {
					return nil, "", errors.New("Codex question answer must be text")
				}
				for _, o := range arr(q["options"]) {
					if obj(o)["id"] == s {
						s = str(obj(o)["label"])
						break
					}
				}
				native = append(native, s)
			}
			answers[id] = Map{"answers": native}
		}
		return Map{"answers": answers}, resolution, nil
	case "permissions":
		perms := Map{}
		if strings.HasPrefix(a, "allow") {
			perms = obj(p["permissions"])
		}
		scope := "turn"
		if a == "allow-session" {
			scope = "session"
		}
		return Map{"permissions": perms, "scope": scope}, resolution, nil
	default:
		return Map{"decision": resolution}, resolution, nil
	}
}
func DefaultInteractionDecline(method string) Map {
	switch method {
	case "item/permissions/requestApproval":
		return Map{"permissions": Map{}, "scope": "turn"}
	case "item/tool/requestUserInput":
		return Map{"answers": Map{}}
	case "mcpServer/elicitation/request":
		return Map{"action": "cancel", "content": nil, "_meta": nil}
	default:
		return Map{"decision": "cancel"}
	}
}
func computerApproval(p Map) Map {
	server := str(p["serverName"])
	if server != "cua_repl" && server != "node_repl" && server != "computer-use" {
		return nil
	}
	if m := str(p["mode"]); m != "" && m != "form" && m != "openai/form" {
		return nil
	}
	if !confirmationSchema(obj(p["requestedSchema"])) {
		return nil
	}
	meta := obj(p["_meta"])
	if meta["codex_approval_kind"] != "mcp_tool_call" || meta["connector_id"] != "computer-use" || strings.TrimSpace(str(meta["tool_name"])) == "" {
		return nil
	}
	args := obj(meta["tool_params"])
	if len(args) != 1 || strings.TrimSpace(str(args["app"])) == "" {
		return nil
	}
	persist := meta["persist"] == "session"
	for _, v := range arr(meta["persist"]) {
		if v == "session" {
			persist = true
		}
		if v != "session" && v != "always" {
			return nil
		}
	}
	if !persist {
		return nil
	}
	m := clone(meta)
	m["persist"] = "session"
	return Map{"action": "accept", "content": Map{}, "_meta": m}
}
