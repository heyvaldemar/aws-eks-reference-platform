package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The repository this tool works on, two directories up.
const repo = "../.."

func TestValidateName(t *testing.T) {
	reserved, err := reservedNames(repo)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		ok   bool
	}{
		{"payments", true},
		{"team-b", true},
		{"a1", true},
		{"Payments", false},
		{"-payments", false},
		{"payments-", false},
		{"pay_ments", false},
		{strings.Repeat("a", 64), false},
		{"kube-payments", false},
		{"tenant-payments", false},
		{"argocd", false},
		{"monitoring", false},
	} {
		err := validateName(tc.name, reserved)
		if (err == nil) != tc.ok {
			t.Errorf("validateName(%q) = %v, want ok=%v", tc.name, err, tc.ok)
		}
	}
}

// copyTree copies the parts of the repository the tool reads into a scratch
// root, so a test can write apps/<name> without touching the checkout.
func scratchRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, rel := range []string{"apps/_template", "platform/tenant/values.yaml"} {
		src := filepath.Join(repo, rel)
		err := filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			r, _ := filepath.Rel(repo, path)
			dst := filepath.Join(root, r)
			if info.IsDir() {
				return os.MkdirAll(dst, 0o755)
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			raw, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(dst, raw, info.Mode().Perm())
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// withoutComments drops comment lines, the one place a tenant made by hand
// may differ from one made by the tool.
func withoutComments(raw []byte) string {
	var keep []string
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		keep = append(keep, line)
	}
	return strings.Join(keep, "\n")
}

// apps/team-b was made from the template by hand, the way the onboarding
// guide says. The tool must produce the same tenant, or one of them is wrong.
func TestNewMatchesTheTenantMadeByHand(t *testing.T) {
	root := scratchRoot(t)
	if err := newTenant(root, "team-b"); err != nil {
		t.Fatal(err)
	}
	made := filepath.Join(root, "apps", "team-b")
	byHand := filepath.Join(repo, "apps", "team-b")
	var count int
	err := filepath.Walk(byHand, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(byHand, path)
		want, _ := os.ReadFile(path)
		got, err := os.ReadFile(filepath.Join(made, rel))
		if err != nil {
			t.Errorf("the tool did not make %s", rel)
			return nil
		}
		if withoutComments(got) != withoutComments(want) {
			t.Errorf("%s differs from the tenant made by hand", rel)
		}
		count++
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("apps/team-b has no files to compare")
	}
	if _, err := os.Stat(filepath.Join(made, "README.md")); err == nil {
		t.Error("the template's README was copied into the tenant")
	}
}

func TestNewRefusesAnExistingTenant(t *testing.T) {
	root := scratchRoot(t)
	if err := newTenant(root, "payments"); err != nil {
		t.Fatal(err)
	}
	if err := newTenant(root, "payments"); err == nil {
		t.Fatal("a second new payments was accepted")
	}
}

func TestNewRefusesAReservedName(t *testing.T) {
	root := scratchRoot(t)
	if err := newTenant(root, "argocd"); err == nil {
		t.Fatal("a tenant named argocd was created")
	}
	if _, err := os.Stat(filepath.Join(root, "apps", "argocd")); err == nil {
		t.Fatal("apps/argocd exists after a refusal")
	}
}

func TestCheckPassesTheTemplate(t *testing.T) {
	root := scratchRoot(t)
	if err := newTenant(root, "payments"); err != nil {
		t.Fatal(err)
	}
	findings, err := checkTenant(root, "payments")
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("a tenant straight from the template has findings: %v", findings)
	}
}

// Each planted violation must be found, with a message that names it.
func TestCheckFindsEachViolation(t *testing.T) {
	for _, tc := range []struct {
		plant, old, new, want string
	}{
		{"an image by tag", "podinfo:6.15.0@sha256:ec73780a8425f59ea49f5bc8cdff0d598805a224fbaa1f86c67a244f250fa9da", "podinfo:6.15.0", "not referenced by digest"},
		{"no memory limit", "            limits: {memory: 128Mi}\n", "", "no memory limit"},
		{"no requests", "            requests: {cpu: 10m, memory: 32Mi}\n", "", "no CPU and memory requests"},
		{"no readiness probe", "          readinessProbe:\n            httpGet: {path: /readyz, port: http}\n", "", "no readiness probe"},
		{"no liveness probe", "          livenessProbe:\n            httpGet: {path: /healthz, port: http}\n", "", "no liveness probe"},
		{"a privileged container", "            allowPrivilegeEscalation: false\n", "            privileged: true\n", "privileged"},
	} {
		t.Run(tc.plant, func(t *testing.T) {
			root := scratchRoot(t)
			if err := newTenant(root, "payments"); err != nil {
				t.Fatal(err)
			}
			app := filepath.Join(root, "apps", "payments", "base", "app.yaml")
			raw, _ := os.ReadFile(app)
			if !bytes.Contains(raw, []byte(tc.old)) {
				t.Fatalf("the template no longer contains %q; the plant is stale", tc.old)
			}
			if err := os.WriteFile(app, bytes.Replace(raw, []byte(tc.old), []byte(tc.new), 1), 0o644); err != nil {
				t.Fatal(err)
			}
			findings, err := checkTenant(root, "payments")
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(strings.Join(findings, "\n"), tc.want) {
				t.Fatalf("%s was not found; findings: %v", tc.plant, findings)
			}
		})
	}
}

func TestRunExitCodes(t *testing.T) {
	root := scratchRoot(t)
	var out, errOut bytes.Buffer
	if code := run([]string{"new", "-root", root, "payments"}, &out, &errOut); code != 0 {
		t.Fatalf("new: exit %d, %s", code, errOut.String())
	}
	if code := run([]string{"check", "-root", root, "payments"}, &out, &errOut); code != 0 {
		t.Fatalf("check on a clean tenant: exit %d, %s", code, out.String())
	}
	if code := run([]string{"new", "-root", root, "kube-x"}, &out, &errOut); code != 1 {
		t.Fatalf("new kube-x: exit %d, want 1", code)
	}
	if code := run(nil, &out, &errOut); code != 2 {
		t.Fatalf("no arguments: exit %d, want 2", code)
	}
}
