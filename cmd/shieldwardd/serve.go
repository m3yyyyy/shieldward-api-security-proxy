package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/compiler"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
	controlserver "github.com/m3yyyyy/shieldward-api-security-proxy/internal/server"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/signing"
)

const shutdownTimeout = 10 * time.Second

func runServe(args []string, stdout, stderr io.Writer) error {
	flagSet := flag.NewFlagSet("serve", flag.ContinueOnError)
	flagSet.SetOutput(stderr)
	flagSet.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"Usage: shieldwardd serve -policy <path> [-private-key <path>] [-listen <address>]",
		)
	}

	policyPath := flagSet.String(
		"policy",
		"",
		"path to a YAML or TOML security policy",
	)
	privateKeyPath := flagSet.String(
		"private-key",
		".shieldward/private.pem",
		"path to the Ed25519 private signing key",
	)
	listenAddress := flagSet.String(
		"listen",
		"127.0.0.1:8080",
		"control-plane listening address",
	)

	if err := flagSet.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if flagSet.NArg() != 0 {
		return fmt.Errorf("serve accepts no positional arguments")
	}

	if strings.TrimSpace(*policyPath) == "" {
		flagSet.Usage()
		return fmt.Errorf("serve requires -policy")
	}
	if strings.TrimSpace(*privateKeyPath) == "" {
		return fmt.Errorf("serve requires a non-empty private-key path")
	}
	if strings.TrimSpace(*listenAddress) == "" {
		return fmt.Errorf("serve requires a non-empty listen address")
	}

	envelope, err := loadSignedEnvelope(
		*policyPath,
		*privateKeyPath,
	)
	if err != nil {
		return err
	}

	store := controlserver.NewStore()
	if err := store.Publish(envelope); err != nil {
		return fmt.Errorf("publish initial bundle: %w", err)
	}

	processContext, stopSignals := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stopSignals()

	listener, err := net.Listen(
		"tcp",
		strings.TrimSpace(*listenAddress),
	)
	if err != nil {
		return fmt.Errorf("listen on %q: %w", *listenAddress, err)
	}
	defer listener.Close()

	httpServer := &http.Server{
		Handler:           controlserver.NewHandler(store),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
		ErrorLog:          log.New(stderr, "shieldwardd: ", log.LstdFlags),
		BaseContext: func(net.Listener) context.Context {
			return processContext
		},
	}

	go watchPolicy(
		processContext,
		*policyPath,
		*privateKeyPath,
		store,
		stdout,
		stderr,
	)

	serveResult := make(chan error, 1)
	go func() {
		serveResult <- httpServer.Serve(listener)
	}()

	_, _ = fmt.Fprintf(
		stdout,
		"serving policy=%q version=%q key-id=%q listen=%q\n",
		envelope.Bundle.PolicyName,
		envelope.Bundle.Version,
		envelope.KeyID,
		listener.Addr().String(),
	)

	select {
	case serveErr := <-serveResult:
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			return fmt.Errorf("serve control plane: %w", serveErr)
		}
		return nil

	case <-processContext.Done():
		_, _ = fmt.Fprintln(stdout, "shutdown requested")

		shutdownContext, cancel := context.WithTimeout(
			context.Background(),
			shutdownTimeout,
		)
		defer cancel()

		if err := httpServer.Shutdown(shutdownContext); err != nil {
			_ = httpServer.Close()
			return fmt.Errorf("shut down control plane: %w", err)
		}

		serveErr := <-serveResult
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			return fmt.Errorf("serve control plane: %w", serveErr)
		}

		_, _ = fmt.Fprintln(stdout, "shutdown complete")
		return nil
	}
}

func loadSignedEnvelope(
	policyPath string,
	privateKeyPath string,
) (signing.Envelope, error) {
	document, err := policy.LoadFile(policyPath)
	if err != nil {
		return signing.Envelope{}, fmt.Errorf("load policy: %w", err)
	}

	bundle, err := compiler.Compile(document)
	if err != nil {
		return signing.Envelope{}, fmt.Errorf("compile policy: %w", err)
	}

	privateKey, err := signing.LoadPrivateKeyFile(privateKeyPath)
	if err != nil {
		return signing.Envelope{}, fmt.Errorf("load private key: %w", err)
	}

	envelope, err := signing.Sign(bundle, privateKey)
	if err != nil {
		return signing.Envelope{}, fmt.Errorf("sign bundle: %w", err)
	}

	return envelope, nil
}
