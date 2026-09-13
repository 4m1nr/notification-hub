package main

import (
	"strings"
	"testing"
)

const multipart = "From: A <a@x>\r\nSubject: hi\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=B\r\n\r\n" +
	"--B\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello   there,\r\n\r\nthe   report is ready.\r\n" +
	"--B\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hello <b>there</b></p>\r\n--B--\r\n"

const htmlOnly = "From: A <a@x>\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" +
	"<html><head><style>p{color:red}</style></head><body><p>Quarterly &amp; annual</p><script>x()</script><div>numbers&nbsp;attached</div></body></html>"

const qpLatin = "From: A <a@x>\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=E9 r=E9union"

func TestPreview(t *testing.T) {
	cases := map[string]struct{ in, want string }{
		"prefers plain over html": {multipart, "Hello there, the report is ready."},
		"html only is de-tagged":  {htmlOnly, "Quarterly & annual numbers attached"},
		"decodes qp and charset":  {qpLatin, "Café réunion"},
		"empty":                   {"", ""},
		"garbage":                 {"not a message", ""},
	}
	for name, c := range cases {
		if got := preview([]byte(c.in)); got != c.want {
			t.Errorf("%s: got %q, want %q", name, got, c.want)
		}
	}
}

func TestPreviewTruncated(t *testing.T) {
	long := "From: A <a@x>\r\nContent-Type: text/plain\r\n\r\n" + strings.Repeat("word ", 200)
	got := preview([]byte(long[:len(long)-7])) // cut mid-body, as maxFetch would
	if !strings.HasPrefix(got, "word word") || !strings.HasSuffix(got, "…") || len([]rune(got)) != maxPreview+1 {
		t.Errorf("truncated body: got %d runes, suffix %q", len([]rune(got)), got[len(got)-3:])
	}
}
