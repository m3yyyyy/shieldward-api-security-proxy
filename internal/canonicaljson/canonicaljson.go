package canonicaljson

import (
	"encoding/json"
	"fmt"

	"github.com/gowebpki/jcs"
)

// Marshal encodes a value and transforms it into RFC 8785 canonical JSON.
func Marshal(value any) ([]byte, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode JSON: %w", err)
	}

	return Transform(encoded)
}

// Transform converts existing JSON into its RFC 8785 canonical form.
func Transform(encoded []byte) ([]byte, error) {
	canonical, err := jcs.Transform(encoded)
	if err != nil {
		return nil, fmt.Errorf("canonicalize JSON: %w", err)
	}

	return canonical, nil
}
