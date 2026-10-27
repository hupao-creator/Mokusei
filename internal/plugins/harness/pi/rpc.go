package pi

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxRPCLineBytes   = 8 * 1024 * 1024
	rpcRequestTimeout = 30 * time.Second
	rpcStartupTimeout = 15 * time.Second
	versionCacheTTL   = 5 * time.Minute
)

type ProcessOptions struct {
	ExecutablePath string
	Cwd            string
	Env            map[string]string
	Args           []string
	Bridge         *BridgeOptions
}

type versionProbe struct {
	at      time.Time
	done    chan struct{}
	version string
	err     error
}

var piVersions = struct {
	sync.Mutex
	entries map[string]*versionProbe
}{entries: map[string]*versionProbe{}}

// RetireVersions invalidates probes when discovery learns that the executable
// may have been replaced in place. Failed probes are never cached.
func RetireVersions() {
	piVersions.Lock()
	piVersions.entries = map[string]*versionProbe{}
	piVersions.Unlock()
}

func piEnvironment(env map[string]string) []string {
	if env == nil {
		result := os.Environ()
		sort.Strings(result)
		return result
	}
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+env[key])
	}
	return result
}

// GetVersion coalesces concurrent probes by executable, directory and full
// environment. Cancelling one waiter does not cancel a shared probe.
func GetVersion(ctx context.Context, options ProcessOptions) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", fmt.Errorf("Pi CLI version probe cancelled: %w", err)
	}
	env := piEnvironment(options.Env)
	digest := sha256.Sum256([]byte(options.ExecutablePath + "\x00" + options.Cwd + "\x00" + strings.Join(env, "\n")))
	key := hex.EncodeToString(digest[:])
	piVersions.Lock()
	entry := piVersions.entries[key]
	if entry == nil || time.Since(entry.at) >= versionCacheTTL {
		entry = &versionProbe{at: time.Now(), done: make(chan struct{})}
		piVersions.entries[key] = entry
		go func(entry *versionProbe) {
			entry.version, entry.err = probeVersion(options.ExecutablePath, options.Cwd, env)
			piVersions.Lock()
			if entry.err != nil && piVersions.entries[key] == entry {
				delete(piVersions.entries, key)
			}
			close(entry.done)
			piVersions.Unlock()
		}(entry)
	}
	piVersions.Unlock()
	select {
	case <-ctx.Done():
		return "", fmt.Errorf("Pi CLI version probe cancelled: %w", ctx.Err())
	case <-entry.done:
		return entry.version, entry.err
	}
}

type cappedBuffer struct {
	bytes.Buffer
	limit    int
	exceeded bool
	stop     func()
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		b.exceeded = true
		if b.stop != nil {
			b.stop()
		}
		return 0, fmt.Errorf("Pi CLI version probe exceeded output limit")
	}
	return b.Buffer.Write(p)
}

var stableVersion = regexp.MustCompile(`^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$`)

// diagnosticTail keeps the last credential-free diagnostic lines a child wrote
// to stderr. A rejected --provider or model surfaces only there, so the terminal
// process error can name the cause instead of just the exit status. Raw stderr
// is never forwarded: it can carry credentials and is persisted with the error.
type diagnosticTail struct {
	mu      sync.Mutex
	lines   []string
	partial string
	limit   int
}

func (t *diagnosticTail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	text := t.partial + string(p)
	t.partial = ""
	for {
		index := strings.IndexByte(text, '\n')
		if index < 0 {
			break
		}
		t.appendLocked(text[:index])
		text = text[index+1:]
	}
	if len(text) > t.limit {
		text = text[len(text)-t.limit:]
	}
	t.partial = text
	return len(p), nil
}

func (t *diagnosticTail) appendLocked(raw string) {
	line, ok := diagnosticLine(raw)
	if !ok {
		return
	}
	t.lines = append(t.lines, line)
	for {
		total := 0
		for _, kept := range t.lines {
			total += len(kept) + 1
		}
		if total <= t.limit {
			return
		}
		t.lines = t.lines[1:]
	}
}

func (t *diagnosticTail) message() string {
	t.mu.Lock()
	lines := append([]string(nil), t.lines...)
	partial, ok := diagnosticLine(t.partial)
	t.mu.Unlock()
	if ok {
		lines = append(lines, partial)
	}
	value := strings.Join(lines, " ")
	if runes := []rune(value); len(runes) > 512 {
		value = "..." + string(runes[len(runes)-512:])
	}
	return value
}

var diagnosticCredential = regexp.MustCompile(`(?i)\b(authorization|bearer|token|api[ _-]?key|access[ _-]?key|secret|password|cookie|credential)\b\s*[:=]?\s*\S*`)
var diagnosticOpaque = regexp.MustCompile(`\b(sk-[A-Za-z0-9_-]{6,}|[A-Za-z0-9_-]{32,})\b`)

// diagnosticLine redacts credential-shaped content and keeps only lines that
// read as a Harness diagnostic. Unknown content is discarded, never guessed.
func diagnosticLine(raw string) (string, bool) {
	line := strings.Join(strings.Fields(raw), " ")
	if line == "" {
		return "", false
	}
	line = diagnosticCredential.ReplaceAllString(line, "$1 [redacted]")
	line = diagnosticOpaque.ReplaceAllString(line, "[redacted]")
	lower := strings.ToLower(line)
	for _, marker := range []string{"unknown provider", "unknown model", "invalid provider", "invalid model", "unsupported model", "not found", "not logged in", "not available", "unavailable"} {
		if strings.Contains(lower, marker) {
			return line, true
		}
	}
	for _, prefix := range []string{"error", "fatal", "panic", "failed", "cannot", "could not", "unable", "no such"} {
		if strings.HasPrefix(lower, prefix) {
			return line, true
		}
	}
	return "", false
}

func probeVersion(executable, cwd string, env []string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), rpcStartupTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "--version")
	cmd.Dir, cmd.Env = cwd, env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killProcessGroup(cmd, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	stdout := &cappedBuffer{limit: 1024, stop: cancel}
	stderr := &cappedBuffer{limit: 1024, stop: cancel}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	if stdout.exceeded || stderr.exceeded {
		return "", fmt.Errorf("Pi CLI version probe exceeded the 1024-byte output limit")
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "", fmt.Errorf("Pi CLI version probe timed out after 15000 ms; retry when the CLI can start")
	}
	if err != nil {
		var exit *exec.ExitError
		switch {
		case errors.As(err, &exit):
			return "", fmt.Errorf("Pi CLI version probe exited with code %d", exit.ExitCode())
		case errors.Is(err, os.ErrNotExist):
			return "", fmt.Errorf("Pi CLI version probe could not start: executable or working directory is missing")
		case errors.Is(err, os.ErrPermission):
			return "", fmt.Errorf("Pi CLI version probe could not start: permission denied")
		default:
			return "", fmt.Errorf("Pi CLI version probe could not start: %w", err)
		}
	}
	version := strings.TrimSpace(stdout.String())
	parts := stableVersion.FindStringSubmatch(version)
	if len(parts) != 4 {
		return "", fmt.Errorf("Pi CLI returned an unrecognized or prerelease version; Mokusei requires a stable Pi release >= 0.83.0. Check pi --version")
	}
	numbers := make([]int64, 3)
	for i, part := range parts[1:] {
		n, err := strconv.ParseInt(part, 10, 64)
		if err != nil || n > 9007199254740991 {
			return "", fmt.Errorf("Pi CLI returned an unrecognized or prerelease version; Mokusei requires a stable Pi release >= 0.83.0. Check pi --version")
		}
		numbers[i] = n
	}
	if numbers[0] == 0 && numbers[1] < 83 {
		return "", fmt.Errorf("Pi CLI %s is too old; upgrade to Pi >= 0.83.0 for the required RPC completion protocol", version)
	}
	return version, nil
}

type rpcResult struct {
	message map[string]any
	err     error
}

// rpcTransport owns framing, request correlation and a detached process group.
// Native meaning, run admission and settlement belong to Session.
type rpcTransport struct {
	version      string
	cmd          *exec.Cmd
	stdin        io.WriteCloser
	stdout       io.ReadCloser
	stderr       io.ReadCloser
	diagnostics  *diagnosticTail
	stderrDone   chan struct{}
	bridge       *hostBridge
	bridgeConn   net.Conn
	done         chan struct{}
	readDone     chan struct{}
	closed       chan struct{}
	closeOnce    sync.Once
	writeGate    chan struct{}
	mu           sync.Mutex
	failure      error
	sequence     int64
	nextListener int64
	pending      map[string]chan rpcResult
	events       map[int64]func(map[string]any)
	failures     map[int64]func(error)
}

func startRPC(ctx context.Context, options ProcessOptions) (*rpcTransport, error) {
	version, err := GetVersion(ctx, options)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("Pi RPC startup cancelled: %w", err)
	}
	cmd := exec.Command(options.ExecutablePath, append([]string{"--mode", "rpc"}, options.Args...)...)
	cmd.Dir, cmd.Env = options.Cwd, piEnvironment(options.Env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	childStdin, stdin, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdout, childStdout, err := os.Pipe()
	if err != nil {
		_ = childStdin.Close()
		_ = stdin.Close()
		return nil, err
	}
	stderr, childStderr, err := os.Pipe()
	if err != nil {
		_ = childStdin.Close()
		_ = childStdout.Close()
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	// Own the read ends ourselves. exec.Cmd.Wait closes StdoutPipe before a
	// concurrent reader has necessarily drained the final settlement frame.
	cmd.Stdin, cmd.Stdout, cmd.Stderr = childStdin, childStdout, childStderr
	closeChildPipes := func() {
		_ = childStdin.Close()
		_ = childStdout.Close()
		_ = childStderr.Close()
	}
	defer closeChildPipes()
	rpc := &rpcTransport{version: version, cmd: cmd, stdin: stdin, stdout: stdout, stderr: stderr, writeGate: make(chan struct{}, 1),
		done: make(chan struct{}), readDone: make(chan struct{}), closed: make(chan struct{}), pending: map[string]chan rpcResult{},
		events: map[int64]func(map[string]any){}, failures: map[int64]func(error){}}
	var childSocket *os.File
	if options.Bridge != nil {
		fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
		if err != nil {
			_ = stdin.Close()
			_ = stdout.Close()
			_ = stderr.Close()
			return nil, fmt.Errorf("create Pi host bridge socket: %w", err)
		}
		syscall.CloseOnExec(fds[0])
		syscall.CloseOnExec(fds[1])
		parentSocket := os.NewFile(uintptr(fds[0]), "pi-host-bridge")
		childSocket = os.NewFile(uintptr(fds[1]), "pi-host-bridge-child")
		rpc.bridgeConn, err = net.FileConn(parentSocket)
		_ = parentSocket.Close()
		if err != nil {
			_ = childSocket.Close()
			_ = stdin.Close()
			_ = stdout.Close()
			_ = stderr.Close()
			return nil, fmt.Errorf("open Pi host bridge socket: %w", err)
		}
		cmd.ExtraFiles = []*os.File{childSocket}
	}
	err = cmd.Start()
	closeChildPipes()
	if childSocket != nil {
		_ = childSocket.Close()
	}
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		if rpc.bridgeConn != nil {
			_ = rpc.bridgeConn.Close()
		}
		return nil, fmt.Errorf("Pi RPC process could not start: %w", err)
	}
	rpc.diagnostics = &diagnosticTail{limit: 2048}
	rpc.stderrDone = make(chan struct{})
	go func() {
		defer close(rpc.stderrDone)
		_, _ = io.Copy(rpc.diagnostics, stderr)
	}()
	go rpc.read()
	go func() {
		err := cmd.Wait()
		close(rpc.done)
		// Once the direct child exits, close its remaining descendants' writers,
		// then let stdout and stderr drain before publishing the terminal process
		// error, which carries the child's own diagnostic (for example an unknown
		// --provider) instead of only its exit status.
		_ = killProcessGroup(cmd, syscall.SIGTERM)
		select {
		case <-rpc.readDone:
		case <-time.After(time.Second):
		}
		if err != nil {
			rpc.terminate(fmt.Errorf("Pi RPC process exited: %w", err))
		} else {
			rpc.terminate(fmt.Errorf("Pi RPC process exited (0)"))
		}
	}()
	go func() {
		select {
		case <-ctx.Done():
			rpc.fail(fmt.Errorf("Pi RPC cancelled: %w", ctx.Err()))
		case <-rpc.closed:
		}
	}()
	if options.Bridge != nil {
		bridge, bridgeErr := startBridge(ctx, rpc.bridgeConn, *options.Bridge, rpc.fail)
		if bridgeErr != nil {
			_ = rpc.Close()
			return nil, bridgeErr
		}
		rpc.mu.Lock()
		rpc.bridge = bridge
		failed := rpc.failure
		rpc.mu.Unlock()
		if failed != nil {
			_ = bridge.Close()
			_ = rpc.Close()
			return nil, failed
		}
	}
	startup, cancel := context.WithTimeout(ctx, rpcStartupTimeout)
	defer cancel()
	_, err = rpc.request(startup, map[string]any{"type": "get_state"})
	if err == nil && rpc.bridge != nil {
		err = rpc.bridge.Ready(startup)
	}
	if err != nil {
		if errors.Is(startup.Err(), context.DeadlineExceeded) {
			err = fmt.Errorf("Pi RPC startup timed out")
		}
		_ = rpc.Close()
		return nil, err
	}
	return rpc, nil
}

func killProcessGroup(cmd *exec.Cmd, signal syscall.Signal) error {
	if cmd.Process == nil {
		return nil
	}
	err := syscall.Kill(-cmd.Process.Pid, signal)
	if errors.Is(err, syscall.ESRCH) {
		return nil
	}
	if err != nil {
		if directErr := cmd.Process.Signal(signal); directErr != nil && !errors.Is(directErr, os.ErrProcessDone) {
			return directErr
		}
	}
	return nil
}

// terminate publishes a terminal process failure together with the child's own
// stderr tail. A native rejection such as an unknown --provider is reported only
// there, so an exit status alone would hide the real cause from every caller.
func (r *rpcTransport) terminate(err error) {
	if r.stderrDone != nil {
		select {
		case <-r.stderrDone:
		case <-time.After(250 * time.Millisecond):
		}
	}
	if r.diagnostics != nil {
		if detail := r.diagnostics.message(); detail != "" {
			err = fmt.Errorf("%w; Pi said: %s", err, detail)
		}
	}
	r.fail(err)
}

func (r *rpcTransport) fail(err error) {
	r.mu.Lock()
	if r.failure != nil {
		r.mu.Unlock()
		return
	}
	r.failure = err
	for id, response := range r.pending {
		response <- rpcResult{err: err}
		delete(r.pending, id)
	}
	listeners := make([]func(error), 0, len(r.failures))
	for _, listener := range r.failures {
		listeners = append(listeners, listener)
	}
	r.failures = map[int64]func(error){}
	r.events = map[int64]func(map[string]any){}
	r.mu.Unlock()
	for _, listener := range listeners {
		safelyNotify(listener, err)
	}
	go func() { _ = r.Close() }()
}

func safelyNotify[T any](listener func(T), value T) {
	defer func() { _ = recover() }()
	listener(value)
}

func (r *rpcTransport) read() {
	defer close(r.readDone)
	reader := bufio.NewReaderSize(r.stdout, 64*1024)
	var record []byte
	for {
		part, err := reader.ReadSlice('\n')
		// Allow newline and an optional CR beyond the maximum JSON record size.
		if len(record)+len(part) > maxRPCLineBytes+2 {
			r.terminate(fmt.Errorf("Pi RPC record exceeds size limit"))
			return
		}
		record = append(record, part...)
		if err == bufio.ErrBufferFull {
			if len(record) > maxRPCLineBytes {
				r.terminate(fmt.Errorf("Pi RPC record exceeds size limit"))
				return
			}
			continue
		}
		if err != nil {
			r.terminate(fmt.Errorf("Pi RPC output disconnected"))
			return
		}
		line := bytes.TrimSuffix(bytes.TrimSuffix(record, []byte{'\n'}), []byte{'\r'})
		if len(line) > maxRPCLineBytes {
			r.terminate(fmt.Errorf("Pi RPC record exceeds size limit"))
			return
		}
		var frame map[string]any
		decodeErr := json.Unmarshal(line, &frame)
		if decodeErr != nil || frame == nil {
			r.terminate(fmt.Errorf("Pi RPC returned an invalid JSON record"))
			return
		}
		if _, ok := frame["type"].(string); !ok {
			r.terminate(fmt.Errorf("Pi RPC returned an invalid JSON record"))
			return
		}
		record = record[:0]
		r.mu.Lock()
		if r.failure != nil {
			r.mu.Unlock()
			return
		}
		if frame["type"] == "response" {
			id, _ := frame["id"].(string)
			response := r.pending[id]
			delete(r.pending, id)
			if response != nil {
				if frame["success"] == true {
					data, _ := frame["data"].(map[string]any)
					if data == nil {
						data = map[string]any{}
					}
					response <- rpcResult{message: data}
				} else {
					response <- rpcResult{err: fmt.Errorf("Pi RPC command rejected")}
				}
			}
			r.mu.Unlock()
		} else {
			listeners := make([]func(map[string]any), 0, len(r.events))
			for _, listener := range r.events {
				listeners = append(listeners, listener)
			}
			r.mu.Unlock()
			// These listeners are protocol bookkeeping, not application callbacks.
			// Decode before reading the next frame so a stale settlement cannot
			// attach to a prompt admitted while a callback queue is busy.
			for _, listener := range listeners {
				safelyNotify(listener, frame)
			}
		}
	}
}

func (r *rpcTransport) write(ctx context.Context, message map[string]any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	line, err := json.Marshal(message)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	select {
	case r.writeGate <- struct{}{}:
		defer func() { <-r.writeGate }()
	case <-ctx.Done():
		return ctx.Err()
	case <-r.closed:
		r.mu.Lock()
		err := r.failure
		r.mu.Unlock()
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	r.mu.Lock()
	err = r.failure
	r.mu.Unlock()
	if err != nil {
		return err
	}
	// Native stdin is an os.Pipe. Its deadline can interrupt backpressure
	// while preserving a full frame that completed alongside cancellation.
	deadline, supportsDeadline := r.stdin.(interface{ SetWriteDeadline(time.Time) error })
	cancelled := make(chan struct{})
	closedOnCancel := false
	stop := context.AfterFunc(ctx, func() {
		if !supportsDeadline || deadline.SetWriteDeadline(time.Now()) != nil {
			closedOnCancel = true
			_ = r.stdin.Close()
		}
		close(cancelled)
	})
	written, err := r.stdin.Write(line)
	if !stop() {
		<-cancelled
		if closedOnCancel || written != len(line) || err != nil {
			err = ctx.Err()
		} else {
			err = deadline.SetWriteDeadline(time.Time{})
		}
	}
	if err == nil && written != len(line) {
		err = io.ErrShortWrite
	}
	if err != nil {
		err = fmt.Errorf("Pi RPC input disconnected: %w", err)
		r.fail(err)
	}
	return err
}

func (r *rpcTransport) request(ctx context.Context, command map[string]any) (map[string]any, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("Pi RPC request cancelled: %w", err)
	}
	r.mu.Lock()
	if r.failure != nil {
		err := r.failure
		r.mu.Unlock()
		return nil, err
	}
	r.sequence++
	id := fmt.Sprintf("oa-%d", r.sequence)
	response := make(chan rpcResult, 1)
	r.pending[id] = response
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
	}()
	message := cloneRecord(command)
	message["id"] = id
	requestCtx, cancel := context.WithTimeout(ctx, rpcRequestTimeout)
	defer cancel()
	if err := r.write(requestCtx, message); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("Pi RPC request cancelled: %w", ctx.Err())
		}
		if requestCtx.Err() != nil {
			// The writer retires partial frames itself. A timeout before the
			// write gate was acquired must leave the active command intact.
			return nil, fmt.Errorf("Pi RPC request timed out")
		}
		err = fmt.Errorf("Pi RPC request could not be written: %w", err)
		r.fail(err)
		return nil, err
	}
	select {
	case result := <-response:
		return result.message, result.err
	case <-ctx.Done():
		return nil, fmt.Errorf("Pi RPC request cancelled: %w", ctx.Err())
	case <-requestCtx.Done():
		if ctx.Err() != nil {
			return nil, fmt.Errorf("Pi RPC request cancelled: %w", ctx.Err())
		}
		err := fmt.Errorf("Pi RPC request timed out")
		r.fail(err)
		return nil, err
	}
}

func (r *rpcTransport) subscribe(listener func(map[string]any)) func() {
	r.mu.Lock()
	r.nextListener++
	id := r.nextListener
	if r.failure == nil {
		r.events[id] = listener
	}
	r.mu.Unlock()
	return func() {
		r.mu.Lock()
		delete(r.events, id)
		r.mu.Unlock()
	}
}

func (r *rpcTransport) onFailure(listener func(error)) func() {
	r.mu.Lock()
	r.nextListener++
	id := r.nextListener
	err := r.failure
	if err == nil {
		r.failures[id] = listener
	}
	r.mu.Unlock()
	if err != nil {
		safelyNotify(listener, err)
	}
	return func() {
		r.mu.Lock()
		delete(r.failures, id)
		r.mu.Unlock()
	}
}

func (r *rpcTransport) Close() error {
	r.closeOnce.Do(func() {
		defer close(r.closed)
		r.mu.Lock()
		if r.failure == nil {
			r.failure = fmt.Errorf("Pi RPC disposed")
			for id, response := range r.pending {
				response <- rpcResult{err: r.failure}
				delete(r.pending, id)
			}
		}
		bridge := r.bridge
		r.mu.Unlock()
		if bridge != nil {
			_ = bridge.Close()
		}
		if r.bridgeConn != nil {
			_ = r.bridgeConn.Close()
		}
		// EOF is Pi's normal shutdown request and lets asynchronous native
		// session_shutdown hooks release their resources. Sending SIGTERM and
		// EOF together can enter shutdown twice; Pi then exits immediately and
		// skips the first disposal. Escalate only when EOF does not finish.
		_ = r.stdin.Close()
		select {
		case <-r.done:
		case <-time.After(time.Second):
			_ = killProcessGroup(r.cmd, syscall.SIGTERM)
			select {
			case <-r.done:
			case <-time.After(time.Second):
				_ = killProcessGroup(r.cmd, syscall.SIGKILL)
				select {
				case <-r.done:
				case <-time.After(time.Second):
				}
			}
		}
		// The direct child may have exited while grandchildren remain alive.
		_ = killProcessGroup(r.cmd, syscall.SIGKILL)
		_ = r.stdout.Close()
		_ = r.stderr.Close()
	})
	return nil
}
