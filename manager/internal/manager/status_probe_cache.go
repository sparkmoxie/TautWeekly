package manager

import (
	"context"
	"sync"
	"time"
)

const windowsTaskProbeTTL = 15 * time.Second
const windowsTaskProbeTimeout = 3 * time.Second

type windowsTaskProbeFunc func(context.Context, string, string) (windowsTaskProbe, error)

type windowsTaskProbeKey struct{ task, root, revision string }
type windowsTaskProbeResult struct {
	key        windowsTaskProbeKey
	probe      windowsTaskProbe
	observedAt time.Time
	err        error
}

// Each Manager retains at most one scheduler observation and one bounded probe.
// Configuration and private delivery data are never cached here.
type windowsTaskProbeCache struct {
	mu         sync.Mutex
	now        func() time.Time
	probe      windowsTaskProbeFunc
	timeout    time.Duration
	generation uint64
	result     *windowsTaskProbeResult
	flight     chan struct{}
}

func newWindowsTaskProbeCache(now func() time.Time, probe windowsTaskProbeFunc) *windowsTaskProbeCache {
	if now == nil {
		now = time.Now
	}
	return &windowsTaskProbeCache{now: now, probe: probe, timeout: windowsTaskProbeTimeout}
}

func (c *windowsTaskProbeCache) Invalidate() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.generation++
	c.result = nil
	c.mu.Unlock()
}

func (c *windowsTaskProbeCache) Get(ctx context.Context, task, root, revision string) (windowsTaskProbe, time.Time, error) {
	key := windowsTaskProbeKey{task, root, revision}
	for {
		if err := ctx.Err(); err != nil {
			return windowsTaskProbe{}, time.Time{}, err
		}
		c.mu.Lock()
		if result := c.result; result != nil && result.key == key {
			ttl := windowsTaskProbeTTL
			if result.err != nil {
				ttl = time.Second
			}
			age := c.now().Sub(result.observedAt)
			if age >= 0 && age < ttl {
				probe := result.probe
				if probe.LastTaskResult != nil {
					value := *probe.LastTaskResult
					probe.LastTaskResult = &value
				}
				observedAt, err := result.observedAt, result.err
				c.mu.Unlock()
				return probe, observedAt, err
			}
		}
		if c.flight == nil {
			c.flight = make(chan struct{})
			generation := c.generation
			go c.collect(key, generation)
		}
		flight := c.flight
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return windowsTaskProbe{}, time.Time{}, ctx.Err()
		case <-flight:
		}
	}
}

func (c *windowsTaskProbeCache) collect(key windowsTaskProbeKey, generation uint64) {
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()
	probe, err := c.probe(ctx, key.task, key.root)
	result := &windowsTaskProbeResult{key: key, probe: probe, observedAt: c.now().UTC(), err: err}
	c.mu.Lock()
	if c.generation == generation {
		c.result = result
	}
	close(c.flight)
	c.flight = nil
	c.mu.Unlock()
}
