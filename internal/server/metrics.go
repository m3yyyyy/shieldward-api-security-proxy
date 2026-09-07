package server

import (
	"fmt"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type PolicyReloadOutcome string

const (
	PolicyReloadUpdated  PolicyReloadOutcome = "updated"
	PolicyReloadRejected PolicyReloadOutcome = "rejected"
)

type httpMetricKey struct {
	route  string
	status int
}

type Metrics struct {
	mu sync.Mutex

	now       func() time.Time
	startedAt time.Time

	httpRequests  map[httpMetricKey]uint64
	policyReloads map[PolicyReloadOutcome]uint64

	activeEventStreams atomic.Int64
	metricsScrapes     atomic.Uint64
}

func NewMetrics() *Metrics {
	return newMetrics(time.Now)
}

func newMetrics(now func() time.Time) *Metrics {
	startedAt := now()

	return &Metrics{
		now:       now,
		startedAt: startedAt,
		httpRequests: make(
			map[httpMetricKey]uint64,
		),
		policyReloads: map[PolicyReloadOutcome]uint64{
			PolicyReloadUpdated:  0,
			PolicyReloadRejected: 0,
		},
	}
}

func (metrics *Metrics) RecordPolicyReload(
	outcome PolicyReloadOutcome,
) {
	switch outcome {
	case PolicyReloadUpdated, PolicyReloadRejected:
	default:
		return
	}

	metrics.mu.Lock()
	defer metrics.mu.Unlock()

	metrics.policyReloads[outcome]++
}

func (metrics *Metrics) beginEventStream() func() {
	metrics.activeEventStreams.Add(1)

	return func() {
		metrics.activeEventStreams.Add(-1)
	}
}

func (metrics *Metrics) wrap(
	next http.Handler,
) http.Handler {
	return http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		observed := &metricsResponseWriter{
			ResponseWriter: writer,
		}
		var wrapped http.ResponseWriter = observed
		if _, supportsFlush := writer.(http.Flusher); supportsFlush {
			wrapped = &metricsFlushingResponseWriter{
				metricsResponseWriter: observed,
			}
		}

		next.ServeHTTP(wrapped, request)

		metrics.recordHTTPRequest(
			metricRoute(request.URL.Path),
			observed.statusCode(),
		)
	})
}

func (metrics *Metrics) render(
	ready bool,
) string {
	scrapes := metrics.metricsScrapes.Add(1)
	now := metrics.now()
	uptime := now.Sub(metrics.startedAt).Seconds()
	if uptime < 0 {
		uptime = 0
	}

	metrics.mu.Lock()
	httpRequests := make(
		map[httpMetricKey]uint64,
		len(metrics.httpRequests),
	)
	for key, value := range metrics.httpRequests {
		httpRequests[key] = value
	}
	policyReloads := make(
		map[PolicyReloadOutcome]uint64,
		len(metrics.policyReloads),
	)
	for key, value := range metrics.policyReloads {
		policyReloads[key] = value
	}
	metrics.mu.Unlock()

	keys := make([]httpMetricKey, 0, len(httpRequests))
	for key := range httpRequests {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool {
		if keys[left].route == keys[right].route {
			return keys[left].status < keys[right].status
		}
		return keys[left].route < keys[right].route
	})

	var output strings.Builder
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_process_start_time_seconds Start time of the control-plane process.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_process_start_time_seconds gauge")
	fmt.Fprintf(&output, "shieldward_control_plane_process_start_time_seconds %g\n", float64(metrics.startedAt.UnixNano())/1e9)
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_process_uptime_seconds Uptime of the control-plane process.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_process_uptime_seconds gauge")
	fmt.Fprintf(&output, "shieldward_control_plane_process_uptime_seconds %g\n", uptime)
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_ready Whether a signed policy bundle is ready.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_ready gauge")
	if ready {
		fmt.Fprintln(&output, "shieldward_control_plane_ready 1")
	} else {
		fmt.Fprintln(&output, "shieldward_control_plane_ready 0")
	}
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_http_requests_total HTTP requests grouped by bounded route and status.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_http_requests_total counter")
	for _, key := range keys {
		fmt.Fprintf(
			&output,
			"shieldward_control_plane_http_requests_total{route=%q,status=%q} %d\n",
			key.route,
			fmt.Sprint(key.status),
			httpRequests[key],
		)
	}
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_policy_reload_total Policy reload attempts by result.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_policy_reload_total counter")
	for _, outcome := range []PolicyReloadOutcome{
		PolicyReloadUpdated,
		PolicyReloadRejected,
	} {
		fmt.Fprintf(
			&output,
			"shieldward_control_plane_policy_reload_total{result=%q} %d\n",
			outcome,
			policyReloads[outcome],
		)
	}
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_event_stream_connections Active configuration event streams.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_event_stream_connections gauge")
	fmt.Fprintf(&output, "shieldward_control_plane_event_stream_connections %d\n", metrics.activeEventStreams.Load())
	fmt.Fprintln(&output, "# HELP shieldward_control_plane_metrics_scrapes_total Successful local metrics scrapes.")
	fmt.Fprintln(&output, "# TYPE shieldward_control_plane_metrics_scrapes_total counter")
	fmt.Fprintf(&output, "shieldward_control_plane_metrics_scrapes_total %d\n", scrapes)

	return output.String()
}

func (metrics *Metrics) recordHTTPRequest(
	route string,
	status int,
) {
	key := httpMetricKey{
		route:  route,
		status: status,
	}

	metrics.mu.Lock()
	defer metrics.mu.Unlock()

	metrics.httpRequests[key]++
}

func metricRoute(path string) string {
	switch path {
	case "/healthz":
		return "health"
	case "/readyz":
		return "ready"
	case "/metrics":
		return "metrics"
	case "/v1/bundle":
		return "bundle"
	case "/v1/events":
		return "events"
	default:
		return "other"
	}
}

func isLoopbackRemoteAddress(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		host = address
	}

	host = strings.TrimSpace(
		strings.Trim(host, "[]"),
	)

	if strings.EqualFold(
		strings.TrimSuffix(host, "."),
		"localhost",
	) {
		return true
	}

	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

type metricsResponseWriter struct {
	http.ResponseWriter
	status int
}

func (writer *metricsResponseWriter) WriteHeader(
	status int,
) {
	if writer.status != 0 {
		return
	}

	writer.status = status
	writer.ResponseWriter.WriteHeader(status)
}

func (writer *metricsResponseWriter) Write(
	body []byte,
) (int, error) {
	if writer.status == 0 {
		writer.WriteHeader(http.StatusOK)
	}

	return writer.ResponseWriter.Write(body)
}

type metricsFlushingResponseWriter struct {
	*metricsResponseWriter
}

func (writer *metricsFlushingResponseWriter) Flush() {
	if writer.status == 0 {
		writer.WriteHeader(http.StatusOK)
	}

	writer.ResponseWriter.(http.Flusher).Flush()
}

func (writer *metricsResponseWriter) statusCode() int {
	if writer.status == 0 {
		return http.StatusOK
	}

	return writer.status
}
