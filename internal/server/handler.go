package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const streamKeepAliveInterval = 15 * time.Second

type API struct {
	store *Store
}

func NewHandler(store *Store) http.Handler {
	if store == nil {
		panic("server: store must not be nil")
	}

	api := &API{store: store}
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", api.health)
	mux.HandleFunc("GET /readyz", api.ready)
	mux.HandleFunc("GET /v1/bundle", api.bundle)
	mux.HandleFunc("GET /v1/events", api.events)

	return mux
}

func (api *API) health(
	writer http.ResponseWriter,
	_ *http.Request,
) {
	writeJSON(writer, http.StatusOK, map[string]string{
		"status": "ok",
	})
}

func (api *API) ready(
	writer http.ResponseWriter,
	_ *http.Request,
) {
	snapshot, exists := api.store.Current()
	if !exists {
		writeJSON(writer, http.StatusServiceUnavailable, map[string]string{
			"status": "not_ready",
		})
		return
	}

	writeJSON(writer, http.StatusOK, map[string]string{
		"status":  "ready",
		"version": snapshot.Version(),
	})
}

func (api *API) bundle(
	writer http.ResponseWriter,
	request *http.Request,
) {
	snapshot, exists := api.store.Current()
	if !exists {
		writeJSON(writer, http.StatusServiceUnavailable, map[string]string{
			"error": "configuration_unavailable",
		})
		return
	}

	writer.Header().Set("Cache-Control", "no-cache")
	writer.Header().Set("Content-Type", "application/json")
	writer.Header().Set("ETag", snapshot.ETag())
	writer.Header().Set("X-Content-Type-Options", "nosniff")

	if etagMatches(
		request.Header.Get("If-None-Match"),
		snapshot.ETag(),
	) {
		writer.WriteHeader(http.StatusNotModified)
		return
	}

	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(snapshot.Body())
}

func (api *API) events(
	writer http.ResponseWriter,
	request *http.Request,
) {
	flusher, supported := writer.(http.Flusher)
	if !supported {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{
			"error": "streaming_unsupported",
		})
		return
	}

	updates, cancel := api.store.Subscribe()
	defer cancel()

	writer.Header().Set("Cache-Control", "no-cache, no-transform")
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("X-Accel-Buffering", "no")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(http.StatusOK)
	flusher.Flush()

	keepAlive := time.NewTicker(streamKeepAliveInterval)
	defer keepAlive.Stop()

	for {
		select {
		case version, open := <-updates:
			if !open {
				return
			}

			if err := writeBundleEvent(writer, version); err != nil {
				return
			}
			flusher.Flush()

		case <-keepAlive.C:
			if _, err := fmt.Fprint(writer, ": keepalive\n\n"); err != nil {
				return
			}
			flusher.Flush()

		case <-request.Context().Done():
			return
		}
	}
}

func writeBundleEvent(
	writer http.ResponseWriter,
	version string,
) error {
	payload, err := json.Marshal(map[string]string{
		"version": version,
	})
	if err != nil {
		return fmt.Errorf("encode bundle event: %w", err)
	}

	_, err = fmt.Fprintf(
		writer,
		"event: bundle\ndata: %s\n\n",
		payload,
	)
	return err
}

func etagMatches(headerValue string, currentETag string) bool {
	for _, candidate := range strings.Split(headerValue, ",") {
		candidate = strings.TrimSpace(candidate)

		if candidate == "*" || candidate == currentETag {
			return true
		}
	}

	return false
}

func writeJSON(
	writer http.ResponseWriter,
	status int,
	value any,
) {
	body, err := json.Marshal(value)
	if err != nil {
		http.Error(
			writer,
			http.StatusText(http.StatusInternalServerError),
			http.StatusInternalServerError,
		)
		return
	}

	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(append(body, '\n'))
}
