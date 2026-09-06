package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/signing"
)

const version = "0.1.0-dev"

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "shieldwardd: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		writeUsage(stderr)
		return fmt.Errorf("command is required")
	}

	switch args[0] {
	case "validate":
		return runValidate(args[1:], stdout, stderr)

	case "keygen":
		return runKeygen(args[1:], stdout, stderr)

	case "serve":
		return runServe(args[1:], stdout, stderr)

	case "version", "--version", "-version":
		_, err := fmt.Fprintln(stdout, version)
		return err

	case "help", "--help", "-h":
		writeUsage(stdout)
		return nil

	default:
		writeUsage(stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runValidate(args []string, stdout, stderr io.Writer) error {
	flagSet := flag.NewFlagSet("validate", flag.ContinueOnError)
	flagSet.SetOutput(stderr)
	flagSet.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"Usage: shieldwardd validate -policy <path>",
		)
	}

	policyPath := flagSet.String(
		"policy",
		"",
		"path to a YAML or TOML security policy",
	)

	if err := flagSet.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if flagSet.NArg() != 0 {
		return fmt.Errorf("validate accepts no positional arguments")
	}

	if strings.TrimSpace(*policyPath) == "" {
		flagSet.Usage()
		return fmt.Errorf("validate requires -policy")
	}

	document, err := policy.LoadFile(*policyPath)
	if err != nil {
		return fmt.Errorf("validate %q: %w", *policyPath, err)
	}

	_, err = fmt.Fprintf(
		stdout,
		"validated policy=%q routes=%d\n",
		document.Metadata.Name,
		len(document.Spec.Routes),
	)
	return err
}

func runKeygen(args []string, stdout, stderr io.Writer) error {
	flagSet := flag.NewFlagSet("keygen", flag.ContinueOnError)
	flagSet.SetOutput(stderr)
	flagSet.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"Usage: shieldwardd keygen [-private-key <path>] [-public-key <path>]",
		)
	}

	privateKeyPath := flagSet.String(
		"private-key",
		".shieldward/private.pem",
		"path for the generated private signing key",
	)
	publicKeyPath := flagSet.String(
		"public-key",
		".shieldward/public.pem",
		"path for the generated public verification key",
	)

	if err := flagSet.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if flagSet.NArg() != 0 {
		return fmt.Errorf("keygen accepts no positional arguments")
	}

	if strings.TrimSpace(*privateKeyPath) == "" {
		return fmt.Errorf("keygen requires a non-empty private-key path")
	}
	if strings.TrimSpace(*publicKeyPath) == "" {
		return fmt.Errorf("keygen requires a non-empty public-key path")
	}

	privatePath := filepath.Clean(*privateKeyPath)
	publicPath := filepath.Clean(*publicKeyPath)

	outputs := []struct {
		name string
		path string
	}{
		{name: "private key", path: privatePath},
		{name: "public key", path: publicPath},
	}

	for _, output := range outputs {
		if err := os.MkdirAll(filepath.Dir(output.path), 0o700); err != nil {
			return fmt.Errorf(
				"create %s directory: %w",
				output.name,
				err,
			)
		}
	}

	keyID, err := signing.GenerateAndWriteKeyPair(
		privatePath,
		publicPath,
	)
	if err != nil {
		return fmt.Errorf("generate signing key pair: %w", err)
	}

	_, err = fmt.Fprintf(
		stdout,
		"generated Ed25519 signing key\nkey-id=%s\nprivate-key=%s\npublic-key=%s\n",
		keyID,
		privatePath,
		publicPath,
	)
	return err
}

func writeUsage(writer io.Writer) {
	_, _ = fmt.Fprintln(writer, `ShieldWard control-plane service

Usage:
  shieldwardd validate -policy <path>
  shieldwardd serve -policy <path> [-private-key <path>] [-listen <address>] [-tls-cert <path> -tls-key <path>]
  shieldwardd version
  shieldwardd help`)
}
