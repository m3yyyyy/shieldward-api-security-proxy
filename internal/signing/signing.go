package signing

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/compiler"
)

const AlgorithmEd25519 = "Ed25519"

type Envelope struct {
	Algorithm string          `json:"algorithm"`
	KeyID     string          `json:"keyId"`
	Bundle    compiler.Bundle `json:"bundle"`
	Signature string          `json:"signature"`
}

func Sign(
	bundle compiler.Bundle,
	privateKey ed25519.PrivateKey,
) (Envelope, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return Envelope{}, fmt.Errorf(
			"private key must contain %d bytes",
			ed25519.PrivateKeySize,
		)
	}

	if err := validateBundleVersion(bundle); err != nil {
		return Envelope{}, err
	}

	publicKey := privateKey.Public().(ed25519.PublicKey)
	keyID, err := PublicKeyID(publicKey)
	if err != nil {
		return Envelope{}, err
	}

	payload, err := json.Marshal(bundle)
	if err != nil {
		return Envelope{}, fmt.Errorf("encode bundle for signing: %w", err)
	}

	signature := ed25519.Sign(privateKey, payload)

	return Envelope{
		Algorithm: AlgorithmEd25519,
		KeyID:     keyID,
		Bundle:    bundle,
		Signature: base64.RawURLEncoding.EncodeToString(signature),
	}, nil
}

func Verify(
	envelope Envelope,
	publicKeys map[string]ed25519.PublicKey,
) error {
	if envelope.Algorithm != AlgorithmEd25519 {
		return fmt.Errorf(
			"unsupported signature algorithm %q",
			envelope.Algorithm,
		)
	}

	publicKey, exists := publicKeys[envelope.KeyID]
	if !exists {
		return fmt.Errorf("unknown signing key %q", envelope.KeyID)
	}

	if len(publicKey) != ed25519.PublicKeySize {
		return fmt.Errorf(
			"public key must contain %d bytes",
			ed25519.PublicKeySize,
		)
	}

	actualKeyID, err := PublicKeyID(publicKey)
	if err != nil {
		return err
	}

	if actualKeyID != envelope.KeyID {
		return fmt.Errorf("public key does not match envelope key ID")
	}

	signature, err := base64.RawURLEncoding.DecodeString(envelope.Signature)
	if err != nil {
		return fmt.Errorf("decode signature: %w", err)
	}

	if len(signature) != ed25519.SignatureSize {
		return fmt.Errorf(
			"signature must contain %d bytes",
			ed25519.SignatureSize,
		)
	}

	payload, err := json.Marshal(envelope.Bundle)
	if err != nil {
		return fmt.Errorf("encode bundle for verification: %w", err)
	}

	if !ed25519.Verify(publicKey, payload, signature) {
		return fmt.Errorf("signature verification failed")
	}

	if err := validateBundleVersion(envelope.Bundle); err != nil {
		return err
	}

	return nil
}

func PublicKeyID(publicKey ed25519.PublicKey) (string, error) {
	if len(publicKey) != ed25519.PublicKeySize {
		return "", fmt.Errorf(
			"public key must contain %d bytes",
			ed25519.PublicKeySize,
		)
	}

	digest := sha256.Sum256(publicKey)
	return fmt.Sprintf("sha256:%x", digest), nil
}

func validateBundleVersion(bundle compiler.Bundle) error {
	if bundle.Version == "" {
		return fmt.Errorf("bundle version must not be empty")
	}

	actualVersion := bundle.Version
	bundle.Version = ""

	canonical, err := json.Marshal(bundle)
	if err != nil {
		return fmt.Errorf("encode bundle version payload: %w", err)
	}

	digest := sha256.Sum256(canonical)
	expectedVersion := fmt.Sprintf("sha256:%x", digest)

	if subtle.ConstantTimeCompare(
		[]byte(actualVersion),
		[]byte(expectedVersion),
	) != 1 {
		return fmt.Errorf("bundle version does not match its content")
	}

	return nil
}
