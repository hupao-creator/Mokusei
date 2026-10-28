package codex

import "strings"

func DecodeNotification(method string, p Map) []Map {
	switch method {
	case "item/plan/delta":
		return []Map{{"type": "status", "label": "正在制定计划"}}
	case "turn/plan/updated":
		r := Map{"type": "plan", "steps": arr(p["plan"])}
		if p["explanation"] != nil {
			r["explanation"] = p["explanation"]
		}
		return []Map{r}
	case "turn/diff/updated":
		return []Map{{"type": "diff", "diff": str(p["diff"])}}
	case "item/started":
		if obj(p["item"])["type"] != "agentMessage" {
			if a := ParseActivity(obj(p["item"])); a != nil {
				return []Map{{"type": "activity-start", "activity": a}}
			}
			return []Map{}
		}
	case "item/mcpToolCall/progress":
		return []Map{{"type": "activity-update", "activityId": str(p["itemId"]), "detail": first(str(p["message"]), compact(p), "运行中")}}
	case "hook/started", "hook/completed":
		r := obj(p["run"])
		if str(r["id"]) == "" {
			return []Map{}
		}
		if method == "hook/started" {
			return []Map{{"type": "activity-start", "activity": Map{"id": r["id"], "kind": "hook", "label": first(str(r["name"]), "运行 Hook"), "status": "running"}}}
		}
		status := "completed"
		if r["status"] == "failed" {
			status = "failed"
		}
		return []Map{{"type": "activity-end", "activityId": r["id"], "status": status, "detail": compact(r)}}
	case "thread/tokenUsage/updated":
		u := obj(p["tokenUsage"])
		last := obj(u["last"])
		usage := present(last, "inputTokens", "cachedInputTokens", "outputTokens")
		if v := last["reasoningOutputTokens"]; v != nil {
			usage["reasoningTokens"] = v
		}
		if v := u["modelContextWindow"]; v != nil {
			usage["contextWindow"] = v
		}
		return []Map{{"type": "usage", "usage": usage}}
	case "warning", "configWarning", "guardianWarning":
		return []Map{{"type": "warning", "message": first(str(p["message"]), str(p["summary"]), compact(p), "Codex 警告")}}
	}
	return nil
}
func ParseActivity(i Map) Map {
	id := str(i["id"])
	if id == "" {
		return nil
	}
	r := Map{"id": id, "status": "running"}
	switch i["type"] {
	case "commandExecution":
		r["kind"] = "command"
		r["label"] = first(str(i["command"]), "运行命令")
		r["detail"] = str(i["cwd"])
	case "fileChange":
		r["kind"] = "file"
		r["label"] = "修改文件"
		r["detail"] = compact(i["changes"])
		if paths := activityFilePaths(i); paths != nil {
			r["filePaths"] = paths
		}
	case "mcpToolCall", "dynamicToolCall":
		r["kind"] = "tool"
		r["label"] = first(str(i["tool"]), "调用 Mokusei 工具")
		r["toolName"] = str(i["tool"])
		if i["type"] == "mcpToolCall" {
			r["label"] = str(i["server"]) + " / " + str(i["tool"])
			r["toolName"] = str(i["server"]) + "/" + str(i["tool"])
		}
		r["detail"] = compact(i["arguments"])
	case "webSearch":
		r["kind"] = "search"
		r["label"] = first(str(i["query"]), "搜索网络")
		r["detail"] = compact(i["action"])
	case "imageView":
		r["kind"] = "tool"
		r["label"] = "查看图片"
		r["detail"] = str(i["path"])
	case "imageGeneration":
		r["kind"] = "tool"
		r["label"] = "生成图片"
		r["detail"] = compact(i)
	case "enteredReviewMode", "exitedReviewMode":
		r["kind"] = "review"
		r["label"] = "代码审查"
		r["detail"] = str(i["review"])
	case "collabAgentToolCall", "subAgentActivity":
		r["kind"] = "subagent"
		r["toolCall"] = i["type"] == "collabAgentToolCall"
		r["label"] = "协作 Agent：" + first(str(i["tool"]), str(i["kind"]))
		r["detail"] = compact(i)
	default:
		return nil
	}
	return r
}
func CompletedActivity(i Map) Map {
	if ParseActivity(i) == nil {
		return nil
	}
	status := "completed"
	if i["status"] == "cancelled" || i["status"] == "interrupted" {
		status = "cancelled"
	} else if i["status"] == "failed" || i["status"] == "declined" || i["success"] == false || i["error"] != nil {
		status = "failed"
	}
	detail := compact(i)
	switch i["type"] {
	case "commandExecution":
		detail = tail(str(i["aggregatedOutput"]), 32*1024)
	case "fileChange":
		detail = compact(i["changes"])
	case "mcpToolCall", "dynamicToolCall":
		detail = compact(i["result"])
		if detail == "" {
			detail = compact(i["error"])
		}
	}
	event := Map{"type": "activity-end", "activityId": str(i["id"]), "status": status, "detail": detail}
	if i["type"] == "fileChange" {
		event["filePaths"] = activityFilePaths(i)
	}
	return event
}
func validMessageID(id string) bool {
	return id != "" && id == strings.TrimSpace(id) && len(id) <= 1024 && !strings.ContainsRune(id, 0)
}

func activityFilePaths(item Map) []any {
	changes := arr(item["changes"])
	if len(changes) == 0 {
		return nil
	}
	paths := []any{}
	seen := map[string]bool{}
	bytes := 0
	for _, change := range changes {
		path := str(obj(change)["path"])
		if path == "" || strings.ContainsRune(path, 0) {
			return nil
		}
		if !seen[path] {
			bytes += len(path)
			// Retain bounded identity facts rather than a truncated file count.
			// An oversized native activity is displayed with an unknown count.
			if bytes > stMaxDetail {
				return nil
			}
			seen[path] = true
			paths = append(paths, path)
		}
	}
	return paths
}
