package manager

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPreviewIndexAndSandboxBase(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	output := filepath.Join(root, "output")
	if err := os.MkdirAll(output, 0o700); err != nil {
		t.Fatal(err)
	}
	const document = "<!doctype html><html><head><title>Preview</title></head><body>Safe</body></html>"
	if err := os.WriteFile(filepath.Join(output, "preview_test.html"), []byte(document), 0o600); err != nil {
		t.Fatal(err)
	}

	previews, paths := listPreviews(root)
	if len(previews) != 1 {
		t.Fatalf("got %d previews, want 1", len(previews))
	}
	if paths[previews[0].ID] == "" {
		t.Fatal("opaque preview ID did not resolve")
	}
	recorder := httptest.NewRecorder()
	servePreview(recorder, paths[previews[0].ID])
	if recorder.Code != http.StatusOK {
		t.Fatalf("preview status: got %d", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "<base href=\"/preview-content/output/\">") {
		t.Fatal("preview response did not inject the authenticated asset base")
	}
	if !strings.Contains(recorder.Header().Get("Content-Security-Policy"), "sandbox allow-same-origin") {
		t.Fatal("preview response is missing its sandbox policy")
	}
}

func TestPreviewIndexIgnoresNonPreviewHTML(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	output := filepath.Join(root, "output")
	if err := os.MkdirAll(output, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(output, "unrelated.html"), []byte("<html></html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	previews, _ := listPreviews(root)
	if len(previews) != 0 {
		t.Fatalf("indexed non-preview HTML: %+v", previews)
	}
}

func TestPreviewAssetsRejectTraversal(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	request := httptest.NewRequest(http.MethodGet, "/preview-content/secret.png", nil)
	recorder := httptest.NewRecorder()
	servePreviewAsset(recorder, request, root, "../secret.png")
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("traversal status: got %d, want 404", recorder.Code)
	}
}

func TestPreviewAssetsServeOnlyOutputAndPackageImages(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	fixtures := []struct {
		requested string
		path      string
	}{
		{requested: "output/posters/fictional.jpg", path: filepath.Join(root, "output", "posters", "fictional.jpg")},
		{requested: "output/media/fictional.png", path: filepath.Join(root, "output", "media", "fictional.png")},
		{requested: "assets/hot.gif", path: filepath.Join(root, "assets", "hot.gif")},
	}
	for _, fixture := range fixtures {
		if err := os.MkdirAll(filepath.Dir(fixture.path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fixture.path, []byte("fictional-image"), 0o600); err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodGet, "/preview-content/"+fixture.requested, nil)
		recorder := httptest.NewRecorder()
		servePreviewAsset(recorder, request, root, fixture.requested)
		if recorder.Code != http.StatusOK {
			t.Fatalf("asset %q status: got %d, want 200", fixture.requested, recorder.Code)
		}
	}

	request := httptest.NewRequest(http.MethodGet, "/preview-content/private/secret.png", nil)
	recorder := httptest.NewRecorder()
	servePreviewAsset(recorder, request, root, "private/secret.png")
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("unsupported namespace status: got %d, want 404", recorder.Code)
	}
}

func TestPreviewAssetsRejectSymlinkEscape(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	outside := t.TempDir()
	assetRoot := filepath.Join(root, "assets")
	if err := os.MkdirAll(assetRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(outside, "secret.png")
	if err := os.WriteFile(secret, []byte("private-image"), 0o600); err != nil {
		t.Fatal(err)
	}
	linked := filepath.Join(assetRoot, "linked.png")
	if err := os.Symlink(secret, linked); err != nil {
		t.Skipf("symlink creation is unavailable on this host: %v", err)
	}

	request := httptest.NewRequest(http.MethodGet, "/preview-content/assets/linked.png", nil)
	recorder := httptest.NewRecorder()
	servePreviewAsset(recorder, request, root, "assets/linked.png")
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("symlink escape status: got %d, want 404", recorder.Code)
	}
}

func TestPathWithinRootRejectsSibling(t *testing.T) {
	t.Parallel()
	root := filepath.Join(t.TempDir(), "assets")
	if !pathWithinRoot(root, filepath.Join(root, "posters", "fictional.jpg")) {
		t.Fatal("contained preview asset was rejected")
	}
	if pathWithinRoot(root, root+"-private") {
		t.Fatal("sibling path with a shared prefix was accepted")
	}
}
