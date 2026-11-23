package mail

import (
	"bytes"
	"embed"
	htmltemplate "html/template"
	"sync"
)

const LogoURL = "https://hasala.app/brand/hasala-mark-email.png"

//go:embed templates/*.html.tmpl
var htmlFS embed.FS

var (
	layoutOnce sync.Once
	layoutT    *htmltemplate.Template
	accountT   *htmltemplate.Template
	layoutErr  error
)

func loadLayout() {
	layoutT, layoutErr = htmltemplate.ParseFS(htmlFS, "templates/layout.html.tmpl")
	if layoutErr != nil {
		return
	}
	var c *htmltemplate.Template
	if c, layoutErr = layoutT.Clone(); layoutErr != nil {
		return
	}
	accountT, layoutErr = c.ParseFS(htmlFS, "templates/account.html.tmpl")
}

func Layout() (*htmltemplate.Template, error) {
	layoutOnce.Do(loadLayout)
	if layoutErr != nil {
		return nil, layoutErr
	}
	return layoutT.Clone()
}

type Row struct{ Label, Value string }

type page struct {
	Title, Preview, Greeting, Why string

	Heading string
	Lead    []string
	Code    string
	Rows    []Row
	Paras   []string
	Freeze  string
	Small   string
}

func (p page) render() (string, error) {
	layoutOnce.Do(loadLayout)
	if layoutErr != nil {
		return "", layoutErr
	}
	var b bytes.Buffer
	if err := accountT.ExecuteTemplate(&b, "layout", p); err != nil {
		return "", err
	}
	return b.String(), nil
}
