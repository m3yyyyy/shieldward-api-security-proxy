package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	defaultProbeURL     = "http://127.0.0.1:8080/readyz"
	defaultProbeTimeout = 3 * time.Second
	maxProbeCAFileBytes = 1024 * 1024
)

func runProbe(args []string, stdout, stderr io.Writer) error {
	flagSet := flag.NewFlagSet("probe", flag.ContinueOnError)
	flagSet.SetOutput(stderr)
	flagSet.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"Usage: shieldwardd probe [-url <health-url>] [-ca <ca-certificate>] [-timeout <duration>]",
		)
	}

	probeURL := flagSet.String(
		"url",
		environmentOrDefault(
			"SHIELDWARD_HEALTHCHECK_URL",
			defaultProbeURL,
		),
		"HTTP or HTTPS readiness URL",
	)
	caFile := flagSet.String(
		"ca",
		strings.TrimSpace(os.Getenv("SHIELDWARD_HEALTHCHECK_CA_FILE")),
		"optional PEM CA certificate for HTTPS",
	)
	timeout := flagSet.Duration(
		"timeout",
		defaultProbeTimeout,
		"request timeout",
	)

	if err := flagSet.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if flagSet.NArg() != 0 {
		return fmt.Errorf("probe accepts no positional arguments")
	}
	if *timeout <= 0 || *timeout > 30*time.Second {
		return fmt.Errorf("probe timeout must be between 1ns and 30s")
	}

	target, err := parseProbeURL(*probeURL)
	if err != nil {
		return err
	}

	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	if strings.TrimSpace(*caFile) != "" {
		roots, err := loadProbeRoots(strings.TrimSpace(*caFile))
		if err != nil {
			return err
		}
		tlsConfig.RootCAs = roots
	}

	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		ForceAttemptHTTP2:     true,
		TLSClientConfig:       tlsConfig,
		TLSHandshakeTimeout:   *timeout,
		ResponseHeaderTimeout: *timeout,
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{
		Transport: transport,
		Timeout:   *timeout,
		CheckRedirect: func(
			*http.Request,
			[]*http.Request,
		) error {
			return errors.New("health probe redirects are not allowed")
		},
	}

	request, err := http.NewRequest(http.MethodGet, target.String(), nil)
	if err != nil {
		return fmt.Errorf("create health probe request: %w", err)
	}
	request.Header.Set("Accept", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("health probe request failed: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf(
			"health probe returned HTTP %d",
			response.StatusCode,
		)
	}

	_, err = fmt.Fprintf(stdout, "healthy status=%d\n", response.StatusCode)
	return err
}

func parseProbeURL(value string) (*url.URL, error) {
	target, err := url.Parse(strings.TrimSpace(value))
	if err != nil || target.Scheme == "" || target.Host == "" {
		return nil, fmt.Errorf("health probe URL must be an absolute HTTP or HTTPS URL")
	}
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, fmt.Errorf("health probe URL must use HTTP or HTTPS")
	}
	if target.User != nil {
		return nil, fmt.Errorf("health probe URL must not contain credentials")
	}
	if target.Fragment != "" {
		return nil, fmt.Errorf("health probe URL must not contain a fragment")
	}
	if target.Scheme == "http" && !isLoopbackListenHost(target.Hostname()) {
		return nil, fmt.Errorf("health probe must use HTTPS unless it targets loopback")
	}

	return target, nil
}

func loadProbeRoots(path string) (*x509.CertPool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat health probe CA file: %w", err)
	}
	if info.Size() > maxProbeCAFileBytes {
		return nil, fmt.Errorf(
			"health probe CA file exceeds %d bytes",
			maxProbeCAFileBytes,
		)
	}

	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read health probe CA file: %w", err)
	}

	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("health probe CA file contains no certificates")
	}

	return roots, nil
}

func environmentOrDefault(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}
