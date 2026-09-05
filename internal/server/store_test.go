package server

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"testing"
	"time"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/compiler"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/signing"
)

func TestStorePublishesImmutableSnapshot(t *testing.T) {
	store := NewStore()

	if _, exists := store.Current(); exists {
		t.Fatal("new store unexpectedly contains a snapshot")
	}

	envelope := storeTestEnvelope(t, "https://first.internal")
	if err := store.Publish(envelope); err != nil {
		t.Fatalf("Publish() failed: %v", err)
	}

	snapshot, exists := store.Current()
	if !exists {
		t.Fatal("published snapshot was not found")
	}

	if snapshot.Version() != envelope.Bundle.Version {
		t.Fatalf(
			"Version() = %q; expected %q",
			snapshot.Version(),
			envelope.Bundle.Version,
		)
	}

	expectedETag := `"` + envelope.Bundle.Version + `"`
	if snapshot.ETag() != expectedETag {
		t.Fatalf(
			"ETag() = %q; expected %q",
			snapshot.ETag(),
			expectedETag,
		)
	}

	firstBody := snapshot.Body()
	firstBody[0] = 'x'

	secondBody := snapshot.Body()
	if secondBody[0] == 'x' {
		t.Fatal("Snapshot.Body() exposed mutable internal storage")
	}

	var decoded signing.Envelope
	if err := json.Unmarshal(secondBody, &decoded); err != nil {
		t.Fatalf("snapshot body is not valid JSON: %v", err)
	}

	if decoded.Bundle.Version != envelope.Bundle.Version {
		t.Fatalf(
			"decoded version = %q; expected %q",
			decoded.Bundle.Version,
			envelope.Bundle.Version,
		)
	}
}

func TestStoreSubscriberReceivesLatestVersion(t *testing.T) {
	store := NewStore()

	first := storeTestEnvelope(t, "https://first.internal")
	if err := store.Publish(first); err != nil {
		t.Fatalf("first Publish() failed: %v", err)
	}

	updates, cancel := store.Subscribe()

	if got := awaitVersion(t, updates); got != first.Bundle.Version {
		t.Fatalf(
			"initial update = %q; expected %q",
			got,
			first.Bundle.Version,
		)
	}

	second := storeTestEnvelope(t, "https://second.internal")
	third := storeTestEnvelope(t, "https://third.internal")

	if err := store.Publish(second); err != nil {
		t.Fatalf("second Publish() failed: %v", err)
	}

	if err := store.Publish(third); err != nil {
		t.Fatalf("third Publish() failed: %v", err)
	}

	if got := awaitVersion(t, updates); got != third.Bundle.Version {
		t.Fatalf(
			"coalesced update = %q; expected latest %q",
			got,
			third.Bundle.Version,
		)
	}

	cancel()
	cancel()

	if _, open := <-updates; open {
		t.Fatal("subscriber channel remained open after cancellation")
	}
}

func awaitVersion(
	t *testing.T,
	updates <-chan string,
) string {
	t.Helper()

	select {
	case version, open := <-updates:
		if !open {
			t.Fatal("subscriber channel closed unexpectedly")
		}
		return version

	case <-time.After(time.Second):
		t.Fatal("timed out waiting for snapshot update")
		return ""
	}
}

func storeTestEnvelope(
	t *testing.T,
	upstream string,
) signing.Envelope {
	t.Helper()

	document := policy.Document{
		APIVersion: policy.APIVersionV1Alpha1,
		Kind:       policy.KindSecurityPolicy,
		Metadata: policy.Metadata{
			Name: "store-api",
		},
		Spec: policy.Spec{
			DefaultDecision: policy.DecisionDeny,
			Routes: []policy.Route{
				{
					ID: "store-route",
					Match: policy.RouteMatch{
						Methods: []string{"GET"},
						Path:    "/store",
					},
					Upstream: upstream,
				},
			},
		},
	}

	bundle, err := compiler.Compile(document)
	if err != nil {
		t.Fatalf("Compile() failed: %v", err)
	}

	seed := bytes.Repeat([]byte{0x24}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)

	envelope, err := signing.Sign(bundle, privateKey)
	if err != nil {
		t.Fatalf("Sign() failed: %v", err)
	}

	return envelope
}
