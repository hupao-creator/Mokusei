// Package value validates required JSON fields before Go decoding, which on its
// own accepts missing fields and null scalars. Nullable fields use non-omitempty
// pointers; optional fields may be absent but cannot silently accept JSON null.
package value

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

var rawType = reflect.TypeOf(json.RawMessage{})

func Decode(raw json.RawMessage, out any) error {
	target := reflect.TypeOf(out)
	if target == nil || target.Kind() != reflect.Pointer {
		return fmt.Errorf("JSON destination must be a pointer")
	}
	decoded, err := model.Decode(raw)
	if err != nil {
		return err
	}
	if err = shape(target.Elem(), decoded, "value", false); err != nil {
		return err
	}
	return model.Unmarshal(raw, out)
}

type field struct {
	kind     reflect.Type
	optional bool
}

func fields(kind reflect.Type) map[string]field {
	result := map[string]field{}
	for i := 0; i < kind.NumField(); i++ {
		entry := kind.Field(i)
		if entry.PkgPath != "" {
			continue
		}
		tag := entry.Tag.Get("json")
		if tag == "-" {
			continue
		}
		if entry.Anonymous && tag == "" {
			embedded := entry.Type
			if embedded.Kind() == reflect.Pointer {
				embedded = embedded.Elem()
			}
			if embedded.Kind() == reflect.Struct {
				for name, value := range fields(embedded) {
					result[name] = value
				}
				continue
			}
		}
		parts := strings.Split(tag, ",")
		name := parts[0]
		if name == "" {
			name = entry.Name
		}
		optional := false
		for _, option := range parts[1:] {
			if option == "omitempty" {
				optional = true
			}
		}
		result[name] = field{entry.Type, optional}
	}
	return result
}
func shape(kind reflect.Type, data any, path string, nullable bool) error {
	if kind == rawType {
		return nil
	}
	if kind.Kind() == reflect.Pointer {
		if data == nil && nullable {
			return nil
		}
		return shape(kind.Elem(), data, path, false)
	}
	if data == nil {
		return fmt.Errorf("%s cannot be null", path)
	}
	switch kind.Kind() {
	case reflect.Struct:
		object, ok := data.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", path)
		}
		known := fields(kind)
		for name, child := range object {
			entry, ok := known[name]
			if !ok {
				return fmt.Errorf("unknown %s.%s", path, name)
			}
			if err := shape(entry.kind, child, path+"."+name, entry.kind.Kind() == reflect.Pointer && !entry.optional); err != nil {
				return err
			}
		}
		for name, entry := range known {
			if _, exists := object[name]; !exists && !entry.optional {
				return fmt.Errorf("missing %s.%s", path, name)
			}
		}
	case reflect.Map:
		object, ok := data.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", path)
		}
		for key, child := range object {
			if err := shape(kind.Elem(), child, path+"."+key, false); err != nil {
				return err
			}
		}
	case reflect.Slice, reflect.Array:
		array, ok := data.([]any)
		if !ok {
			return fmt.Errorf("%s must be an array", path)
		}
		for i, child := range array {
			if err := shape(kind.Elem(), child, fmt.Sprintf("%s[%d]", path, i), false); err != nil {
				return err
			}
		}
	case reflect.String:
		if _, ok := data.(string); !ok {
			return fmt.Errorf("%s must be a string", path)
		}
	case reflect.Bool:
		if _, ok := data.(bool); !ok {
			return fmt.Errorf("%s must be a boolean", path)
		}
	}
	return nil
}
