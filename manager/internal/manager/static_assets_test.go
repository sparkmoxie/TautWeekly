package manager

import (
	"bytes"
	"compress/gzip"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStaticEncodingNegotiation(t *testing.T) {
	asset := staticAsset{Gzip: &staticVariant{}, Brotli: &staticVariant{}}
	cases := []struct {
		header, want string
		ok           bool
	}{
		{"", "identity", true}, {"gzip, deflate, br", "br", true}, {"gzip", "gzip", true},
		{"br;q=0,gzip", "gzip", true}, {"br;q=0.5,gzip;q=0.9", "gzip", true},
		{"br;q=0.001", "br", true},
		{"BR ; q=1,gzip;q=0.2", "br", true}, {"identity;q=1,br;q=0.5", "identity", true},
		{"br;q=0,gzip;q=0", "identity", true}, {"*", "br", true}, {"*;q=0", "", false},
		{"*;q=1,br;q=0", "gzip", true}, {"*;q=0,identity;q=0.1", "identity", true},
		{"br;q=NaN,gzip", "gzip", true}, {"br;q=2,gzip", "gzip", true},
		{"identity;q=0,br;q=0,gzip;q=0", "", false}, {"br;q=0,br;q=1,gzip", "gzip", true},
	}
	for _, tc := range cases {
		t.Run(tc.header, func(t *testing.T) {
			got, ok := negotiateStaticEncoding(tc.header, asset)
			if got != tc.want || ok != tc.ok {
				t.Fatalf("got %q,%v; want %q,%v", got, ok, tc.want, tc.ok)
			}
		})
	}
	if got, ok := negotiateStaticEncoding("br,gzip", staticAsset{}); got != "identity" || !ok {
		t.Fatal("binary identity fallback failed")
	}
}

func TestStaticAssetEncodingsAndCacheVariants(t *testing.T) {
	root, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		t.Fatal(err)
	}
	manifest := readStaticAssetManifest(root)
	asset := manifest.Assets["app.js"]
	original, err := fs.ReadFile(root, "app.js")
	if err != nil {
		t.Fatal(err)
	}
	etags := map[string]string{}
	for _, encoding := range []string{"br", "gzip", "identity"} {
		t.Run(encoding, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/app.js?v="+asset.SHA256, nil)
			req.Header.Set("Accept-Encoding", encoding)
			res := httptest.NewRecorder()
			if !serveStaticAsset(res, req, root, manifest, "app.js") {
				t.Fatal("asset not handled")
			}
			if res.Code != 200 {
				t.Fatalf("status %d", res.Code)
			}
			wantEncoding := encoding
			if encoding == "identity" {
				wantEncoding = ""
			}
			if res.Header().Get("Content-Encoding") != wantEncoding {
				t.Fatal("wrong encoding")
			}
			if res.Header().Get("Cache-Control") != "public, max-age=31536000, immutable" || res.Header().Get("Vary") != "Accept-Encoding" {
				t.Fatal("wrong cache policy")
			}
			if !strings.Contains(res.Header().Get("Content-Type"), "javascript") {
				t.Fatal("wrong media type")
			}
			body := res.Body.Bytes()
			switch encoding {
			case "gzip":
				reader, err := gzip.NewReader(bytes.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				decoded, err := io.ReadAll(reader)
				reader.Close()
				if err != nil || !bytes.Equal(decoded, original) {
					t.Fatal("gzip changed bytes")
				}
			case "br":
				expected, err := fs.ReadFile(root, asset.Brotli.File)
				if err != nil || !bytes.Equal(body, expected) {
					t.Fatal("Brotli payload mismatch")
				}
			default:
				if !bytes.Equal(body, original) {
					t.Fatal("identity changed bytes")
				}
			}
			etag := res.Header().Get("ETag")
			if etag == "" {
				t.Fatal("missing ETag")
			}
			etags[encoding] = etag
			req.Header.Set("If-None-Match", etag)
			res = httptest.NewRecorder()
			serveStaticAsset(res, req, root, manifest, "app.js")
			if res.Code != 304 || res.Body.Len() != 0 {
				t.Fatal("conditional GET failed")
			}
			req = httptest.NewRequest(http.MethodHead, "/app.js", nil)
			req.Header.Set("Accept-Encoding", encoding)
			res = httptest.NewRecorder()
			serveStaticAsset(res, req, root, manifest, "app.js")
			if res.Code != 200 || res.Body.Len() != 0 || res.Header().Get("Content-Length") == "" {
				t.Fatal("HEAD failed")
			}
			if res.Header().Get("Cache-Control") != "public, max-age=0, must-revalidate" {
				t.Fatal("unversioned assets must revalidate")
			}
		})
	}
	if etags["br"] == etags["gzip"] || etags["gzip"] == etags["identity"] {
		t.Fatal("encoded ETags must differ")
	}
	req := httptest.NewRequest(http.MethodGet, "/app.js?v=stale", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	req.Header.Set("If-None-Match", etags["br"])
	res := httptest.NewRecorder()
	serveStaticAsset(res, req, root, manifest, "app.js")
	if res.Code != 200 || strings.Contains(res.Header().Get("Cache-Control"), "immutable") {
		t.Fatal("stale fingerprint or other encoding reused")
	}
	req.Header.Set("Accept-Encoding", "*;q=0")
	res = httptest.NewRecorder()
	serveStaticAsset(res, req, root, manifest, "app.js")
	if res.Code != 406 || res.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("refused encodings must not be cached")
	}
}

func TestStaticShellVersioningAndPrivateBoundaries(t *testing.T) {
	for _, mode := range []string{"windows", "nas", "linux", "mac"} {
		t.Run(mode, func(t *testing.T) {
			server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), RuntimeMode: mode, Version: "test"})
			if err != nil {
				t.Fatal(err)
			}
			root, err := fs.Sub(embeddedWeb, "web")
			if err != nil {
				t.Fatal(err)
			}
			manifest := readStaticAssetManifest(root)
			res := requestForTest(server, http.MethodGet, "/", nil, nil)
			if res.Code != 200 || res.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("shell status/cache %d/%q", res.Code, res.Header().Get("Cache-Control"))
			}
			if !strings.Contains(res.Body.String(), "/app.js?v="+manifest.Assets["app.js"].SHA256) {
				t.Fatal("versioned URL missing")
			}
			if mode == "windows" && !strings.Contains(res.Body.String(), "og:image") {
				t.Fatal("dynamic metadata lost")
			}
			for _, target := range []string{"/api/v1/config", "/api/v1/status", "/preview/missing", "/precompressed/manifest.json"} {
				res = requestForTest(server, http.MethodGet, target, nil, nil)
				if strings.Contains(res.Header().Get("Cache-Control"), "public") || res.Header().Get("Content-Encoding") != "" {
					t.Fatalf("private/internal response cached: %s", target)
				}
			}
		})
	}
}
