package pi

import (
	"context"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"os"
	"strings"
)

func inheritedEnvironment(ctx context.Context, host plugin.HostContext) (map[string]string, error) {
	env := map[string]string{}
	if host.Environment != nil {
		source, err := host.Environment(ctx)
		if err != nil {
			return nil, err
		}
		for k, v := range source {
			env[k] = v
		}
	} else {
		for _, pair := range os.Environ() {
			k, v, _ := strings.Cut(pair, "=")
			env[k] = v
		}
	}
	return env, nil
}

func readObject(path string) (model.Object, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return model.Object{}, nil
	}
	if err != nil {
		return nil, err
	}
	return model.DecodeObject(data)
}
