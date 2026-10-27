package codex

import (
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func WireInput(input model.AgentInput) ([]any, error) {
	out := []any{}
	for _, p := range input.Parts {
		var v Map
		switch p.Kind {
		case "text":
			v = Map{"type": "text", "text": p.Text, "text_elements": []any{}}
		case "skill":
			v = Map{"type": "skill", "name": p.Name, "path": p.Path}
		case "mention":
			v = filesystemReference(p.Name, p.Path, first(p.PathType, "unspecified"))
		case "image", "audio", "local-file":
			if p.File == nil || p.File.Path == "" {
				return nil, fmt.Errorf("%s attachment has no resolved path", p.Kind)
			}
			switch p.Kind {
			case "image":
				v = Map{"type": "localImage", "path": p.File.Path}
			case "audio":
				v = Map{"type": "localAudio", "path": p.File.Path}
			default:
				v = filesystemReference(p.File.Name, p.File.Path, "file")
			}
		case "image-url":
			v = Map{"type": "image", "url": p.URL}
		case "audio-url":
			v = Map{"type": "audio", "url": p.URL}
		default:
			return nil, fmt.Errorf("unsupported Codex input kind %q", p.Kind)
		}
		if p.Detail != "" && (p.Kind == "image" || p.Kind == "image-url") {
			v["detail"] = p.Detail
		}
		out = append(out, v)
	}
	return out, nil
}
func filesystemReference(name, path, kind string) Map {
	return Map{"type": "text", "text": "User-referenced filesystem entry: " + jsonText(Map{"name": name, "path": path, "kind": kind}), "text_elements": []any{}}
}
