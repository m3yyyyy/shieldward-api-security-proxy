package signing

import (
	"bytes"
	"crypto/ed25519"
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateAndLoadKeyPair(t *testing.T) {
	directory := t.TempDir()
	privatePath := filepath.Join(directory, "private.pem")
	publicPath := filepath.Join(directory, "public.pem")

	keyID, err := GenerateAndWriteKeyPair(
		privatePath,
		publicPath,
	)
	if err != nil {
		t.Fatalf("GenerateAndWriteKeyPair() failed: %v", err)
	}

	privateKey, err := LoadPrivateKeyFile(privatePath)
	if err != nil {
		t.Fatalf("LoadPrivateKeyFile() failed: %v", err)
	}

	publicKey, err := LoadPublicKeyFile(publicPath)
	if err != nil {
		t.Fatalf("LoadPublicKeyFile() failed: %v", err)
	}

	derivedPublicKey, valid := privateKey.Public().(ed25519.PublicKey)
	if !valid {
		t.Fatal("private key did not produce an Ed25519 public key")
	}

	if !bytes.Equal(derivedPublicKey, publicKey) {
		t.Fatal("private and public key files do not form a pair")
	}

	loadedKeyID, err := PublicKeyID(publicKey)
	if err != nil {
		t.Fatalf("PublicKeyID() failed: %v", err)
	}

	if loadedKeyID != keyID {
		t.Fatalf(
			"loaded key ID = %q; expected %q",
			loadedKeyID,
			keyID,
		)
	}
}

func TestGenerateAndWriteKeyPairRefusesOverwrite(t *testing.T) {
	directory := t.TempDir()
	privatePath := filepath.Join(directory, "private.pem")
	publicPath := filepath.Join(directory, "public.pem")

	if _, err := GenerateAndWriteKeyPair(
		privatePath,
		publicPath,
	); err != nil {
		t.Fatalf("initial key generation failed: %v", err)
	}

	originalPrivate, err := os.ReadFile(privatePath)
	if err != nil {
		t.Fatalf("read original private key: %v", err)
	}

	if _, err := GenerateAndWriteKeyPair(
		privatePath,
		publicPath,
	); err == nil {
		t.Fatal("second key generation unexpectedly overwrote files")
	}

	currentPrivate, err := os.ReadFile(privatePath)
	if err != nil {
		t.Fatalf("read current private key: %v", err)
	}

	if !bytes.Equal(originalPrivate, currentPrivate) {
		t.Fatal("existing private key was modified")
	}
}

func TestParseKeyPEMRejectsTrailingData(t *testing.T) {
	publicKey, privateKey := testKeyPair()

	privatePEM, err := EncodePrivateKeyPEM(privateKey)
	if err != nil {
		t.Fatalf("EncodePrivateKeyPEM() failed: %v", err)
	}

	publicPEM, err := EncodePublicKeyPEM(publicKey)
	if err != nil {
		t.Fatalf("EncodePublicKeyPEM() failed: %v", err)
	}

	if _, err := ParsePrivateKeyPEM(
		append(privatePEM, []byte("trailing")...),
	); err == nil {
		t.Fatal("ParsePrivateKeyPEM() accepted trailing data")
	}

	if _, err := ParsePublicKeyPEM(
		append(publicPEM, []byte("trailing")...),
	); err == nil {
		t.Fatal("ParsePublicKeyPEM() accepted trailing data")
	}
}

func TestLoadKeyFileRejectsOversizedInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oversized.pem")
	data := bytes.Repeat([]byte{'x'}, MaxKeyFileBytes+1)

	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write oversized test file: %v", err)
	}

	if _, err := LoadPrivateKeyFile(path); err == nil {
		t.Fatal("LoadPrivateKeyFile() accepted oversized input")
	}
}
