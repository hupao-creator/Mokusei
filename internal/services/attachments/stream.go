package attachments

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// StageStream accepts one bounded, checksummed upload. It deliberately does not
// hold the repository lock while the remote peer produces bytes: existing
// conversation sends and previews remain available during a slow upload.
func (r *Repository) StageStream(ctx context.Context, name string, size int64, digest string, source io.Reader) (model.Attachment, error) {
	if len(name) > 4096 || !hashPattern.MatchString(digest) || source == nil {
		return model.Attachment{}, errors.New("无效的附件传输元数据")
	}
	if err := ctx.Err(); err != nil {
		return model.Attachment{}, err
	}
	r.mu.Lock()
	err := os.MkdirAll(r.root, 0700)
	if err == nil {
		err = os.Chmod(r.root, 0700)
	}
	if err == nil {
		var owners map[string][]string
		owners, err = r.readOwners()
		if err == nil {
			err = r.writeOwners(owners)
		}
	}
	r.mu.Unlock()
	if err != nil {
		return model.Attachment{}, err
	}
	return r.stageReader(ctx, name, filepath.Ext(name), MimeTypeForPath(name), size, digest, source, nil)
}
