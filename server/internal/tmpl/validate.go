package tmpl

import (
	"errors"
	"fmt"
	"strings"
)

var ErrInvalidDefinition = errors.New("tmpl: definition rejected by the publish gate")

func ValidateForPublish(d Definition) error {
	for i, x := range d.Extract {
		for j, p := range x.Patterns {
			if errs := ValidatePattern(p, x.Flags); len(errs) > 0 {
				return fmt.Errorf("%w: extract[%d].patterns[%d]: %s",
					ErrInvalidDefinition, i, j, strings.Join(Codes(errs), ", "))
			}
		}
	}
	if errs := ValidateDefinition(d); len(errs) > 0 {
		return fmt.Errorf("%w: %w", ErrInvalidDefinition, errors.Join(errs...))
	}
	if _, err := Compile(d); err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidDefinition, err)
	}
	return nil
}
