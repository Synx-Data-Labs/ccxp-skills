package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// resolve picks the account for $PWD's origin, with the bash wrapper's messages.
func resolve(prog string, stderr io.Writer) (slug, user, tok string, ok bool) {
	die := func(msg string) { fmt.Fprintf(stderr, "%s: %s\n", prog, msg) }
	slug, err := repoSlug()
	if err != nil {
		cwd, _ := os.Getwd()
		die("no github 'origin' remote in " + cwd)
		return
	}
	if !strings.Contains(slug, "/") {
		die("could not parse owner/repo from origin URL")
		return
	}
	user, err = pickAccount(slug)
	if err != nil {
		if errors.Is(err, errNoAccount) {
			die("no authenticated gh account has access to " + slug + " (try: gh auth login)")
		} else {
			die(err.Error())
		}
		return
	}
	return slug, user, "", true
}

// exitCode follows bash: 128+N when the child died on signal N.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return 127
}

func runGH(prog string, args []string, stderr io.Writer) int {
	slug, user, _, ok := resolve(prog, stderr)
	if !ok {
		return 1
	}
	tok, err := tokenFor(user)
	if err != nil {
		fmt.Fprintf(stderr, "%s: could not read token for account %s\n", prog, user)
		return 1
	}
	// stdout streams through; stderr is buffered and relayed after the
	// command (like the bash wrapper) so a permission failure can be retried.
	attempt := func(tok string) (int, []byte) {
		var eb bytes.Buffer
		cmd := exec.Command("gh", args...)
		cmd.Env = envWithToken(tok)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, &eb
		return exitCode(cmd.Run()), eb.Bytes()
	}
	status, eb := attempt(tok)
	if status != 0 && permissionError(string(eb)) {
		cacheInvalidate(slug, user)
		if ru, err := pickAccount(slug); err == nil && ru != user {
			if rt, err := tokenFor(ru); err == nil {
				status, eb = attempt(rt)
			}
		}
	}
	stderr.Write(eb)
	return status
}

func runGit(prog string, args []string, stderr io.Writer) int {
	_, user, _, ok := resolve(prog, stderr)
	if !ok {
		return 1
	}
	wireCredentials() // after a successful pick, before the token read (as in git.sh)
	tok, err := tokenFor(user)
	if err != nil {
		fmt.Fprintf(stderr, "%s: could not read token for account %s\n", prog, user)
		return 1
	}
	path, err := exec.LookPath("git")
	if err != nil {
		fmt.Fprintf(stderr, "%s: git not found in PATH\n", prog)
		return 127
	}
	// exec: token reaches git via environment only, never argv.
	err = syscall.Exec(path, append([]string{"git"}, args...), envWithToken(tok))
	fmt.Fprintf(stderr, "%s: exec git: %v\n", prog, err)
	return 126
}

// Repo-local config only; errors swallowed, like _git_wire_credentials.
func wireCredentials() {
	for _, a := range [][]string{
		{"--unset-all", "credential.helper"},
		{"--add", "credential.helper", ""},
		{"--add", "credential.helper", "!gh auth git-credential"},
		{"--unset-all", "url.https://github.com/.insteadOf"},
		{"--add", "url.https://github.com/.insteadOf", "git@github.com:"},
		{"--add", "url.https://github.com/.insteadOf", "ssh://git@github.com/"},
	} {
		exec.Command("git", append([]string{"config", "--local"}, a...)...).Run()
	}
}
