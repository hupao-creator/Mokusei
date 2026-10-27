package threadvoice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Root.Open prevents symlink/path traversal even if directory entries change
// between resolving the supplied path and opening it. No command/write tool is
// exposed to a discussion, including when the source task had those tools.
func ProjectReadTools(cwd string) ([]plugin.ToolBinding, func() error, error) {
	canonical, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return nil, nil, err
	}
	root, err := os.OpenRoot(canonical)
	if err != nil {
		return nil, nil, err
	}
	parse := func(raw json.RawMessage) (string, int64, error) {
		var args struct {
			Path   *string `json:"path"`
			Offset int64   `json:"offset"`
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&args); err != nil {
			return "", 0, err
		}
		if dec.Decode(&struct{}{}) != io.EOF || args.Path == nil || strings.ContainsRune(*args.Path, 0) || filepath.IsAbs(*args.Path) || args.Offset < 0 || args.Offset > 9007199254740991 {
			return "", 0, errors.New("use a project-relative path and a nonnegative safe byte offset")
		}
		p := *args.Path
		if p == "" {
			p = "."
		}
		return p, args.Offset, nil
	}
	schema := json.RawMessage(`{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":0}},"required":["path"],"additionalProperties":false}`)
	tools := []plugin.ToolBinding{
		{Name: "read_project_file", Description: "Read a UTF-8 project file, at most 32 KiB per call. Offset is in bytes.", InputSchema: schema, Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			path, offset, e := parse(call.Arguments)
			if e != nil {
				return nil, e
			}
			if e = ctx.Err(); e != nil {
				return nil, e
			}
			file, e := root.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
			if e != nil {
				return nil, e
			}
			defer file.Close()
			info, e := file.Stat()
			if e != nil {
				return nil, e
			}
			if !info.Mode().IsRegular() {
				return nil, errors.New("target is not a regular file")
			}
			buf := make([]byte, 32768)
			n, e := file.ReadAt(buf, offset)
			if e != nil && !errors.Is(e, io.EOF) {
				return nil, e
			}
			if e = ctx.Err(); e != nil {
				return nil, e
			}
			if offset > 0 && n > 0 && !utf8.RuneStart(buf[0]) {
				return nil, errors.New("offset must start at a UTF-8 character boundary")
			}
			// nextOffset is a byte cursor. Leave an incomplete final rune for
			// the next page instead of irreversibly replacing both halves.
			if n == len(buf) && offset+int64(n) < info.Size() {
				start := n - 1
				for start > 0 && !utf8.RuneStart(buf[start]) {
					start--
				}
				if !utf8.FullRune(buf[start:n]) {
					n = start
				}
			}
			if bytes.IndexByte(buf[:n], 0) >= 0 {
				return nil, errors.New("only text files may be read")
			}
			return json.Marshal(map[string]any{"text": strings.ToValidUTF8(string(buf[:n]), "�"), "nextOffset": offset + int64(n), "end": offset+int64(n) >= info.Size()})
		}},
		{Name: "list_project_directory", Description: "List one project directory. No shell commands are executed.", InputSchema: schema, Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			path, offset, e := parse(call.Arguments)
			if e != nil {
				return nil, e
			}
			if e = ctx.Err(); e != nil {
				return nil, e
			}
			file, e := root.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
			if e != nil {
				return nil, e
			}
			defer file.Close()
			entries, e := file.ReadDir(-1)
			if e != nil {
				return nil, e
			}
			if e = ctx.Err(); e != nil {
				return nil, e
			}
			sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
			start := min(offset, int64(len(entries)))
			end := min(start+200, int64(len(entries)))
			values := make([]map[string]any, 0, end-start)
			for _, entry := range entries[start:end] {
				values = append(values, map[string]any{"name": entry.Name(), "directory": entry.IsDir()})
			}
			return json.Marshal(map[string]any{"entries": values, "nextOffset": offset + (end - start), "end": offset+200 >= int64(len(entries))})
		}},
	}
	return tools, root.Close, nil
}
