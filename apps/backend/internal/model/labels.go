package model

import (
	"errors"
)

// ErrUnknownLabelKind - вид PDF не large, small или cards.
var ErrUnknownLabelKind = errors.New("вид этикеток: large, small или cards")
