package main

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Same file and tab-separated format as the bash wrapper, so both interoperate.
func cacheFile() string {
	tmp, user := os.Getenv("TMPDIR"), os.Getenv("USER")
	if tmp == "" {
		tmp = "/tmp"
	}
	if user == "" {
		user = "anon"
	}
	return tmp + "/.gh-account-cache-" + user
}

func readCache() [][2]string {
	f, err := os.Open(cacheFile())
	if err != nil {
		return nil
	}
	defer f.Close()
	var rows [][2]string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if p := strings.Split(sc.Text(), "\t"); len(p) >= 2 {
			rows = append(rows, [2]string{p[0], p[1]})
		}
	}
	return rows
}

func cacheLookup(slug string) string {
	for _, r := range readCache() {
		if r[0] == slug {
			return r[1]
		}
	}
	return ""
}

// Best effort: a failed cache write must never block an already-found account.
func cacheAppend(slug, user string) {
	f, err := os.OpenFile(cacheFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(slug + "\t" + user + "\n")
}

func cacheInvalidate(slug, user string) {
	rows := readCache()
	var b strings.Builder
	for _, r := range rows {
		if !(r[0] == slug && r[1] == user) {
			b.WriteString(r[0] + "\t" + r[1] + "\n")
		}
	}
	f, err := os.CreateTemp(filepath.Dir(cacheFile()), ".gh-account-cache-tmp-*")
	if err != nil {
		return
	}
	_, werr := f.WriteString(b.String())
	f.Close()
	if werr != nil || os.Rename(f.Name(), cacheFile()) != nil {
		os.Remove(f.Name())
	}
}

// tier: "write", "read", or "" when the account cannot see the repo.
func accountTier(slug, tok string) string {
	cmd := exec.Command("gh", "api", "repos/"+slug, "--jq", ".permissions.push")
	cmd.Env = envWithToken(tok)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	if strings.TrimSpace(string(out)) == "true" {
		return "write"
	}
	return "read"
}

var errNoAccount = errors.New("no account")

func pickAccount(slug string) (string, error) {
	if c := cacheLookup(slug); c != "" {
		if _, err := tokenFor(c); err == nil {
			return c, nil
		}
	}
	accts, err := listAccounts()
	if err != nil {
		return "", err
	}
	bestRead := ""
	for _, u := range accts {
		tok, err := tokenFor(u)
		if err != nil {
			continue
		}
		switch accountTier(slug, tok) {
		case "write":
			cacheAppend(slug, u)
			return u, nil
		case "read":
			if bestRead == "" {
				bestRead = u
			}
		}
	}
	if bestRead != "" {
		cacheAppend(slug, bestRead)
		return bestRead, nil
	}
	return "", errNoAccount
}

var permErrRe = regexp.MustCompile(`(?i)must be a collaborator|resource not accessible|http 403|requires? (push|write) access|must have (push|write) access`)

func permissionError(stderr string) bool { return permErrRe.MatchString(stderr) }
