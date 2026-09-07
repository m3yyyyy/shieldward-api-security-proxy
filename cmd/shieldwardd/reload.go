package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	controlserver "github.com/m3yyyyy/shieldward-api-security-proxy/internal/server"
)

const policyPollInterval = 750 * time.Millisecond

type observedPolicyFile struct {
	size             int64
	modifiedUnixNano int64
	errorText        string
}

func watchPolicy(
	ctx context.Context,
	policyPath string,
	privateKeyPath string,
	store *controlserver.Store,
	metrics *controlserver.Metrics,
	stdout io.Writer,
	stderr io.Writer,
) {
	ticker := time.NewTicker(policyPollInterval)
	defer ticker.Stop()

	lastObservation := observePolicyFile(policyPath)
	firstCheck := true

	for {
		select {
		case <-ctx.Done():
			return

		case <-ticker.C:
			observation := observePolicyFile(policyPath)

			if !firstCheck && observation == lastObservation {
				continue
			}

			firstCheck = false
			lastObservation = observation

			if observation.errorText != "" {
				metrics.RecordPolicyReload(
					controlserver.PolicyReloadRejected,
				)
				_, _ = fmt.Fprintf(
					stderr,
					"policy reload skipped: %s\n",
					observation.errorText,
				)
				continue
			}

			envelope, err := loadSignedEnvelope(
				policyPath,
				privateKeyPath,
			)
			if err != nil {
				metrics.RecordPolicyReload(
					controlserver.PolicyReloadRejected,
				)
				_, _ = fmt.Fprintf(
					stderr,
					"policy reload rejected: %v\n",
					err,
				)
				continue
			}

			current, exists := store.Current()
			if exists &&
				current.Version() == envelope.Bundle.Version {
				continue
			}

			if err := store.Publish(envelope); err != nil {
				metrics.RecordPolicyReload(
					controlserver.PolicyReloadRejected,
				)
				_, _ = fmt.Fprintf(
					stderr,
					"policy reload publish failed: %v\n",
					err,
				)
				continue
			}

			metrics.RecordPolicyReload(
				controlserver.PolicyReloadUpdated,
			)

			_, _ = fmt.Fprintf(
				stdout,
				"reloaded policy=%q version=%q\n",
				envelope.Bundle.PolicyName,
				envelope.Bundle.Version,
			)
		}
	}
}

func observePolicyFile(path string) observedPolicyFile {
	info, err := os.Stat(path)
	if err != nil {
		return observedPolicyFile{
			errorText: err.Error(),
		}
	}

	if !info.Mode().IsRegular() {
		return observedPolicyFile{
			errorText: fmt.Sprintf(
				"%q is not a regular file",
				path,
			),
		}
	}

	return observedPolicyFile{
		size:             info.Size(),
		modifiedUnixNano: info.ModTime().UnixNano(),
	}
}
