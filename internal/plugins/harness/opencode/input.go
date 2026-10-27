package opencode

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const maxAttachmentBytes = 20 << 20

func supportedImageMIME(mime string) bool {
	switch strings.ToLower(mime) {
	case "image/png", "image/jpeg", "image/webp", "image/gif":
		return true
	}
	return false
}

type PreparedInput struct {
	Text, VisibleText string
	Files             []Object
	Modalities        []string
}

func PrepareInput(ctx context.Context, input model.AgentInput) (PreparedInput, error) {
	out := PreparedInput{Files: []Object{}}
	pieces, visible := []string{}, []string{}
	modalities := map[string]bool{}
	for _, p := range input.Parts {
		if err := ctx.Err(); err != nil {
			return out, err
		}
		switch p.Kind {
		case "text":
			pieces = append(pieces, p.Text)
			if p.AnnotationID == "" {
				visible = append(visible, p.Text)
			}
		case "audio", "audio-url":
			return out, errors.New("OpenCode 2 does not support audio input")
		case "image", "image-url":
			if p.Detail != "" && p.Detail != "auto" {
				return out, errors.New("OpenCode requires automatic image detail")
			}
			var data []byte
			var err error
			name := ""
			if p.Kind == "image" {
				if p.File == nil {
					return out, errors.New("missing image metadata")
				}
				if !supportedImageMIME(p.File.MimeType) {
					return out, fmt.Errorf("unsupported OpenCode image type: %s", p.File.MimeType)
				}
				if p.File.Size > maxAttachmentBytes {
					return out, errors.New("OpenCode images must be at most 20 MiB")
				}
				data, err = readBounded(p.File.Path)
				name = p.File.Name
			} else {
				data, err = downloadImage(ctx, p.URL)
			}
			if err != nil {
				return out, err
			}
			mime := detectImage(data)
			if mime == "" {
				return out, errors.New("OpenCode image content must be PNG, JPEG, WebP or GIF")
			}
			file := Object{"uri": "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)}
			if name != "" {
				file["name"] = name
			}
			out.Files = append(out.Files, file)
			modalities["image"] = true
			screenshot := false
			if p.File != nil {
				var annotations []Object
				_ = json.Unmarshal(input.Annotations, &annotations)
				for _, annotation := range annotations {
					if annotation["screenshotId"] == p.File.ID {
						screenshot = true
					}
				}
			}
			if !screenshot {
				if name != "" {
					visible = append(visible, "Attached image: "+name)
				} else if strings.HasPrefix(p.URL, "data:") {
					visible = append(visible, "Attached image")
				} else {
					visible = append(visible, "Attached image: "+p.URL)
				}
			}
		case "local-file":
			if p.File == nil {
				return out, errors.New("missing attachment metadata")
			}
			if p.File.MimeType == "application/pdf" {
				if p.File.Size > maxAttachmentBytes {
					return out, errors.New("OpenCode PDFs must be at most 20 MiB")
				}
				data, err := readBounded(p.File.Path)
				if err != nil {
					return out, err
				}
				if !bytes.HasPrefix(data, []byte("%PDF-")) {
					return out, errors.New("invalid PDF")
				}
				out.Files = append(out.Files, Object{"uri": "data:application/pdf;base64," + base64.StdEncoding.EncodeToString(data), "name": p.File.Name})
				modalities["pdf"] = true
			}
			ref, _ := json.Marshal(Object{"name": p.File.Name, "path": p.File.Path})
			pieces = append(pieces, "User-referenced file: "+string(ref))
			visible = append(visible, "Attached file: "+p.File.Name)
		default:
			ref, _ := json.Marshal(Object{"name": p.Name, "path": p.Path, "uri": (&url.URL{Scheme: "file", Path: p.Path}).String()})
			pieces = append(pieces, "User-referenced "+p.Kind+": "+string(ref))
			visible = append(visible, p.Name+": "+p.Path)
		}
	}
	out.Text = strings.Join(pieces, "\n\n")
	out.VisibleText = strings.Join(visible, "\n\n")
	for _, kind := range []string{"image", "pdf"} {
		if modalities[kind] {
			out.Modalities = append(out.Modalities, kind)
		}
	}
	return out, nil
}
func readBounded(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxAttachmentBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) == 0 || len(b) > maxAttachmentBytes {
		return nil, errors.New("invalid or oversized attachment")
	}
	return b, nil
}
func downloadImage(ctx context.Context, value string) ([]byte, error) {
	u, err := url.Parse(value)
	if err != nil {
		return nil, err
	}
	if u.Scheme == "data" {
		header, encoded, ok := strings.Cut(value, ",")
		if !ok || !strings.HasSuffix(header, ";base64") || len(encoded) > (maxAttachmentBytes+2)/3*4 {
			return nil, errors.New("invalid data image")
		}
		mime := strings.TrimSuffix(strings.TrimPrefix(header, "data:"), ";base64")
		if !supportedImageMIME(mime) {
			return nil, errors.New("unsupported data image")
		}
		b, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if err != nil || len(b) == 0 || len(b) > maxAttachmentBytes || base64.StdEncoding.EncodeToString(b) != encoded {
			return nil, errors.New("invalid or oversized data image")
		}
		return b, nil
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, errors.New("unsupported image URL")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", value, nil)
	if err != nil {
		return nil, err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, fmt.Errorf("image download failed (%d)", res.StatusCode)
	}
	if res.ContentLength > maxAttachmentBytes {
		return nil, errors.New("image exceeds 20 MiB")
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, maxAttachmentBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) == 0 || len(b) > maxAttachmentBytes {
		return nil, errors.New("empty or oversized image")
	}
	return b, nil
}
func detectImage(b []byte) string {
	switch {
	case bytes.HasPrefix(b, []byte{137, 80, 78, 71, 13, 10, 26, 10}):
		return "image/png"
	case bytes.HasPrefix(b, []byte{255, 216, 255}):
		return "image/jpeg"
	case bytes.HasPrefix(b, []byte("GIF87a")) || bytes.HasPrefix(b, []byte("GIF89a")):
		return "image/gif"
	case len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	}
	return ""
}
func decodeJSON[T ~[]byte](b T, out any) error { return json.Unmarshal(b, out) }
