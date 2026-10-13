package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// The rules platform/tenant/templates/_helpers.tpl enforces when the chart
// renders, so a name the chart would refuse is refused here first.
var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

func validateName(name string, reserved []string) error {
	if !dnsLabel.MatchString(name) {
		return fmt.Errorf("%q is not a DNS label: lowercase letters, digits and hyphens, at most 63, starting and ending with a letter or digit", name)
	}
	for _, prefix := range []string{"kube-", "tenant-"} {
		if strings.HasPrefix(name, prefix) {
			return fmt.Errorf("%q starts with %s, which the platform keeps for itself", name, prefix)
		}
	}
	for _, r := range reserved {
		if r == name {
			return fmt.Errorf("%q is a platform name (reserved in platform/tenant/values.yaml); a tenant cannot take it", name)
		}
	}
	return nil
}

// reservedNames reads the list the chart reads, so the two cannot disagree.
func reservedNames(root string) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(root, "platform", "tenant", "values.yaml"))
	if err != nil {
		return nil, err
	}
	var values struct {
		Reserved []string `yaml:"reserved"`
	}
	if err := yaml.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("platform/tenant/values.yaml: %w", err)
	}
	if len(values.Reserved) == 0 {
		return nil, errors.New("platform/tenant/values.yaml lists no reserved names; refusing to guess")
	}
	return values.Reserved, nil
}

// The template's instruction to a person, which is done once the tool has run.
const templateNote = "# A tenant: one service, its route and the network paths it needs. Replace\n" +
	"# TEAM everywhere with the team's name (lowercase, a DNS label), which is\n" +
	"# also the directory name under apps/."

func newTenant(root, name string) error {
	reserved, err := reservedNames(root)
	if err != nil {
		return err
	}
	if err := validateName(name, reserved); err != nil {
		return err
	}
	src := filepath.Join(root, "apps", "_template")
	dst := filepath.Join(root, "apps", name)
	if _, err := os.Stat(dst); err == nil {
		return fmt.Errorf("apps/%s already exists", name)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}

	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		// The template's README explains the template; the tenant does not need it.
		if rel == "README.md" {
			return nil
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		text := strings.Replace(string(raw), templateNote,
			"# The tenant "+name+", made from apps/_template by kubectl-tenant.", 1)
		text = strings.ReplaceAll(text, "TEAM", name)
		info, err := d.Info()
		if err != nil {
			return err
		}
		return os.WriteFile(target, []byte(text), info.Mode().Perm())
	})
}
