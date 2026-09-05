package signing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const MaxKeyFileBytes = 16 << 10

func GenerateAndWriteKeyPair(
	privatePath string,
	publicPath string,
) (string, error) {
	if filepath.Clean(privatePath) == filepath.Clean(publicPath) {
		return "", fmt.Errorf("private and public key paths must differ")
	}

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", fmt.Errorf("generate Ed25519 key pair: %w", err)
	}

	privatePEM, err := EncodePrivateKeyPEM(privateKey)
	if err != nil {
		return "", err
	}

	publicPEM, err := EncodePublicKeyPEM(publicKey)
	if err != nil {
		return "", err
	}

	if err := writeExclusive(publicPath, publicPEM, 0o644); err != nil {
		return "", fmt.Errorf("write public key: %w", err)
	}

	if err := writeExclusive(privatePath, privatePEM, 0o600); err != nil {
		cleanupErr := os.Remove(publicPath)
		if cleanupErr != nil {
			return "", fmt.Errorf(
				"write private key: %v; remove incomplete public key: %v",
				err,
				cleanupErr,
			)
		}

		return "", fmt.Errorf("write private key: %w", err)
	}

	keyID, err := PublicKeyID(publicKey)
	if err != nil {
		return "", err
	}

	return keyID, nil
}

func EncodePrivateKeyPEM(
	privateKey ed25519.PrivateKey,
) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf(
			"private key must contain %d bytes",
			ed25519.PrivateKeySize,
		)
	}

	der, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("marshal PKCS#8 private key: %w", err)
	}

	encoded := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: der,
	})
	if encoded == nil {
		return nil, fmt.Errorf("encode private key PEM")
	}

	return encoded, nil
}

func EncodePublicKeyPEM(
	publicKey ed25519.PublicKey,
) ([]byte, error) {
	if len(publicKey) != ed25519.PublicKeySize {
		return nil, fmt.Errorf(
			"public key must contain %d bytes",
			ed25519.PublicKeySize,
		)
	}

	der, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return nil, fmt.Errorf("marshal PKIX public key: %w", err)
	}

	encoded := pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: der,
	})
	if encoded == nil {
		return nil, fmt.Errorf("encode public key PEM")
	}

	return encoded, nil
}

func LoadPrivateKeyFile(path string) (ed25519.PrivateKey, error) {
	data, err := readLimitedKeyFile(path)
	if err != nil {
		return nil, err
	}

	return ParsePrivateKeyPEM(data)
}

func LoadPublicKeyFile(path string) (ed25519.PublicKey, error) {
	data, err := readLimitedKeyFile(path)
	if err != nil {
		return nil, err
	}

	return ParsePublicKeyPEM(data)
}

func ParsePrivateKeyPEM(data []byte) (ed25519.PrivateKey, error) {
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("expected a PRIVATE KEY PEM block")
	}

	if len(bytes.TrimSpace(rest)) != 0 {
		return nil, fmt.Errorf("private key contains trailing data")
	}

	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKCS#8 private key: %w", err)
	}

	privateKey, valid := parsed.(ed25519.PrivateKey)
	if !valid || len(privateKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("private key is not Ed25519")
	}

	return append(ed25519.PrivateKey(nil), privateKey...), nil
}

func ParsePublicKeyPEM(data []byte) (ed25519.PublicKey, error) {
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PUBLIC KEY" {
		return nil, fmt.Errorf("expected a PUBLIC KEY PEM block")
	}

	if len(bytes.TrimSpace(rest)) != 0 {
		return nil, fmt.Errorf("public key contains trailing data")
	}

	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKIX public key: %w", err)
	}

	publicKey, valid := parsed.(ed25519.PublicKey)
	if !valid || len(publicKey) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("public key is not Ed25519")
	}

	return append(ed25519.PublicKey(nil), publicKey...), nil
}

func readLimitedKeyFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open key file: %w", err)
	}
	defer file.Close()

	data, err := io.ReadAll(
		io.LimitReader(file, MaxKeyFileBytes+1),
	)
	if err != nil {
		return nil, fmt.Errorf("read key file: %w", err)
	}

	if len(data) > MaxKeyFileBytes {
		return nil, fmt.Errorf(
			"key file exceeds maximum size of %d bytes",
			MaxKeyFileBytes,
		)
	}

	return data, nil
}

func writeExclusive(
	path string,
	data []byte,
	permissions os.FileMode,
) error {
	file, err := os.OpenFile(
		path,
		os.O_WRONLY|os.O_CREATE|os.O_EXCL,
		permissions,
	)
	if err != nil {
		return err
	}

	cleanup := func() {
		_ = file.Close()
		_ = os.Remove(path)
	}

	if _, err := file.Write(data); err != nil {
		cleanup()
		return err
	}

	if err := file.Sync(); err != nil {
		cleanup()
		return err
	}

	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}

	return nil
}
