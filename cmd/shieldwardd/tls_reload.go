package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const maxTLSMaterialFileBytes = 1024 * 1024

type serverTLSMaterial struct {
	certificate tls.Certificate
	clientCAs   *x509.CertPool
	fingerprint [sha256.Size]byte
}

type tlsMaterialReloader struct {
	certificatePath string
	privateKeyPath  string
	clientCAPath    string
	now             func() time.Time

	mu       sync.RWMutex
	material *serverTLSMaterial
}

func newTLSMaterialReloader(
	certificatePath string,
	privateKeyPath string,
	clientCAPath string,
) (*tlsMaterialReloader, error) {
	reloader := &tlsMaterialReloader{
		certificatePath: strings.TrimSpace(certificatePath),
		privateKeyPath:  strings.TrimSpace(privateKeyPath),
		clientCAPath:    strings.TrimSpace(clientCAPath),
		now:             time.Now,
	}

	material, err := reloader.load()
	if err != nil {
		return nil, err
	}
	reloader.material = material

	return reloader, nil
}

func (reloader *tlsMaterialReloader) TLSConfig(
	expectedClientIdentity string,
) *tls.Config {
	base := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	base.GetConfigForClient = func(
		_ *tls.ClientHelloInfo,
	) (*tls.Config, error) {
		material := reloader.current()
		configuration := base.Clone()
		configuration.GetConfigForClient = nil
		configuration.Certificates = []tls.Certificate{
			material.certificate,
		}

		if material.clientCAs != nil {
			configuration.ClientAuth = tls.VerifyClientCertIfGiven
			configuration.ClientCAs = material.clientCAs
			configuration.VerifyConnection = func(
				state tls.ConnectionState,
			) error {
				if len(state.PeerCertificates) == 0 {
					return nil
				}
				return verifyClientIdentity(
					state,
					expectedClientIdentity,
				)
			}
		}

		return configuration, nil
	}

	return base
}

func requireServiceIdentity(next http.Handler) http.Handler {
	return http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		if strings.HasPrefix(request.URL.Path, "/v1/") &&
			(request.TLS == nil ||
				len(request.TLS.VerifiedChains) == 0) {
			writer.Header().Set("Cache-Control", "no-store")
			http.Error(
				writer,
				"client certificate required",
				http.StatusUnauthorized,
			)
			return
		}

		next.ServeHTTP(writer, request)
	})
}

func (reloader *tlsMaterialReloader) Reload() (bool, error) {
	material, err := reloader.load()
	if err != nil {
		return false, err
	}

	reloader.mu.Lock()
	defer reloader.mu.Unlock()

	if reloader.material != nil &&
		reloader.material.fingerprint == material.fingerprint {
		return false, nil
	}

	reloader.material = material
	return true, nil
}

func (reloader *tlsMaterialReloader) Run(
	ctx context.Context,
	interval time.Duration,
	onReload func(),
	onError func(error),
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			updated, err := reloader.Reload()
			if err != nil {
				if onError != nil {
					onError(err)
				}
				continue
			}
			if updated && onReload != nil {
				onReload()
			}
		}
	}
}

func (reloader *tlsMaterialReloader) current() *serverTLSMaterial {
	reloader.mu.RLock()
	defer reloader.mu.RUnlock()

	return reloader.material
}

func (reloader *tlsMaterialReloader) load() (*serverTLSMaterial, error) {
	certificatePEM, err := readTLSMaterialFile(
		reloader.certificatePath,
		"certificate",
	)
	if err != nil {
		return nil, err
	}
	privateKeyPEM, err := readTLSMaterialFile(
		reloader.privateKeyPath,
		"private key",
	)
	if err != nil {
		return nil, err
	}

	certificate, err := tls.X509KeyPair(
		certificatePEM,
		privateKeyPEM,
	)
	if err != nil {
		return nil, fmt.Errorf(
			"load TLS certificate and key: %w",
			err,
		)
	}
	if len(certificate.Certificate) == 0 {
		return nil, fmt.Errorf("TLS certificate chain is empty")
	}

	leaf, err := x509.ParseCertificate(
		certificate.Certificate[0],
	)
	if err != nil {
		return nil, fmt.Errorf("parse TLS certificate: %w", err)
	}
	currentTime := reloader.now()
	if currentTime.Before(leaf.NotBefore) || currentTime.After(leaf.NotAfter) {
		return nil, fmt.Errorf("TLS certificate is not currently valid")
	}
	certificate.Leaf = leaf

	var clientCAs *x509.CertPool
	var clientCAPEM []byte
	if reloader.clientCAPath != "" {
		clientCAPEM, err = readTLSMaterialFile(
			reloader.clientCAPath,
			"client certificate authority",
		)
		if err != nil {
			return nil, err
		}

		clientCAs = x509.NewCertPool()
		if !clientCAs.AppendCertsFromPEM(clientCAPEM) {
			return nil, fmt.Errorf(
				"TLS client certificate authority file contains no certificates",
			)
		}
	}

	fingerprintInput := make(
		[]byte,
		0,
		len(certificatePEM)+len(privateKeyPEM)+len(clientCAPEM)+2,
	)
	fingerprintInput = append(fingerprintInput, certificatePEM...)
	fingerprintInput = append(fingerprintInput, 0)
	fingerprintInput = append(fingerprintInput, privateKeyPEM...)
	fingerprintInput = append(fingerprintInput, 0)
	fingerprintInput = append(fingerprintInput, clientCAPEM...)

	return &serverTLSMaterial{
		certificate: certificate,
		clientCAs:   clientCAs,
		fingerprint: sha256.Sum256(fingerprintInput),
	}, nil
}

func readTLSMaterialFile(
	path string,
	description string,
) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat TLS %s file: %w", description, err)
	}
	if info.Size() == 0 {
		return nil, fmt.Errorf("TLS %s file must not be empty", description)
	}
	if info.Size() > maxTLSMaterialFileBytes {
		return nil, fmt.Errorf(
			"TLS %s file exceeds %d bytes",
			description,
			maxTLSMaterialFileBytes,
		)
	}

	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read TLS %s file: %w", description, err)
	}

	return contents, nil
}

func validateMutualTLS(
	tlsEnabled bool,
	clientCAPath string,
	clientIdentity string,
) error {
	clientCAConfigured := strings.TrimSpace(clientCAPath) != ""
	identityConfigured := strings.TrimSpace(clientIdentity) != ""

	if clientCAConfigured != identityConfigured {
		return fmt.Errorf(
			"client-ca and client-identity must be configured together",
		)
	}
	if !clientCAConfigured {
		return nil
	}
	if !tlsEnabled {
		return fmt.Errorf("client certificate authentication requires TLS")
	}

	identity, err := url.Parse(strings.TrimSpace(clientIdentity))
	if err != nil ||
		identity.Scheme != "spiffe" ||
		identity.Host == "" ||
		identity.Path == "" ||
		identity.RawQuery != "" ||
		identity.Fragment != "" ||
		identity.User != nil {
		return fmt.Errorf(
			"client-identity must be an absolute SPIFFE URI without credentials, query, or fragment",
		)
	}

	return nil
}

func verifyClientIdentity(
	state tls.ConnectionState,
	expectedIdentity string,
) error {
	if len(state.VerifiedChains) == 0 ||
		len(state.VerifiedChains[0]) == 0 {
		return fmt.Errorf("client certificate was not verified")
	}

	leaf := state.VerifiedChains[0][0]
	for _, identity := range leaf.URIs {
		if identity.String() == expectedIdentity {
			return nil
		}
	}

	return fmt.Errorf("client certificate identity is not authorized")
}
