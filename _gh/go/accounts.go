package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
)

const ghHost = "github.com"

var errJSONUnsupported = errors.New("this gh does not support `gh auth status --json` (upgrade gh, or unset CCXP_GH_GO to use the bash wrapper)")

type authEntry struct {
	Login  string `json:"login"`
	State  string `json:"state"`
	Active bool   `json:"active"`
}

// parseAccounts extracts usable logins for github.com from the
// `gh auth status --json hosts` document: state "success" only, in order.
func parseAccounts(doc []byte) ([]string, error) {
	var v struct {
		Hosts map[string][]authEntry `json:"hosts"`
	}
	if err := json.Unmarshal(doc, &v); err != nil {
		return nil, err
	}
	var logins []string
	for _, e := range v.Hosts[ghHost] {
		if e.State == "success" && e.Login != "" {
			logins = append(logins, e.Login)
		}
	}
	return logins, nil
}

// listAccounts parses stdout regardless of exit status: gh exits non-zero
// when any stored token is invalid, yet still prints the document.
func listAccounts() ([]string, error) {
	cmd := exec.Command("gh", "auth", "status", "--json", "hosts")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	runErr := cmd.Run()
	if stdout.Len() == 0 {
		if strings.Contains(stderr.String(), "unknown flag") || strings.Contains(stderr.String(), "--json") {
			return nil, errJSONUnsupported
		}
		if runErr != nil {
			return nil, nil // nothing authenticated -> caller reports "no account"
		}
	}
	return parseAccounts(stdout.Bytes())
}

func tokenFor(user string) (string, error) {
	out, err := exec.Command("gh", "auth", "token", "--user", user).Output()
	if err != nil {
		return "", err
	}
	tok := strings.TrimSpace(string(out))
	if tok == "" {
		return "", errors.New("empty token")
	}
	return tok, nil
}

// envWithToken returns the environment with GH_TOKEN replaced (never duplicated).
func envWithToken(tok string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GH_TOKEN=") {
			env = append(env, kv)
		}
	}
	return append(env, "GH_TOKEN="+tok)
}
