//go:build !unix

package headroom

func statfsAvail(string) (uint64, error) { return 0, errUnsupported }
