// Command kubectl-tenant onboards a team onto the platform the way
// docs/onboarding-a-tenant.md describes, and checks a tenant's manifests
// before anyone reviews them. On PATH it is a kubectl plugin:
//
//	kubectl tenant new payments      # apps/payments from apps/_template
//	kubectl tenant check payments    # what admission will refuse, offline
//
// Both run from the repository root, or with -root pointing at it.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

const usage = `usage:
  kubectl tenant new <name> [-root DIR]     create apps/<name> from apps/_template
  kubectl tenant check <name> [-root DIR]   report what admission would refuse in apps/<name>
`

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(stderr)
	root := fs.String("root", ".", "the repository root")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	name := fs.Arg(0)

	switch args[0] {
	case "new":
		if err := newTenant(*root, name); err != nil {
			fmt.Fprintln(stderr, "error:", err)
			return 1
		}
		fmt.Fprintf(stdout, "created apps/%s from apps/_template\n", name)
		fmt.Fprintf(stdout, "next: replace the example service in apps/%s/base/app.yaml, open the paths it needs in network-policies.yaml, then: kubectl tenant check %s\n", name, name)
		return 0
	case "check":
		findings, err := checkTenant(*root, name)
		if err != nil {
			fmt.Fprintln(stderr, "error:", err)
			return 1
		}
		for _, f := range findings {
			fmt.Fprintln(stdout, f)
		}
		if len(findings) > 0 {
			fmt.Fprintf(stdout, "apps/%s: %d finding(s); admission would refuse these\n", name, len(findings))
			return 1
		}
		fmt.Fprintf(stdout, "apps/%s: nothing admission would refuse\n", name)
		return 0
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
}
