package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// What the platform's admission policies require of every workload in a
// tenant namespace (policies/): an image by digest, requests and a
// memory limit, readiness and liveness probes, and no privilege. Checked here
// on the files, so a team hears it before review instead of from a refused
// sync.
var podSpecPath = map[string][]string{
	"Pod":         {"spec"},
	"Deployment":  {"spec", "template", "spec"},
	"StatefulSet": {"spec", "template", "spec"},
	"DaemonSet":   {"spec", "template", "spec"},
	"ReplicaSet":  {"spec", "template", "spec"},
	"Job":         {"spec", "template", "spec"},
	"CronJob":     {"spec", "jobTemplate", "spec", "template", "spec"},
}

func checkTenant(root, name string) ([]string, error) {
	dir := filepath.Join(root, "apps", name, "base")
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("apps/%s/base has no manifests", name)
	}
	sort.Strings(files)
	var findings []string
	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		rel, _ := filepath.Rel(root, file)
		docs, err := decodeAll(raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", rel, err)
		}
		for _, doc := range docs {
			findings = append(findings, checkDoc(rel, doc)...)
		}
	}
	return findings, nil
}

func decodeAll(raw []byte) ([]map[string]any, error) {
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	var docs []map[string]any
	for {
		var doc map[string]any
		err := dec.Decode(&doc)
		if errors.Is(err, io.EOF) {
			return docs, nil
		}
		if err != nil {
			return nil, err
		}
		if doc != nil {
			docs = append(docs, doc)
		}
	}
}

func checkDoc(file string, doc map[string]any) []string {
	kind, _ := doc["kind"].(string)
	path, ok := podSpecPath[kind]
	if !ok {
		return nil
	}
	name, _ := dig(doc, "metadata", "name").(string)
	spec, _ := dig(doc, path...).(map[string]any)
	if spec == nil {
		return []string{fmt.Sprintf("%s: %s/%s has no pod spec", file, kind, name)}
	}
	var out []string
	where := func(c string) string { return fmt.Sprintf("%s: %s/%s container %s", file, kind, name, c) }
	if v, _ := spec["hostNetwork"].(bool); v {
		out = append(out, fmt.Sprintf("%s: %s/%s uses the host network", file, kind, name))
	}
	for _, list := range []string{"initContainers", "containers"} {
		items, _ := spec[list].([]any)
		for _, item := range items {
			c, _ := item.(map[string]any)
			cname, _ := c["name"].(string)
			image, _ := c["image"].(string)
			if !strings.Contains(image, "@sha256:") {
				out = append(out, where(cname)+": image "+image+" is not referenced by digest")
			}
			if dig(c, "resources", "requests", "cpu") == nil || dig(c, "resources", "requests", "memory") == nil {
				out = append(out, where(cname)+": no CPU and memory requests")
			}
			if dig(c, "resources", "limits", "memory") == nil {
				out = append(out, where(cname)+": no memory limit")
			}
			if v, _ := dig(c, "securityContext", "privileged").(bool); v {
				out = append(out, where(cname)+": privileged")
			}
			if list == "containers" {
				if c["readinessProbe"] == nil {
					out = append(out, where(cname)+": no readiness probe")
				}
				if c["livenessProbe"] == nil {
					out = append(out, where(cname)+": no liveness probe")
				}
			}
		}
	}
	return out
}

func dig(m map[string]any, keys ...string) any {
	var cur any = m
	for _, k := range keys {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}
