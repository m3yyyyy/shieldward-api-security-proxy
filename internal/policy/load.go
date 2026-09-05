package policy

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml/v2"
	"go.yaml.in/yaml/v4"
)

const MaxDocumentBytes = 1 << 20

func LoadFile(path string) (Document, error) {
	file, err := os.Open(path)
	if err != nil {
		return Document{}, fmt.Errorf("open policy: %w", err)
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, MaxDocumentBytes+1))
	if err != nil {
		return Document{}, fmt.Errorf("read policy: %w", err)
	}

	if len(data) > MaxDocumentBytes {
		return Document{}, fmt.Errorf(
			"policy exceeds maximum size of %d bytes",
			MaxDocumentBytes,
		)
	}

	return Parse(data, filepath.Ext(path))
}

func Parse(data []byte, format string) (Document, error) {
	if len(data) > MaxDocumentBytes {
		return Document{}, fmt.Errorf(
			"policy exceeds maximum size of %d bytes",
			MaxDocumentBytes,
		)
	}

	normalizedFormat := strings.TrimPrefix(
		strings.ToLower(strings.TrimSpace(format)),
		".",
	)

	var (
		document Document
		err      error
	)

	switch normalizedFormat {
	case "yaml", "yml":
		document, err = parseYAML(data)
	case "toml":
		document, err = parseTOML(data)
	default:
		return Document{}, fmt.Errorf(
			"unsupported policy format %q",
			normalizedFormat,
		)
	}

	if err != nil {
		return Document{}, err
	}

	if err := Validate(document); err != nil {
		return Document{}, fmt.Errorf("validate policy: %w", err)
	}

	return document, nil
}

func parseYAML(data []byte) (Document, error) {
	var documents []Document

	err := yaml.Load(
		data,
		&documents,
		yaml.WithKnownFields(),
		yaml.WithAllDocuments(),
	)
	if err != nil {
		return Document{}, fmt.Errorf("decode YAML policy: %w", err)
	}

	if len(documents) != 1 {
		return Document{}, fmt.Errorf(
			"YAML policy must contain exactly one document",
		)
	}

	return documents[0], nil
}

func parseTOML(data []byte) (Document, error) {
	var document Document

	decoder := toml.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&document); err != nil {
		return Document{}, fmt.Errorf("decode TOML policy: %w", err)
	}

	return document, nil
}
