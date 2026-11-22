package authtest

import (
	"bytes"
	"sync"

	"github.com/salehtl/hasala/server/internal/cryptoref"
)

type stretchKey struct {
	password, salt, emailNorm string
}

type stretchResult struct {
	once sync.Once
	s    []byte
}

var stretched sync.Map

func Stretch(password string, sSrv []byte, emailNorm string) []byte {
	v, _ := stretched.LoadOrStore(stretchKey{password, string(sSrv), emailNorm}, &stretchResult{})
	r := v.(*stretchResult)
	r.once.Do(func() { r.s = cryptoref.Stretch(password, sSrv, emailNorm) })
	return bytes.Clone(r.s)
}
