package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// Export real Coordinator tool audit records for the native production replay.
// The Harness and workspace are isolated fixtures; the tool binding and its
// validation, completion and transcript writes are the production Go code.
func exportNativeTalkRecords() error {
	path := os.Getenv("MOKU_TALK_NATIVE_FIXTURE")
	if path == "" {
		return nil
	}
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("native talk replay")))
	texts := []string{
		"已经收到。",
		"找到原因了。\n我会继续检查。",
		"检查已完成。\n筛选条件已同步。\n相关视图也已检查。\n可以继续下一步。",
		strings.Join([]string{
			"检查完成。", "", "消息在 Moku 内部居中显示。",
			"最多显示四行，可滚动阅读全文。", "", "输入期间暂存新消息。",
			"保留焦点、草稿、附件和选区。", "", "结束编辑后展示最新消息。",
			"旧消息不会因刷新重现。", "", "检查完成：这就是消息的结尾。",
		}, "\n"),
	}
	var records []model.ThreadRecord
	for _, text := range texts {
		result, err := w.call("talk", string(mokuReplayRaw(map[string]string{"text": text})))
		if err != nil {
			return err
		}
		var response struct {
			OK bool `json:"ok"`
		}
		if err := json.Unmarshal(result, &response); err != nil || !response.OK {
			return fmt.Errorf("talk did not acknowledge delivery: %s", result)
		}
		records = append(records, w.mokuRecord())
	}
	dispatchRecords, err := nativeDispatchRecords()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(map[string]any{
		"source":  "production Moku.Coordinator talk binding; isolated mock Harness, no live account",
		"records": records, "texts": texts,
		"dispatchRecords": dispatchRecords,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	fmt.Println("PASS exported real talk tool audit records for native replay:", path)
	return nil
}
