package signing

import (
	"crypto/ed25519"
	"encoding/base64"
	"testing"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/canonicaljson"
)

func TestSignUsesCanonicalJSONPayload(t *testing.T) {
	publicKey, privateKey := testKeyPair()
	bundle := testBundle(t)

	envelope, err := Sign(bundle, privateKey)
	if err != nil {
		t.Fatalf("Sign() returned unexpected error: %v", err)
	}

	signature, err := base64.RawURLEncoding.DecodeString(
		envelope.Signature,
	)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}

	canonicalPayload, err := canonicaljson.Marshal(bundle)
	if err != nil {
		t.Fatalf("canonicalize bundle: %v", err)
	}

	if !ed25519.Verify(
		publicKey,
		canonicalPayload,
		signature,
	) {
		t.Fatal("signature was not created from canonical JSON")
	}
}
