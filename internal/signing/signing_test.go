package signing

import (
	"bytes"
	"crypto/ed25519"
	"testing"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/compiler"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
)

func TestSignAndVerify(t *testing.T) {
	publicKey, privateKey := testKeyPair()
	bundle := testBundle(t)

	envelope, err := Sign(bundle, privateKey)
	if err != nil {
		t.Fatalf("Sign() returned unexpected error: %v", err)
	}

	keyID, err := PublicKeyID(publicKey)
	if err != nil {
		t.Fatalf("PublicKeyID() failed: %v", err)
	}

	if envelope.KeyID != keyID {
		t.Fatalf(
			"Envelope.KeyID = %q; expected %q",
			envelope.KeyID,
			keyID,
		)
	}

	keyring := map[string]ed25519.PublicKey{
		keyID: publicKey,
	}

	if err := Verify(envelope, keyring); err != nil {
		t.Fatalf("Verify() returned unexpected error: %v", err)
	}
}

func TestVerifyRejectsTamperedBundle(t *testing.T) {
	publicKey, privateKey := testKeyPair()
	envelope, err := Sign(testBundle(t), privateKey)
	if err != nil {
		t.Fatalf("Sign() failed: %v", err)
	}

	envelope.Bundle.Routes[0].Upstream =
		"https://attacker.example.com"

	keyID, err := PublicKeyID(publicKey)
	if err != nil {
		t.Fatalf("PublicKeyID() failed: %v", err)
	}

	keyring := map[string]ed25519.PublicKey{
		keyID: publicKey,
	}

	if err := Verify(envelope, keyring); err == nil {
		t.Fatal("Verify() accepted a tampered bundle")
	}
}

func TestVerifyRejectsUnknownKey(t *testing.T) {
	_, privateKey := testKeyPair()
	envelope, err := Sign(testBundle(t), privateKey)
	if err != nil {
		t.Fatalf("Sign() failed: %v", err)
	}

	if err := Verify(
		envelope,
		map[string]ed25519.PublicKey{},
	); err == nil {
		t.Fatal("Verify() accepted an unknown signing key")
	}
}

func TestSignRejectsInconsistentBundleVersion(t *testing.T) {
	_, privateKey := testKeyPair()
	bundle := testBundle(t)
	bundle.Version = "sha256:invalid"

	if _, err := Sign(bundle, privateKey); err == nil {
		t.Fatal("Sign() accepted an inconsistent bundle version")
	}
}

func testKeyPair() (ed25519.PublicKey, ed25519.PrivateKey) {
	seed := bytes.Repeat([]byte{0x42}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)

	return publicKey, privateKey
}

func testBundle(t *testing.T) compiler.Bundle {
	t.Helper()

	document := policy.Document{
		APIVersion: policy.APIVersionV1Alpha1,
		Kind:       policy.KindSecurityPolicy,
		Metadata: policy.Metadata{
			Name: "signed-api",
		},
		Spec: policy.Spec{
			DefaultDecision: policy.DecisionDeny,
			Routes: []policy.Route{
				{
					ID: "signed-route",
					Match: policy.RouteMatch{
						Methods: []string{"GET"},
						Path:    "/v1/signed",
					},
					Upstream: "https://service.internal",
				},
			},
		},
	}

	bundle, err := compiler.Compile(document)
	if err != nil {
		t.Fatalf("Compile() failed: %v", err)
	}

	return bundle
}
