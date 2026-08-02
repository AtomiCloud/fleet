package kargoexpression

import (
	"os"
	"testing"

	"github.com/akuity/kargo/pkg/expressions"
	"github.com/expr-lang/expr"
)

type image struct {
	Tag string
}

func imageFromOption() expr.Option {
	return expr.Function(
		"imageFrom",
		func(params ...any) (any, error) {
			return image{Tag: "1.2.3"}, nil
		},
		new(func(string) image),
	)
}

func evaluate(candidate string) (any, error) {
	return expressions.EvaluateTemplate(candidate, map[string]any{}, imageFromOption())
}

func TestPinnedEvaluatorRejectsLegacyPipeAndAcceptsExprLangCall(t *testing.T) {
	if _, err := evaluate(`${{ imageFrom "registry.atomi.cloud/canary/dummy" | .Tag }}`); err == nil {
		t.Fatal("pinned Kargo evaluator accepted the legacy Go-template pipe expression")
	}
	got, err := evaluate(`${{ imageFrom("registry.atomi.cloud/canary/dummy").Tag }}`)
	if err != nil {
		t.Fatalf("pinned Kargo evaluator rejected expr-lang call syntax: %v", err)
	}
	if got != "1.2.3" {
		t.Fatalf("pinned Kargo evaluator returned %#v, want the Freight image tag", got)
	}
}

func TestRenderedExpressionUsesThePinnedEvaluator(t *testing.T) {
	candidate := os.Getenv("KARGO_EXPRESSION_UNDER_TEST")
	if candidate == "" {
		candidate = `${{ imageFrom("registry.atomi.cloud/canary/dummy").Tag }}`
	}
	got, err := evaluate(candidate)
	if err != nil {
		t.Fatalf("rendered yaml-update expression is invalid for pinned Kargo v1.9.10: %v", err)
	}
	if got != "1.2.3" {
		t.Fatalf("rendered expression returned %#v, want the Freight image tag", got)
	}
}
