package devtool

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
)

const uiResourceBundle = "MokuseiNative_MokuseiPluginUI.bundle"

func requiredResource(root, name, subdir string) ([]byte, error) {
	paths := []string{filepath.Join(root, name)}
	if subdir != "" {
		paths = append(paths, filepath.Join(root, subdir, name))
	}
	for _, path := range paths {
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() == 0 {
			return nil, fmt.Errorf("invalid packaged resource %s", path)
		}
		return os.ReadFile(path)
	}
	return nil, fmt.Errorf("missing packaged resource %s in %s", name, root)
}
func validatePackagedResources(app string) error {
	resources := filepath.Join(app, "Contents/Resources")
	bundle := filepath.Join(resources, uiResourceBundle)
	info, err := os.Lstat(bundle)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("packaged UI resources must be an embedded directory")
	}
	shader, err := requiredResource(bundle, "CloudLoading-macosx.metallib", "")
	if err != nil {
		return err
	}
	if len(shader) < 4 || string(shader[:4]) != "MTLB" {
		return fmt.Errorf("invalid packaged cloud Metal library")
	}
	fonts := []string{"inter-latin-wght-normal.ttf", "jetbrains-mono-latin-wght-normal.ttf"}
	for _, subset := range []string{"cyrillic-ext", "cyrillic", "greek", "vietnamese", "latin-ext"} {
		fonts = append(fonts, "jetbrains-mono-"+subset+"-wght-normal.ttf")
	}
	for _, name := range fonts {
		data, err := requiredResource(bundle, name, "fonts")
		if err != nil {
			return err
		}
		if len(data) < 12 || (binary.BigEndian.Uint32(data[:4]) != 0x00010000 && binary.BigEndian.Uint32(data[:4]) != 0x4f54544f) || binary.BigEndian.Uint16(data[4:6]) == 0 {
			return fmt.Errorf("invalid packaged OpenType font %s", name)
		}
	}
	data, err := requiredResource(bundle, "lucide-paths.json", "icons")
	if err != nil {
		return err
	}
	var icons map[string][]struct {
		Op     string    `json:"op"`
		Values []float64 `json:"values"`
	}
	if err = json.Unmarshal(data, &icons); err != nil {
		return err
	}
	if len(icons) != 141 {
		return fmt.Errorf("packaged Lucide catalog must contain 141 icons")
	}
	arity := map[string]int{"M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0, "E": 4, "R": 6, "A": 7}
	for name, commands := range icons {
		if len(commands) == 0 {
			return fmt.Errorf("empty icon %s", name)
		}
		for _, command := range commands {
			n, ok := arity[command.Op]
			if !ok || len(command.Values) != n {
				return fmt.Errorf("invalid icon geometry %s", name)
			}
			for _, value := range command.Values {
				if math.IsInf(value, 0) || math.IsNaN(value) {
					return fmt.Errorf("nonfinite icon geometry %s", name)
				}
			}
		}
	}
	for _, item := range [][2]string{{"inter-LICENSE.txt", "fonts"}, {"jetbrains-mono-LICENSE.txt", "fonts"}, {"lucide-LICENSE.txt", "icons"}} {
		if _, err = requiredResource(bundle, item[0], item[1]); err != nil {
			return err
		}
	}
	data, err = requiredResource(resources, "AppIcon.icns", "")
	if err != nil {
		return err
	}
	if len(data) < 8 || string(data[:4]) != "icns" || int(binary.BigEndian.Uint32(data[4:8])) != len(data) {
		return fmt.Errorf("invalid application icon")
	}
	for _, name := range []string{"Go-LICENSE", "LiveKitWebRTC-LICENSE"} {
		if _, err = requiredResource(filepath.Join(resources, "licenses"), name, ""); err != nil {
			return err
		}
	}
	return nil
}
