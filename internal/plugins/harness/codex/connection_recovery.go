package codex

import (
	"errors"
	"fmt"
	"time"
)

const nativeRetryWindow = 60 * time.Second
const nativeRetryLimit = 5

// Retry errors are evidence of a broken transport, not execution progress.
// Only arm a recovery deadline after that evidence; healthy long tools and
// approval waits must never inherit a generic inactivity deadline.
func (n *NativeSession) retrying(message string) {
	n.mu.Lock()
	if n.terminal || n.closed {
		n.mu.Unlock()
		return
	}
	n.retryCount++
	if n.retryTimer == nil {
		n.retryGeneration++
		generation := n.retryGeneration
		n.retryTimer = time.AfterFunc(nativeRetryWindow, func() {
			n.mu.Lock()
			defer n.mu.Unlock()
			if generation == n.retryGeneration && !n.terminal && !n.closed {
				n.failRecoveryLocked()
			}
		})
	}
	if n.retryCount >= nativeRetryLimit {
		n.failRecoveryLocked()
		n.mu.Unlock()
		return
	}
	count := n.retryCount
	n.mu.Unlock()
	n.publish(Map{"type": "status", "label": fmt.Sprintf("Codex 连接中断，正在恢复（%d/%d，最多等待 60 秒）：%s", count, nativeRetryLimit, message)})
}

// Called under n.mu so progress and timeout cannot both win. fail only signals
// closure and schedules callbacks/cleanup; it never calls native handlers inline.
func (n *NativeSession) failRecoveryLocked() {
	message := "Codex 连接恢复失败，已停止本次任务。已发送的消息不会自动重发；请重新发送需要继续的请求。"
	n.failure = message
	n.clearRetryLocked()
	n.server.fail(errors.New(message))
}

func (n *NativeSession) clearRetryLocked() {
	if n.retryTimer != nil {
		n.retryTimer.Stop()
		n.retryTimer = nil
	}
	n.retryCount = 0
	n.retryGeneration++
}

func nativeProgress(method string, p Map) bool {
	switch method {
	case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/commandExecution/outputDelta":
		return str(p["delta"]) != ""
	case "item/started", "item/completed":
		i := obj(p["item"])
		return str(i["id"]) != "" && (i["type"] == "agentMessage" || i["type"] == "reasoning" || ParseActivity(i) != nil)
	case "item/mcpToolCall/progress":
		return str(p["message"]) != ""
	}
	return false
}
