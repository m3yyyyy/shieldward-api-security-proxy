package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestValidateMutualTLSFailsClosed(t *testing.T) {
	tests := []struct {
		name      string
		tls       bool
		clientCA  string
		identity  string
		wantError string
	}{
		{
			name: "disabled",
		},
		{
			name:     "configured",
			tls:      true,
			clientCA: "ca.pem",
			identity: "spiffe://shieldward.local/edge",
		},
		{
			name:      "missing identity",
			tls:       true,
			clientCA:  "ca.pem",
			wantError: "must be configured together",
		},
		{
			name:      "without TLS",
			clientCA:  "ca.pem",
			identity:  "spiffe://shieldward.local/edge",
			wantError: "requires TLS",
		},
		{
			name:      "non SPIFFE identity",
			tls:       true,
			clientCA:  "ca.pem",
			identity:  "https://shieldward.local/edge",
			wantError: "absolute SPIFFE URI",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateMutualTLS(
				test.tls,
				test.clientCA,
				test.identity,
			)
			if test.wantError == "" && err != nil {
				t.Fatalf("validateMutualTLS() error = %v", err)
			}
			if test.wantError != "" &&
				(err == nil || !strings.Contains(err.Error(), test.wantError)) {
				t.Fatalf(
					"validateMutualTLS() error = %v; expected %q",
					err,
					test.wantError,
				)
			}
		})
	}
}

func TestVerifyClientIdentityUsesExactURISAN(t *testing.T) {
	authorized, err := url.Parse(
		"spiffe://shieldward.local/edge",
	)
	if err != nil {
		t.Fatal(err)
	}
	certificate := &x509.Certificate{
		URIs: []*url.URL{authorized},
	}
	state := tls.ConnectionState{
		VerifiedChains: [][]*x509.Certificate{{certificate}},
	}

	if err := verifyClientIdentity(
		state,
		authorized.String(),
	); err != nil {
		t.Fatalf("verifyClientIdentity() error = %v", err)
	}
	if err := verifyClientIdentity(
		state,
		"spiffe://shieldward.local/other",
	); err == nil {
		t.Fatal("verifyClientIdentity() authorized the wrong identity")
	}
}

func TestRequireServiceIdentityProtectsConfigurationEndpoints(t *testing.T) {
	handler := requireServiceIdentity(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusNoContent)
		},
	))

	withoutIdentity := httptest.NewRequest(
		http.MethodGet,
		"https://control.example/v1/bundle",
		nil,
	)
	withoutIdentity.TLS = nil
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, withoutIdentity)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d; expected 401", response.Code)
	}

	health := httptest.NewRequest(
		http.MethodGet,
		"https://control.example/readyz",
		nil,
	)
	health.TLS = nil
	healthResponse := httptest.NewRecorder()
	handler.ServeHTTP(healthResponse, health)
	if healthResponse.Code != http.StatusNoContent {
		t.Fatalf(
			"health status = %d; expected 204",
			healthResponse.Code,
		)
	}

	withIdentity := httptest.NewRequest(
		http.MethodGet,
		"https://control.example/v1/bundle",
		nil,
	)
	withIdentity.TLS = &tls.ConnectionState{
		VerifiedChains: [][]*x509.Certificate{{{}}},
	}
	identityResponse := httptest.NewRecorder()
	handler.ServeHTTP(identityResponse, withIdentity)
	if identityResponse.Code != http.StatusNoContent {
		t.Fatalf(
			"identity status = %d; expected 204",
			identityResponse.Code,
		)
	}
}

func TestTLSMaterialReloaderKeepsLastKnownGoodMaterial(t *testing.T) {
	directory := t.TempDir()
	certificatePath := filepath.Join(directory, "certificate.pem")
	privateKeyPath := filepath.Join(directory, "private-key.pem")

	certificateOne, keyOne := newSelfSignedTLSMaterial(t, 1)
	writeTLSPair(
		t,
		certificatePath,
		privateKeyPath,
		certificateOne,
		keyOne,
	)

	reloader, err := newTLSMaterialReloader(
		certificatePath,
		privateKeyPath,
		"",
	)
	if err != nil {
		t.Fatalf("newTLSMaterialReloader() error = %v", err)
	}
	if got := reloader.current().certificate.Leaf.SerialNumber.Int64(); got != 1 {
		t.Fatalf("initial serial = %d; expected 1", got)
	}

	certificateTwo, keyTwo := newSelfSignedTLSMaterial(t, 2)
	writeTLSPair(
		t,
		certificatePath,
		privateKeyPath,
		certificateTwo,
		keyTwo,
	)
	updated, err := reloader.Reload()
	if err != nil || !updated {
		t.Fatalf("Reload() = %t, %v; expected update", updated, err)
	}
	if got := reloader.current().certificate.Leaf.SerialNumber.Int64(); got != 2 {
		t.Fatalf("rotated serial = %d; expected 2", got)
	}

	if err := os.WriteFile(privateKeyPath, keyOne, 0o600); err != nil {
		t.Fatalf("write mismatched key: %v", err)
	}
	if _, err := reloader.Reload(); err == nil {
		t.Fatal("Reload() accepted mismatched TLS material")
	}
	if got := reloader.current().certificate.Leaf.SerialNumber.Int64(); got != 2 {
		t.Fatalf("serial after rejected reload = %d; expected 2", got)
	}
}

func TestMutualTLSAuthorizesOnlyExpectedServiceIdentity(t *testing.T) {
	authority, authorityKey, authorityPEM := newTestAuthority(t)
	serverCertificate, serverKey := newSignedTLSMaterial(
		t,
		authority,
		authorityKey,
		10,
		[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		nil,
		[]net.IP{net.ParseIP("127.0.0.1")},
	)
	authorizedURI, _ := url.Parse("spiffe://shieldward.local/edge")
	clientCertificatePEM, clientKeyPEM := newSignedTLSMaterial(
		t,
		authority,
		authorityKey,
		11,
		[]x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		[]*url.URL{authorizedURI},
		nil,
	)
	unauthorizedURI, _ := url.Parse("spiffe://shieldward.local/other")
	otherCertificatePEM, otherKeyPEM := newSignedTLSMaterial(
		t,
		authority,
		authorityKey,
		12,
		[]x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		[]*url.URL{unauthorizedURI},
		nil,
	)

	directory := t.TempDir()
	certificatePath := filepath.Join(directory, "server-cert.pem")
	keyPath := filepath.Join(directory, "server-key.pem")
	caPath := filepath.Join(directory, "client-ca.pem")
	writeTLSPair(
		t,
		certificatePath,
		keyPath,
		serverCertificate,
		serverKey,
	)
	if err := os.WriteFile(caPath, authorityPEM, 0o600); err != nil {
		t.Fatalf("write client CA: %v", err)
	}

	reloader, err := newTLSMaterialReloader(
		certificatePath,
		keyPath,
		caPath,
	)
	if err != nil {
		t.Fatalf("newTLSMaterialReloader() error = %v", err)
	}

	server := httptest.NewUnstartedServer(
		requireServiceIdentity(http.HandlerFunc(
			func(writer http.ResponseWriter, _ *http.Request) {
				writer.WriteHeader(http.StatusNoContent)
			},
		)),
	)
	server.TLS = reloader.TLSConfig(authorizedURI.String())
	server.StartTLS()
	defer server.Close()

	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(authorityPEM) {
		t.Fatal("append test CA")
	}

	request := func(
		certificatePEM []byte,
		privateKeyPEM []byte,
	) (*http.Response, error) {
		configuration := &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    roots,
		}
		if certificatePEM != nil {
			certificate, loadErr := tls.X509KeyPair(
				certificatePEM,
				privateKeyPEM,
			)
			if loadErr != nil {
				t.Fatalf("load client certificate: %v", loadErr)
			}
			configuration.Certificates = []tls.Certificate{certificate}
		}

		transport := &http.Transport{
			TLSClientConfig: configuration,
		}
		defer transport.CloseIdleConnections()
		return (&http.Client{Transport: transport}).Get(
			server.URL + "/v1/bundle",
		)
	}

	response, err := request(clientCertificatePEM, clientKeyPEM)
	if err != nil {
		t.Fatalf("authorized request error = %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf(
			"authorized status = %d; expected 204",
			response.StatusCode,
		)
	}

	response, err = request(nil, nil)
	if err != nil {
		t.Fatalf("anonymous request error = %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf(
			"anonymous status = %d; expected 401",
			response.StatusCode,
		)
	}

	if _, err := request(otherCertificatePEM, otherKeyPEM); err == nil {
		t.Fatal("unauthorized service identity completed a TLS request")
	}
}

func newSelfSignedTLSMaterial(
	t *testing.T,
	serial int64,
) ([]byte, []byte) {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate private key: %v", err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject: pkix.Name{
			CommonName: "shieldward-test",
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}

	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		&privateKey.PublicKey,
		privateKey,
	)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}

	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}

	return pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: der,
		}), pem.EncodeToMemory(&pem.Block{
			Type:  "PRIVATE KEY",
			Bytes: privateDER,
		})
}

func newTestAuthority(
	t *testing.T,
) (*x509.Certificate, *rsa.PrivateKey, []byte) {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(100),
		Subject: pkix.Name{
			CommonName: "ShieldWard test CA",
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		&privateKey.PublicKey,
		privateKey,
	)
	if err != nil {
		t.Fatalf("create CA certificate: %v", err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA certificate: %v", err)
	}

	return certificate, privateKey, pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: der,
	})
}

func newSignedTLSMaterial(
	t *testing.T,
	authority *x509.Certificate,
	authorityKey *rsa.PrivateKey,
	serial int64,
	usages []x509.ExtKeyUsage,
	identities []*url.URL,
	ipAddresses []net.IP,
) ([]byte, []byte) {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject: pkix.Name{
			CommonName: "shieldward-test-leaf",
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           usages,
		URIs:                  identities,
		IPAddresses:           ipAddresses,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		authority,
		&privateKey.PublicKey,
		authorityKey,
	)
	if err != nil {
		t.Fatalf("create leaf certificate: %v", err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal leaf key: %v", err)
	}

	return pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: der,
		}), pem.EncodeToMemory(&pem.Block{
			Type:  "PRIVATE KEY",
			Bytes: privateDER,
		})
}

func writeTLSPair(
	t *testing.T,
	certificatePath string,
	privateKeyPath string,
	certificate []byte,
	privateKey []byte,
) {
	t.Helper()

	if err := os.WriteFile(certificatePath, certificate, 0o600); err != nil {
		t.Fatalf("write certificate: %v", err)
	}
	if err := os.WriteFile(privateKeyPath, privateKey, 0o600); err != nil {
		t.Fatalf("write private key: %v", err)
	}
}
