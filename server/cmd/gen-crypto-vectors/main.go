package main

import (
	"bytes"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/salehtl/hasala/server/internal/cryptoref/vectors"
)

func main() {
	root := flag.String("root", "..", "the repository root")
	check := flag.Bool("check", false, "compare with the files on disk instead of writing")
	flag.Parse()
	files, err := vectors.Generate(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "gen-crypto-vectors:", err)
		os.Exit(1)
	}
	if !*check {
		if err := vectors.Write(*root, files); err != nil {
			fmt.Fprintln(os.Stderr, "gen-crypto-vectors:", err)
			os.Exit(1)
		}
		fmt.Printf("wrote %d files\n", len(files))
		return
	}
	stale := Diff(*root, files)
	for _, s := range stale {
		fmt.Fprintln(os.Stderr, "stale:", s)
	}
	if len(stale) > 0 {
		os.Exit(1)
	}
}

func Diff(root string, files vectors.Files) []string {
	var out []string
	for p, b := range files {
		got, err := os.ReadFile(filepath.Join(root, p))
		if err != nil || !bytes.Equal(got, b) {
			out = append(out, p)
		}
	}
	dir := filepath.Join(root, vectors.CryptoDir)
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		if _, ok := files[filepath.ToSlash(rel)]; !ok {
			out = append(out, filepath.ToSlash(rel)+" (not generated)")
		}
		return nil
	})
	sort.Strings(out)
	return out
}
