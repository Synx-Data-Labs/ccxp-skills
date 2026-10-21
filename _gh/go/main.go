// Command ccxp-gh is the compiled counterpart of _gh/gh.sh and _gh/git.sh
// (T20261020-231370). Usage: `ccxp-gh gh <gh args...>` or `ccxp-gh git <git args...>`.
//
// It picks the authenticated gh account with access to the repo at $PWD's
// `origin` (preferring write access) and runs gh/git with that account's
// token in GH_TOKEN (process-scoped, never in argv). Accounts come from the
// structured `gh auth status --json hosts`, never from parsing prose.
//
// The bash wrappers remain the default; they exec this binary only when
// CCXP_GH_GO=1 and a built binary exists. Build with _gh/go/build.sh.
package main

import (
	"fmt"
	"io"
	"os"
)

func main() { os.Exit(run(os.Args[1:], os.Stderr)) }

func run(args []string, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "gh" && args[0] != "git") {
		fmt.Fprintln(stderr, "usage: ccxp-gh gh|git <args...>")
		return 2
	}
	mode, rest := args[0], args[1:]
	prog := mode + ".sh" // error prefix matches the bash wrappers' ${0##*/}
	if mode == "gh" {
		return runGH(prog, rest, stderr)
	}
	return runGit(prog, rest, stderr)
}
