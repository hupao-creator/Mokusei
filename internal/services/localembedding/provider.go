package localembedding

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Options struct {
	Directory string
	Trace     func(plugin.SearchDiagnostic)
	// Tests provide tiny synthetic, hash-verified assets and a loopback download
	// client. Production composition supplies Directory and the diagnostic sink.
	Assets       *Assets
	DownloadHTTP *http.Client
	IdleTimeout  time.Duration
}
type Provider struct {
	trace              func(plugin.SearchDiagnostic)
	directory          string
	assets             Assets
	downloadHTTP       *http.Client
	idleTimeout        time.Duration
	mu, filesMu, runMu sync.Mutex
	// Serialize explicit asset actions through their joined completion. An
	// overlapping download must not be swallowed by a removal being cancelled.
	assetMu            sync.Mutex
	setup              plugin.EmbeddingSetupStatus
	verified           bool
	executable         string
	closed             bool
	installCancel      context.CancelFunc
	installDone        chan struct{}
	serverCancel       context.CancelFunc
	serverDone         chan struct{}
	address, token     string
	instance           string
	processOperationID string
	idle               *time.Timer
	serverErr          error
	cleanupErr         error
	poisoned           atomic.Bool
	lastUse            time.Time
	http               *http.Client
}

func New(options Options) *Provider {
	assets := pinnedAssets()
	if options.Assets != nil {
		assets = *options.Assets
	}
	client := options.DownloadHTTP
	if client == nil {
		client = downloadClient()
	}
	idle := options.IdleTimeout
	if idle <= 0 {
		idle = 2 * time.Minute
	}
	// Inference ignores HTTP_PROXY / HTTPS_PROXY and cannot dial any other host
	// or follow redirects. Downloads use a separate, GET-only path.
	transport := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(address)
		if err != nil || host != "127.0.0.1" {
			return nil, errors.New("nonlocal embedding connection refused")
		}
		return (&net.Dialer{Timeout: time.Second}).DialContext(ctx, network, address)
	}}
	return &Provider{trace: options.Trace, directory: filepath.Join(options.Directory, "embeddinggemma-2"), assets: assets, downloadHTTP: client, idleTimeout: idle,
		setup: plugin.EmbeddingSetupStatus{Supported: assets.Runtime.URL != "", TotalBytes: assets.Model.Bytes + assets.Runtime.Bytes},
		http:  &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}
func (*Provider) Model() string { return Model }
func (p *Provider) Available(ctx context.Context) bool {
	p.mu.Lock()
	closed, downloading := p.closed, p.setup.Downloading
	p.mu.Unlock()
	return !closed && !downloading && !p.poisoned.Load() && p.verify(ctx)
}
func (p *Provider) SetupStatus() plugin.EmbeddingSetupStatus {
	p.mu.Lock()
	s := p.setup
	p.mu.Unlock()
	p.filesMu.Lock()
	s.Ready = p.verified && !p.poisoned.Load()
	p.filesMu.Unlock()
	return s
}
func (p *Provider) Download(ctx context.Context) error {
	p.assetMu.Lock()
	defer p.assetMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return &plugin.EmbeddingError{Code: "local-unavailable"}
	}
	if p.poisoned.Load() {
		return &plugin.EmbeddingError{Code: "cleanup"}
	}
	if !p.setup.Supported {
		return &plugin.EmbeddingError{Code: "unsupported"}
	}
	if p.setup.Downloading {
		return nil
	}
	// Downloads have their own lifetime so closing settings does not leave an
	// ambiguous command. Explicit cancel and runtime shutdown cancel and join.
	life, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	p.installCancel = cancel
	p.installDone = make(chan struct{})
	done := p.installDone
	p.setup.Downloading = true
	p.setup.DownloadedBytes = 0
	p.setup.Reason = ""
	_, operationID := plugin.SearchOperation(life)
	go func() {
		started := time.Now()
		p.emit(plugin.SearchDiagnostic{Event: "embedding.download.started", OperationID: operationID})
		err := p.install(life)
		event := plugin.SearchDiagnostic{Event: "embedding.download.completed", OperationID: operationID, DurationMS: plugin.SearchDuration(started), Outcome: "completed"}
		if err != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(err)
			if event.Reason == "internal" {
				event.Reason = "download-failed"
			}
		}
		p.emit(event)
		cancel()
		p.mu.Lock()
		p.setup.Downloading = false
		if err != nil {
			p.setup.Reason = "download-failed"
			if errors.Is(err, context.Canceled) {
				p.setup.Reason = "cancelled"
			}
			if p.poisoned.Load() {
				p.setup.Reason = "cleanup"
			}
		}
		p.mu.Unlock()
		close(done)
	}()
	return nil
}
func (p *Provider) CancelDownload() {
	p.assetMu.Lock()
	defer p.assetMu.Unlock()
	p.cancelDownload()
}
func (p *Provider) cancelDownload() {
	p.mu.Lock()
	cancel, done := p.installCancel, p.installDone
	p.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}
}
func (p *Provider) Remove() error {
	p.assetMu.Lock()
	defer p.assetMu.Unlock()
	p.cancelDownload()
	p.runMu.Lock()
	defer p.runMu.Unlock()
	if err := p.stop(); err != nil {
		return err
	}
	p.filesMu.Lock()
	defer p.filesMu.Unlock()
	p.verified = false
	p.executable = ""
	return os.RemoveAll(p.directory)
}
func (p *Provider) request(ctx context.Context, path string, body []byte) ([]byte, error) {
	method := "POST"
	if body == nil {
		method = "GET"
	}
	req, err := http.NewRequestWithContext(ctx, method, p.address+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.token)
	req.Header.Set("Content-Type", "application/json")
	response, err := p.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return nil, &plugin.EmbeddingError{Code: "local-unavailable"}
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 128*1024+1))
	if err != nil || len(raw) > 128*1024 {
		return nil, &plugin.EmbeddingError{Code: "response"}
	}
	return raw, nil
}
func (p *Provider) start(ctx context.Context) (err error) {
	if p.serverDone != nil {
		select {
		case <-p.serverDone:
			if err := p.stop(); err != nil {
				return err
			}
		default:
			return nil
		}
	}
	if !p.Available(ctx) {
		return &plugin.EmbeddingError{Code: "model-missing"}
	}
	started := time.Now()
	_, operationID := plugin.SearchOperation(ctx)
	defer func() {
		event := plugin.SearchDiagnostic{Event: "embedding.process.start.completed", OperationID: operationID, DurationMS: plugin.SearchDuration(started), Outcome: "completed"}
		if err != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(err)
		}
		p.emit(event)
	}()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	nonce := make([]byte, 48)
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	p.token = hex.EncodeToString(nonce[:32])
	p.instance = "oa-embedding-" + hex.EncodeToString(nonce[32:])
	p.address = "http://127.0.0.1:" + strconv.Itoa(port)
	life, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	p.serverCancel = cancel
	p.serverDone = done
	p.processOperationID = operationID
	args := []string{"--model", filepath.Join(p.directory, "text.gguf"), "--alias", p.instance, "--host", "127.0.0.1", "--port", strconv.Itoa(port),
		"--embedding", "--pooling", "mean", "--ctx-size", "8192", "--batch-size", "8192", "--ubatch-size", "8192",
		"--parallel", "1", "--threads", "4", "--threads-batch", "4", "--n-gpu-layers", "all", "--offline", "--no-webui", "--no-slots", "--log-disable"}
	// Do not inherit provider credentials, proxy configuration, native profiles
	// or a user-controlled llama argument environment. The random local token
	// is never in argv, persisted state, diagnostics or model input.
	env := []string{"PATH=/usr/bin:/bin", "HOME=" + p.directory, "TMPDIR=" + os.TempDir(), "LLAMA_API_KEY=" + p.token}
	p.filesMu.Lock()
	executable := p.executable
	p.filesMu.Unlock()
	go func() {
		_, err := processgroup.Run(life, executable, args, p.directory, env, 64*1024)
		p.serverErr = err
		close(done)
	}()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			p.stop()
			return ctx.Err()
		case <-done:
			p.stop()
			return &plugin.EmbeddingError{Code: "local-unavailable"}
		case <-ticker.C:
			probe, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
			raw, err := p.request(probe, "/health", nil)
			cancel()
			var health struct {
				Status string `json:"status"`
			}
			if err == nil && json.Unmarshal(raw, &health) == nil && health.Status == "ok" {
				identity, identifyErr := p.request(ctx, "/v1/models", nil)
				var models struct {
					Data []struct {
						ID string `json:"id"`
					} `json:"data"`
				}
				if identifyErr != nil || json.Unmarshal(identity, &models) != nil || len(models.Data) != 1 || models.Data[0].ID != p.instance {
					continue
				}
				// A port can be claimed between choosing it and exec. Do not send
				// any thread text until the fresh per-process alias also matches.
				p.mu.Lock()
				p.setup.Loaded = true
				p.mu.Unlock()
				select {
				case <-done:
					p.stop()
					return &plugin.EmbeddingError{Code: "local-unavailable"}
				default:
					return nil
				}
			}
		}
	}
}
func (p *Provider) stop() error {
	started := time.Now()
	hadProcess := p.serverDone != nil
	p.mu.Lock()
	p.setup.Loaded = false
	p.mu.Unlock()
	if p.idle != nil {
		p.idle.Stop()
		p.idle = nil
	}
	if p.serverCancel != nil {
		p.serverCancel()
	}
	if p.serverDone != nil {
		<-p.serverDone
		if errors.Is(p.serverErr, processgroup.ErrCleanup) {
			p.cleanupErr = &plugin.EmbeddingError{Code: "cleanup"}
			p.poisoned.Store(true)
			p.mu.Lock()
			p.setup.Reason = "cleanup"
			p.mu.Unlock()
		}
	}
	p.serverCancel = nil
	p.serverDone = nil
	p.address = ""
	p.token = ""
	p.instance = ""
	if hadProcess {
		event := plugin.SearchDiagnostic{Event: "embedding.process.stopped", OperationID: p.processOperationID, DurationMS: plugin.SearchDuration(started), Outcome: "completed"}
		if p.cleanupErr != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(p.cleanupErr)
		}
		p.emit(event)
		p.processOperationID = ""
	}
	return p.cleanupErr
}
func (p *Provider) Release() error { p.runMu.Lock(); defer p.runMu.Unlock(); return p.stop() }
func (p *Provider) Close() error {
	p.assetMu.Lock()
	defer p.assetMu.Unlock()
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()
	p.cancelDownload()
	if err := p.Release(); err != nil {
		return err
	}
	p.http.CloseIdleConnections()
	return nil
}
func (p *Provider) Embed(ctx context.Context, text string, dimensions int) (vector []float32, err error) {
	ctx, id := plugin.SearchOperation(ctx)
	started := time.Now()
	event := plugin.SearchDiagnostic{Event: "embedding.inference.completed", OperationID: id, InputBytes: len(text)}
	defer func() {
		event.DurationMS = plugin.SearchDuration(started)
		event.Outcome = "completed"
		if err != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(err)
		}
		p.emit(event)
	}()
	// One owner, one sequence, one pooled vector. No shared native generation
	// context or HTTP server supplied by the user is ever borrowed.
	p.runMu.Lock()
	event.QueueMS = plugin.SearchDuration(started)
	event.ColdStart = p.serverDone == nil
	if p.serverDone != nil {
		select {
		case <-p.serverDone:
			event.ColdStart = true
		default:
		}
	}
	defer p.runMu.Unlock()
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if closed {
		return nil, &plugin.EmbeddingError{Code: "local-unavailable"}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if dimensions != 768 || len([]byte(text)) > 8000 {
		return nil, &plugin.EmbeddingError{Code: "input-limit"}
	}
	if p.idle != nil {
		p.idle.Stop()
	}
	if err := p.start(ctx); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &plugin.EmbeddingError{Code: "local-unavailable"}
	}
	body, _ := json.Marshal(map[string]any{"model": Model, "input": text, "encoding_format": "float"})
	raw, err := p.request(ctx, "/v1/embeddings", body)
	p.lastUse = time.Now()
	p.idle = time.AfterFunc(p.idleTimeout, func() {
		p.runMu.Lock()
		defer p.runMu.Unlock()
		if time.Since(p.lastUse) >= p.idleTimeout {
			p.stop()
		}
	})
	if err != nil {
		// Closing the owned process cancels compute even when a backend has
		// not yet observed its client's disconnected request.
		p.stop()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &plugin.EmbeddingError{Code: "local-unavailable"}
	}
	var result struct {
		Data []struct {
			Index     int       `json:"index"`
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
	}
	if json.Unmarshal(raw, &result) != nil || len(result.Data) != 1 || result.Data[0].Index != 0 || len(result.Data[0].Embedding) != dimensions {
		return nil, &plugin.EmbeddingError{Code: "response"}
	}
	vector = result.Data[0].Embedding
	var norm float64
	for _, v := range vector {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			return nil, &plugin.EmbeddingError{Code: "response"}
		}
		norm += float64(v) * float64(v)
	}
	if norm < 1e-12 {
		return nil, &plugin.EmbeddingError{Code: "response"}
	}
	norm = math.Sqrt(norm)
	for i := range vector {
		vector[i] /= float32(norm)
	}
	return vector, nil
}

func (p *Provider) emit(event plugin.SearchDiagnostic) {
	if p.trace != nil {
		p.trace(event)
	}
}
