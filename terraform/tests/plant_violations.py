#!/usr/bin/env python3
"""Every promise in tests/posture.tftest.hcl, broken on a copy, has to be noticed.

    TERRAFORM_IMAGE=<pinned image> terraform/tests/plant_violations.py   (CI)
    TERRAFORM_BIN=terraform terraform/tests/plant_violations.py          (a local binary)

A test that cannot fail is not a test. Each line of tests/plants.tsv names a
file, a piece of it and its replacement, and each one breaks one property the
posture test asserts: an API endpoint open to the internet, IMDSv1 on nodes,
a controller's Pod Identity bound to the wrong namespace, a backup bucket
allowed to go public. The untouched copy has to pass; each planted copy has
to fail. A plant whose text is no longer in the file fails the run too, so
the test cannot fall behind the configuration unnoticed.

The configuration's .terraform directory (from `terraform init`) is mounted
into each copy rather than copied, so the providers are not duplicated.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.environ.get("TERRAFORM_IMAGE")
BIN = os.environ.get("TERRAFORM_BIN")


def terraform_test(d):
    if IMAGE:
        cmd = ["docker", "run", "--rm", "-v", "%s:/mnt" % d,
               "-v", "%s:/mnt/.terraform" % os.path.join(ROOT, ".terraform"),
               "-w", "/mnt", IMAGE, "test", "-no-color"]
        return subprocess.run(cmd, capture_output=True, text=True)
    return subprocess.run([BIN, "test", "-no-color"], capture_output=True, text=True, cwd=d,
                          env=dict(os.environ, CHECKPOINT_DISABLE="1"))


def copy():
    work = tempfile.mkdtemp(prefix="plant-", dir=os.environ.get("RUNNER_TEMP"))
    shutil.copytree(ROOT, work, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".terraform"))
    if IMAGE:
        os.makedirs(os.path.join(work, ".terraform"), exist_ok=True)
    else:
        os.symlink(os.path.join(ROOT, ".terraform"), os.path.join(work, ".terraform"))
    return work


def main():
    if not (IMAGE or BIN):
        sys.exit("set TERRAFORM_IMAGE (a pinned image) or TERRAFORM_BIN (a terraform binary)")
    plants = []
    with open(os.path.join(ROOT, "tests", "plants.tsv"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            plants.append([json.loads(x) for x in line.rstrip("\n").split("\t")])
    if not plants:
        sys.exit("tests/plants.tsv has no plants: a posture test nothing tries to break proves nothing")

    work = copy()
    r = terraform_test(work)
    shutil.rmtree(work, ignore_errors=True)
    if r.returncode != 0:
        print(r.stdout[-3000:] + r.stderr[-3000:])
        sys.exit("the untouched configuration does not pass its own posture test")
    print("  ok      the untouched configuration passes")

    missed = stale = 0
    for fname, old, new, what in plants:
        work = copy()
        try:
            path = os.path.join(work, fname)
            text = open(path, encoding="utf-8").read()
            if old not in text:
                print("  STALE   %s: the text this plant breaks is no longer in %s" % (what, fname))
                stale += 1
                continue
            open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
            r = terraform_test(work)
            if r.returncode == 0:
                print("  MISSED  %s" % what)
                missed += 1
            else:
                print("  caught  %s" % what)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    print("%d plants: %d caught, %d missed, %d stale" % (len(plants), len(plants) - missed - stale, missed, stale))
    sys.exit(1 if (missed or stale) else 0)


if __name__ == "__main__":
    main()
