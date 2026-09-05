package canonicaljson

import (
	"bytes"
	"testing"
)

func TestTransformMatchesRFC8785Example(t *testing.T) {
	input := []byte(`{
"numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
"string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
"literals": [null, true, false]
}`)

	expected := []byte(
		`{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}`,
	)

	actual, err := Transform(input)
	if err != nil {
		t.Fatalf("Transform() returned unexpected error: %v", err)
	}

	if !bytes.Equal(actual, expected) {
		t.Fatalf(
			"Transform() = %s; expected %s",
			actual,
			expected,
		)
	}
}

func TestMarshalSortsNestedObjects(t *testing.T) {
	value := map[string]any{
		"z": "last",
		"a": map[string]any{
			"b": 2,
			"a": 1,
		},
		"items": []any{
			map[string]any{
				"y": true,
				"x": nil,
			},
		},
	}

	expected := []byte(
		`{"a":{"a":1,"b":2},"items":[{"x":null,"y":true}],"z":"last"}`,
	)

	actual, err := Marshal(value)
	if err != nil {
		t.Fatalf("Marshal() returned unexpected error: %v", err)
	}

	if !bytes.Equal(actual, expected) {
		t.Fatalf(
			"Marshal() = %s; expected %s",
			actual,
			expected,
		)
	}
}
