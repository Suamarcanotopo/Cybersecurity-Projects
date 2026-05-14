// ©AngelaMos | 2026
// client.go

package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/cenkalti/backoff/v4"
	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ratelimit"
)

const (
	defaultUserAgent           = "monitor-the-situation/1.0"
	defaultRequestTimeout      = 30 * time.Second
	defaultMaxRetryElapsed     = 60 * time.Second
	defaultInitialRetryBackoff = 500 * time.Millisecond
	defaultMaxRetryBackoff     = 10 * time.Second
	defaultAPIKeyHeader        = "X-API-Key"
	clientErrorBodyLimit       = 4096
)

type Config struct {
	Name                     string
	BaseURL                  string
	Headers                  http.Header
	BearerToken              string
	APIKey                   string
	APIKeyHeader             string
	Rate                     rate.Limit
	Burst                    int
	ConsecutiveFailureBudget uint32
	BreakerTimeout           time.Duration
	RequestTimeout           time.Duration
	MaxRetryElapsed          time.Duration
	UserAgent                string
}

type Client struct {
	cfg     Config
	limiter *ratelimit.Limiter[*http.Response]
	hc      *http.Client
}

type StatusError struct {
	Code int
	Body string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("client error %d: %s", e.Code, e.Body)
}

func New(cfg Config) *Client {
	if cfg.RequestTimeout <= 0 {
		cfg.RequestTimeout = defaultRequestTimeout
	}
	if cfg.MaxRetryElapsed <= 0 {
		cfg.MaxRetryElapsed = defaultMaxRetryElapsed
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = defaultUserAgent
	}
	limiter := ratelimit.New[*http.Response](ratelimit.Config{
		Name:                     cfg.Name,
		Rate:                     cfg.Rate,
		Burst:                    cfg.Burst,
		ConsecutiveFailureBudget: cfg.ConsecutiveFailureBudget,
		BreakerTimeout:           cfg.BreakerTimeout,
	})
	return &Client{
		cfg:     cfg,
		limiter: limiter,
		hc:      &http.Client{Timeout: cfg.RequestTimeout},
	}
}

func (c *Client) GetJSON(
	ctx context.Context,
	path string,
	query url.Values,
	out any,
) error {
	resp, err := c.Get(ctx, path, query)
	if err != nil {
		return err
	}
	defer drainAndClose(resp)
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) Get(
	ctx context.Context,
	path string,
	query url.Values,
) (*http.Response, error) {
	target, err := c.resolveURL(path, query)
	if err != nil {
		return nil, err
	}

	bo := backoff.NewExponentialBackOff()
	bo.MaxElapsedTime = c.cfg.MaxRetryElapsed
	bo.InitialInterval = defaultInitialRetryBackoff
	bo.MaxInterval = defaultMaxRetryBackoff

	var resp *http.Response
	op := func() error {
		r, opErr := c.limiter.Do(
			ctx,
			func(rctx context.Context) (*http.Response, error) {
				return c.do(rctx, target)
			},
		)
		if opErr != nil {
			return opErr
		}
		switch {
		case r.StatusCode == http.StatusTooManyRequests:
			retryAfter := parseRetryAfter(r.Header.Get("Retry-After"))
			drainAndClose(r)
			if retryAfter > 0 {
				select {
				case <-ctx.Done():
					return backoff.Permanent(ctx.Err())
				case <-time.After(retryAfter):
				}
			}
			return errors.New("upstream 429")
		case r.StatusCode >= 500 && r.StatusCode <= 599:
			drainAndClose(r)
			return fmt.Errorf("upstream %d", r.StatusCode)
		case r.StatusCode >= 400:
			body, _ := io.ReadAll(io.LimitReader(r.Body, clientErrorBodyLimit))
			drainAndClose(r)
			return backoff.Permanent(
				&StatusError{Code: r.StatusCode, Body: string(body)},
			)
		}
		resp = r
		return nil
	}
	if err := backoff.Retry(op, backoff.WithContext(bo, ctx)); err != nil {
		return nil, err
	}
	return resp, nil
}

func (c *Client) do(
	ctx context.Context,
	target string,
) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.cfg.UserAgent)
	for k, vs := range c.cfg.Headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	if c.cfg.BearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.BearerToken)
	}
	if c.cfg.APIKey != "" {
		header := c.cfg.APIKeyHeader
		if header == "" {
			header = defaultAPIKeyHeader
		}
		req.Header.Set(header, c.cfg.APIKey)
	}
	return c.hc.Do(req)
}

func (c *Client) resolveURL(path string, query url.Values) (string, error) {
	base, err := url.Parse(c.cfg.BaseURL)
	if err != nil {
		return "", err
	}
	rel, err := url.Parse(path)
	if err != nil {
		return "", err
	}
	resolved := base.ResolveReference(rel)
	if query != nil {
		resolved.RawQuery = query.Encode()
	}
	return resolved.String(), nil
}

func parseRetryAfter(v string) time.Duration {
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(v); err == nil {
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil {
		d := time.Until(t)
		if d > 0 {
			return d
		}
	}
	return 0
}

func drainAndClose(r *http.Response) {
	if r == nil || r.Body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, r.Body)
	_ = r.Body.Close()
}
