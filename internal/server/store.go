package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/signing"
)

type Snapshot struct {
	body    []byte
	etag    string
	version string
}

func (snapshot *Snapshot) Body() []byte {
	return bytes.Clone(snapshot.body)
}

func (snapshot *Snapshot) ETag() string {
	return snapshot.etag
}

func (snapshot *Snapshot) Version() string {
	return snapshot.version
}

type Store struct {
	current atomic.Pointer[Snapshot]

	mu               sync.Mutex
	nextSubscriberID uint64
	subscribers      map[uint64]chan string
}

func NewStore() *Store {
	return &Store{
		subscribers: make(map[uint64]chan string),
	}
}

func (store *Store) Current() (*Snapshot, bool) {
	snapshot := store.current.Load()
	return snapshot, snapshot != nil
}

func (store *Store) Publish(envelope signing.Envelope) error {
	snapshot, err := newSnapshot(envelope)
	if err != nil {
		return err
	}

	store.mu.Lock()
	defer store.mu.Unlock()

	store.current.Store(snapshot)

	for _, updates := range store.subscribers {
		pushLatest(updates, snapshot.version)
	}

	return nil
}

func (store *Store) Subscribe() (<-chan string, func()) {
	store.mu.Lock()

	subscriberID := store.nextSubscriberID
	store.nextSubscriberID++

	updates := make(chan string, 1)
	store.subscribers[subscriberID] = updates

	if snapshot := store.current.Load(); snapshot != nil {
		updates <- snapshot.version
	}

	store.mu.Unlock()

	var once sync.Once

	cancel := func() {
		once.Do(func() {
			store.mu.Lock()
			defer store.mu.Unlock()

			if existing, exists := store.subscribers[subscriberID]; exists {
				delete(store.subscribers, subscriberID)
				close(existing)
			}
		})
	}

	return updates, cancel
}

func newSnapshot(envelope signing.Envelope) (*Snapshot, error) {
	if envelope.Algorithm == "" {
		return nil, fmt.Errorf("envelope algorithm must not be empty")
	}

	if envelope.KeyID == "" {
		return nil, fmt.Errorf("envelope key ID must not be empty")
	}

	if envelope.Bundle.Version == "" {
		return nil, fmt.Errorf("bundle version must not be empty")
	}

	if envelope.Signature == "" {
		return nil, fmt.Errorf("envelope signature must not be empty")
	}

	body, err := json.Marshal(envelope)
	if err != nil {
		return nil, fmt.Errorf("encode snapshot: %w", err)
	}

	return &Snapshot{
		body:    body,
		etag:    fmt.Sprintf("%q", envelope.Bundle.Version),
		version: envelope.Bundle.Version,
	}, nil
}

func pushLatest(updates chan string, version string) {
	select {
	case updates <- version:
		return
	default:
	}

	select {
	case <-updates:
	default:
	}

	select {
	case updates <- version:
	default:
	}
}
