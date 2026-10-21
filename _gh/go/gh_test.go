package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSlug(t *testing.T) {
	for in, want := range map[string]string{
		"git@github-personal:someuser/somerepo.git": "someuser/somerepo",
		"git@github-work:acme/widgets":              "acme/widgets",
		"git@github.com:owner/repo.git":             "owner/repo",
		"https://github.com/owner/repo.git":         "owner/repo",
		"https://github.com/owner/repo":             "owner/repo",
		"https://user@github.com/owner/repo.git":    "owner/repo",
		"ssh://git@github.com/owner/repo.git":       "owner/repo",
		"git://github.com/owner/repo.git":           "owner/repo",
	} {
		if got := parseSlug(in); got != want {
			t.Errorf("parseSlug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseAccounts(t *testing.T) {
	doc := `{"hosts":{"github.com":[
	 {"state":"success","active":true,"login":"alice"},
	 {"state":"error","active":false,"login":"dead"},
	 {"state":"success","active":false,"login":"bob"}],
	 "ghe.example.com":[{"state":"success","login":"other"}]}}`
	got, err := parseAccounts([]byte(doc))
	if err != nil || strings.Join(got, ",") != "alice,bob" {
		t.Fatalf("got %v, %v; want alice,bob (state success, github.com only, order kept)", got, err)
	}
	if got, _ := parseAccounts([]byte(`{"hosts":{}}`)); len(got) != 0 {
		t.Errorf("missing host should yield no accounts, got %v", got)
	}
	if _, err := parseAccounts([]byte("Logged in to github.com account x")); err == nil {
		t.Error("prose must not parse as JSON")
	}
}

func TestPermissionError(t *testing.T) {
	for _, s := range []string{"GraphQL: must be a collaborator (x)", "Resource not accessible by integration", "HTTP 403", "requires push access", "must have write access"} {
		if !permissionError(s) {
			t.Errorf("%q should be permission-shaped", s)
		}
	}
	for _, s := range []string{"HTTP 500: boom", "HTTP 404 Not Found", ""} {
		if permissionError(s) {
			t.Errorf("%q should not be permission-shaped", s)
		}
	}
}

func fakeEnv(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	src, err := os.ReadFile("../../tests/fixtures/gh/fake-gh.sh")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "gh"), src, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TMPDIR", dir)
	t.Setenv("USER", "gotest")
	return dir
}

func TestCacheRoundTrip(t *testing.T) {
	fakeEnv(t)
	if cacheFile() == "" || !strings.HasSuffix(cacheFile(), "/.gh-account-cache-gotest") {
		t.Fatalf("cache path %q", cacheFile())
	}
	cacheAppend("o/r", "alice")
	cacheAppend("o/r", "bob")
	cacheAppend("o/x", "carol")
	if got := cacheLookup("o/r"); got != "alice" {
		t.Errorf("first match wins, got %q", got)
	}
	cacheInvalidate("o/r", "alice")
	if got := cacheLookup("o/r"); got != "bob" {
		t.Errorf("after invalidate got %q, want bob", got)
	}
	if got := cacheLookup("o/x"); got != "carol" {
		t.Errorf("unrelated entry lost, got %q", got)
	}
}

func TestPickPrefersWrite(t *testing.T) {
	fakeEnv(t)
	t.Setenv("FAKE_GH_ACCOUNTS", "alice bob")
	t.Setenv("FAKE_GH_PERM", "alice-token:false bob-token:true")
	u, err := pickAccount("o/r")
	if err != nil || u != "bob" {
		t.Fatalf("got %q, %v; want bob (write beats earlier read-only)", u, err)
	}
	if cacheLookup("o/r") != "bob" {
		t.Error("pick not cached")
	}
}

func TestPickReadFallbackAndNone(t *testing.T) {
	fakeEnv(t)
	t.Setenv("FAKE_GH_ACCOUNTS", "alice")
	t.Setenv("FAKE_GH_PERM", "alice-token:false")
	if u, err := pickAccount("o/r"); err != nil || u != "alice" {
		t.Fatalf("read-only fallback: got %q, %v", u, err)
	}
	t.Setenv("FAKE_GH_PERM", "")
	if _, err := pickAccount("o/none"); err != errNoAccount {
		t.Fatalf("want errNoAccount, got %v", err)
	}
}

func TestInvalidAccountSkipped(t *testing.T) {
	fakeEnv(t)
	t.Setenv("FAKE_GH_ACCOUNTS", "dead alice")
	t.Setenv("FAKE_GH_INVALID", "dead")
	t.Setenv("FAKE_GH_PERM", "dead-token:true alice-token:true")
	if u, err := pickAccount("o/r"); err != nil || u != "alice" {
		t.Fatalf("got %q, %v; want alice (non-success state skipped, stdout parsed despite exit 1)", u, err)
	}
}

func TestJSONUnsupported(t *testing.T) {
	fakeEnv(t)
	t.Setenv("FAKE_GH_NO_JSON", "1")
	if _, err := pickAccount("o/r"); err != errJSONUnsupported {
		t.Fatalf("want errJSONUnsupported, got %v", err)
	}
}

func TestEnvWithTokenReplaces(t *testing.T) {
	t.Setenv("GH_TOKEN", "old")
	n := 0
	for _, kv := range envWithToken("new") {
		if strings.HasPrefix(kv, "GH_TOKEN=") {
			n++
			if kv != "GH_TOKEN=new" {
				t.Errorf("got %q", kv)
			}
		}
	}
	if n != 1 {
		t.Errorf("GH_TOKEN appears %d times", n)
	}
}

func TestRunUsage(t *testing.T) {
	var b bytes.Buffer
	if run(nil, &b) != 2 || !strings.Contains(b.String(), "usage") {
		t.Error("expected usage error")
	}
}
