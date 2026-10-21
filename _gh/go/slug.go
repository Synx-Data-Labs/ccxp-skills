package main

import (
	"os/exec"
	"regexp"
	"strings"
)

var (
	slugSchemeRe = regexp.MustCompile(`^[a-z]+://([^@/]+@)?[^/]+/`)
	slugScpRe    = regexp.MustCompile(`^[^/:]+@[^:]+:`)
	slugGitRe    = regexp.MustCompile(`\.git$`)
)

// parseSlug mirrors _gh_repo_slug's three sed rules, applied in order.
func parseSlug(url string) string {
	s := slugSchemeRe.ReplaceAllString(url, "")
	s = slugScpRe.ReplaceAllString(s, "")
	return slugGitRe.ReplaceAllString(s, "")
}

func repoSlug() (string, error) {
	out, err := exec.Command("git", "remote", "get-url", "origin").Output()
	if err != nil {
		return "", err
	}
	return parseSlug(strings.TrimRight(string(out), "\r\n")), nil
}
