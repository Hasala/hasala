package pushv2

import (
	"context"
	"errors"

	"github.com/google/uuid"
)

type Notifier interface {
	Notify(ctx context.Context, userID uuid.UUID) error
}

type Disabled struct{}

func (Disabled) Notify(context.Context, uuid.UUID) error { return nil }

type Multi []Notifier

func (m Multi) Notify(ctx context.Context, userID uuid.UUID) error {
	var errs []error
	for _, n := range m {
		if n == nil {
			continue
		}
		if err := n.Notify(ctx, userID); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
