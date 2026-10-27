package accounttelemetry

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"
)

// ClientOptions keeps native account reads injectable without a plugin contract.
type ClientOptions struct {
	HTTP HTTPClient
	Now  func() time.Time
}
type HTTPClient interface {
	Do(*http.Request) (*http.Response, error)
}
type object = map[string]any
type safeClient struct {
	client *http.Client
	// Preserve the caller's public-fetch identity across normalized copies, so
	// native account readers share one prices cache.
	identity *http.Client
}

func (c *safeClient) Do(request *http.Request) (*http.Response, error) { return c.client.Do(request) }

var defaultHTTP HTTPClient = &safeClient{client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
	return errors.New("Account telemetry redirects are disabled")
}}}

func normalizeOptions(host ClientOptions) ClientOptions {
	if host.HTTP == nil {
		host.HTTP = defaultHTTP
	} else if client, ok := host.HTTP.(*http.Client); ok {
		copy := *client
		copy.CheckRedirect = func(*http.Request, []*http.Request) error {
			return errors.New("Account telemetry redirects are disabled")
		}
		host.HTTP = &safeClient{client: &copy, identity: client}
	}
	if host.Now == nil {
		host.Now = time.Now
	}
	return host
}
func readJSON(ctx context.Context, host ClientOptions, url, key string, timeout time.Duration) (int, any, error) {
	bounded, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(bounded, http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, errors.New("invalid account telemetry request")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "Mokusei/0.1")
	request.Header.Set("Cache-Control", "no-store")
	if key != "" {
		request.Header.Set("Authorization", "Bearer "+key)
	}
	response, err := host.HTTP.Do(request)
	if err != nil {
		return 0, nil, errors.New("account telemetry request failed or timed out")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 32*1024*1024+1))
	if err != nil || len(body) > 32*1024*1024 {
		return response.StatusCode, nil, errors.New("invalid account telemetry response size")
	}
	if err = bounded.Err(); err != nil {
		return response.StatusCode, nil, err
	}
	var value any
	if err = json.Unmarshal(body, &value); err != nil {
		return response.StatusCode, nil, errors.New("invalid account telemetry JSON response")
	}
	return response.StatusCode, value, nil
}
func record(value any) object { result, _ := value.(map[string]any); return result }
func text(value any) string   { result, _ := value.(string); return result }
func finiteNumber(value any) (float64, bool) {
	number, ok := value.(float64)
	return number, ok && !math.IsNaN(number) && !math.IsInf(number, 0)
}
func jsonValue(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		panic("invalid account telemetry value")
	}
	return raw
}

func OpenCodeGoAttributionKeys(apiKey string) []string {
	if strings.TrimSpace(apiKey) == "" {
		return []string{}
	}
	hash := sha256.New()
	_, _ = hash.Write([]byte("mokusei.moku.telemetry.sample.v1"))
	for _, part := range []string{"opencode-go", apiKey} {
		_, _ = fmt.Fprintf(hash, "%d:", len([]byte(part)))
		_, _ = hash.Write([]byte(part))
	}
	return []string{"opencode-go:sha256:" + hex.EncodeToString(hash.Sum(nil))}
}
func telemetryTime(value any) (time.Time, bool) {
	if number, ok := finiteNumber(value); ok {
		if number < 1e12 {
			number *= 1000
		}
		if number > 8640000000000000 || number < -8640000000000000 {
			return time.Time{}, false
		}
		return time.UnixMilli(int64(number)), true
	}
	if value, ok := value.(string); ok && strings.TrimSpace(value) != "" {
		for _, layout := range []string{time.RFC3339Nano, "2006-01-02"} {
			if parsed, err := time.Parse(layout, value); err == nil {
				return parsed, true
			}
		}
	}
	return time.Time{}, false
}
func rounded(value float64) float64 { return math.Floor(value*100+0.5) / 100 }
func calculatePace(used float64, durationMinutes float64, reset time.Time, observed time.Time) object {
	duration := durationMinutes * 60000
	until := float64(reset.UnixMilli() - observed.UnixMilli())
	if duration <= 0 || until <= 0 || until > duration {
		return nil
	}
	elapsed := duration - until
	expected := elapsed / duration * 100
	if expected < 3 {
		return nil
	}
	actual := max(0.0, min(100.0, used))
	delta := actual - expected
	remaining := 100 - actual
	projected := actual * until / elapsed
	var multiplier any
	if remaining > 0 && projected > 0 {
		multiplier = math.Floor(remaining/projected*1000+0.5) / 1000
	}
	lasts := true
	var eta any
	var exhaustion any
	if actual >= 100 {
		lasts = false
		eta = int64(0)
		exhaustion = observed.UTC().Format("2006-01-02T15:04:05.000Z")
	} else if actual > 0 {
		candidate := remaining / (actual / elapsed)
		if candidate < until {
			lasts = false
			seconds := int64(math.Floor(candidate/1000 + 0.5))
			eta = seconds
			exhaustion = observed.Add(time.Duration(seconds) * time.Second).UTC().Format("2006-01-02T15:04:05.000Z")
		}
	}
	stage := "on_pace"
	magnitude := math.Abs(delta)
	if magnitude > 2 {
		prefix := "slightly_"
		if magnitude > 12 {
			prefix = "far_"
		} else if magnitude > 6 {
			prefix = ""
		}
		direction := "under"
		if delta > 0 {
			direction = "over"
		}
		stage = prefix + direction + "_pace"
	}
	return object{"expectedUsedPercent": rounded(expected), "deltaPercent": rounded(delta), "stage": stage, "willLastToReset": lasts, "etaSeconds": eta, "projectedExhaustionAt": exhaustion, "sustainableRateMultiplier": multiplier}
}
