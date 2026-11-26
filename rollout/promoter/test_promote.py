"""Tests for promote.py, the part that reads git, the cluster and Nix: a real
git remote with SSH-signed commits, and fake `nix`, `kubectl` and `gh` on
PATH that answer from JSON files. Run: python3 -m unittest (in this directory).
"""

import argparse
import contextlib
import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path

import promote

NIX = r"""import json, os, re, sys
fake = os.environ["FAKE"]
args = sys.argv[1:]
ref = next(a for a in args if "#" in a)
attr = ref.split("#", 1)[1]
m = re.search(r"\?rev=([0-9a-f]+)", ref)
rev = m.group(1) if m else "HEAD"
if attr == "rolloutPlan":
    print(open(f"{fake}/plan.json").read())
    sys.exit(0)
fps = json.load(open(f"{fake}/fingerprints.json"))
names = re.findall(r'"([^"]+)"', args[args.index("--apply") + 1])
if rev not in fps or any(n not in fps[rev] for n in names):
    print(f"error: attribute missing at {rev}", file=sys.stderr)
    sys.exit(1)
print(json.dumps({n: fps[rev][n] for n in names}))
"""

KUBECTL = r"""import json, os, sys
kind = sys.argv[sys.argv.index("get") + 1]
print(json.dumps({"items": json.load(open(os.environ["FAKE"] + "/cluster.json")).get(kind, [])}))
"""

GH = r"""import json, os, re, sys
m = re.search(r"head_sha=([0-9a-f]+)", " ".join(sys.argv))
print(1 if m and m.group(1) in json.load(open(os.environ["FAKE"] + "/passed.json")) else 0)
"""

STAGING, PROD = ["s1"], ["p1", "p2"]
OLD_STATE = "0" * 40


def fp(**over):
    return {
        "toplevel": "t0",
        "kernel": "k0",
        "kernelVersion": "6.18.4",
        "initrd": "i",
        "systemd": "s",
        "kernelParams": [],
        "kernelModules": [],
        "inhibitors": {},
        "nixosRelease": "26.05",
        **over,
    }


def node(name, revision, rollbacks=0, readiness="ok"):
    ann = {
        "revision": revision,
        "boot-revision": revision,
        "reboot-required": "false",
        "reboot-held": "",
        "health": "ok",
        "readiness": readiness,
        "rollbacks": str(rollbacks),
        "boot-id": "boot-1",
        "kernel": "6.18.4",
        "trial": "none",
        "boot-check": "none",
        "reported-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return {
        "metadata": {"name": name, "annotations": {"nixos.ethpandaops.io/" + k: v for k, v in ann.items()}, "labels": {}},
        "spec": {},
        "status": {"conditions": [{"type": "Ready", "status": "True"}], "nodeInfo": {"bootID": "boot-1", "kernelVersion": "6.18.4"}},
    }


class Fleet(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="promoter-test-"))
        self.fake = self.dir / "fake"
        bin_dir = self.dir / "bin"
        self.fake.mkdir()
        bin_dir.mkdir()
        for name, text in (("nix", NIX), ("kubectl", KUBECTL), ("gh", GH)):
            # This interpreter, not /usr/bin/env: the Nix build sandbox has none.
            (bin_dir / name).write_text(f"#!{sys.executable}\n{text}")
            (bin_dir / name).chmod(0o755)
        self.env = dict(os.environ)
        os.environ.update(
            {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "FAKE": str(self.fake),
                "GITHUB_REPOSITORY": "example/fleet",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )
        os.environ.pop("ROLLOUT_DISCORD_WEBHOOK", None)
        for var in ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"):
            os.environ[var] = "Test"
        for var in ("GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"):
            os.environ[var] = "t@example.org"

        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.dir / "key")], check=True)
        pub = (self.dir / "key.pub").read_text().split()
        self.signers = f"t@example.org {pub[0]} {pub[1]}\n"
        self.remote = self.dir / "remote.git"
        self.work = self.dir / "work"
        self.sh("git", "init", "-q", "--bare", "-b", "master", str(self.remote), cwd=self.dir)
        self.sh("git", "init", "-q", "-b", "master", str(self.work), cwd=self.dir)
        for k, v in (("gpg.format", "ssh"), ("user.signingkey", str(self.dir / "key")), ("commit.gpgsign", "true")):
            self.git("config", k, v)
        self.git("remote", "add", "origin", str(self.remote))
        self.c0 = self.commit("start", {"flake.lock": self.lock("n0"), "README": "fleet\n"})
        self.c1 = self.commit("change", {"README": "fleet 1\n"})
        for h in STAGING + PROD:
            self.git("push", "-q", "origin", f"{self.c0}:refs/heads/deploy/{h}")
        self.git("push", "-q", "origin", "master")

        self.plan = self.make_plan()
        self.write("plan.json", self.plan)
        self.write("passed.json", [self.c0, self.c1])
        self.fps = {self.c0: {h: fp() for h in STAGING + PROD}, self.c1: {h: fp(toplevel="t1") for h in STAGING + PROD}}
        self.write("fingerprints.json", self.fps)
        self.set_cluster({h: self.c0 for h in STAGING + PROD})

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.dir)

    # Helpers

    def sh(self, *cmd, cwd=None, check=True):
        return subprocess.run(cmd, cwd=cwd or self.work, check=check, text=True, capture_output=True).stdout.strip()

    def git(self, *args):
        return self.sh("git", *args)

    def write(self, name, data):
        (self.fake / name).write_text(json.dumps(data))

    def lock(self, nixpkgs_rev):
        return (
            json.dumps(
                {
                    "nodes": {
                        "nixpkgs": {"locked": {"rev": nixpkgs_rev}},
                        "nixos-modules": {"locked": {"rev": "m0"}},
                        "root": {"inputs": {"nixpkgs": "nixpkgs"}},
                    },
                    "version": 7,
                },
                indent=2,
            )
            + "\n"
        )

    def commit(self, message, files, sign=True, push=False):
        for name, text in files.items():
            path = self.work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            self.git("add", name)
        self.git("commit", "-q", "-m", message, *([] if sign else ["--no-gpg-sign"]))
        if push:
            self.git("push", "-q", "origin", "master")
        return self.git("rev-parse", "HEAD")

    def make_plan(self):
        def host(env, n, canary=False):
            return {
                "env": env,
                "fleet": "fleet",
                "group": "g",
                "canary": canary,
                "lead": False,
                "node": f"n-{n}",
                "deployBranch": f"deploy/{n}",
                "readinessMinutes": 0,
                "trialMinutes": 0,
            }

        soak = {"switch": 5, "reboot": 20, "kernel-series": 60, "release": 60}
        return {
            "fleet": "fleet",
            "environmentOrder": ["staging", "production"],
            "environments": {
                "staging": {"waves": [{"name": "g", "hosts": STAGING}]},
                "production": {"waves": [{"name": "canary", "hosts": ["p1"]}, {"name": "g", "hosts": ["p2"]}]},
            },
            "hosts": {"s1": host("staging", "s1"), "p1": host("production", "p1", True), "p2": host("production", "p2")},
            "classes": [
                {"name": "switch"},
                {"name": "reboot", "fields": ["kernel", "initrd", "systemd", "kernelParams", "kernelModules", "inhibitors"]},
                {"name": "kernel-series", "series": ["kernelVersion"]},
                {"name": "release", "fields": ["nixosRelease"]},
            ],
            "groupCanaries": True,
            "soak": {"staging": soak, "production": soak},
            "canaryExtra": {"switch": 30, "reboot": 240, "kernel-series": 1440, "release": 1440},
            "promote": {"switch": 60, "reboot": 360, "kernel-series": 1440, "release": 1440},
            "urgent": {"soak": 10, "promote": 60},
            "budgets": {"deploy": 20, "lock": 125, "drain": 20, "boot": 20, "readyMargin": 5, "regression": 30, "watchGrace": 10, "waitNotice": 120},
            "windows": {},
            "alerts": False,
            "sourceBranch": "master",
            "stateBranch": "rollout-state",
            "holdFile": "rollout/hold",
            "checkWorkflow": "check.yaml",
            "vulnixWhitelist": "vulnix-whitelist.toml",
            "allowedSigners": self.signers,
        }

    def set_cluster(self, running, **node_over):
        self.write("cluster.json", {"nodes": [node(f"n-{h}", rev, **node_over.get(h, {})) for h, rev in running.items()]})

    def promoter(self, env, apply=True, action="run", commit=None):
        args = argparse.Namespace(
            env=env, apply=apply, action=action, commit=commit, context=None, repo=str(self.work), remote="origin", plan="rolloutPlan", max_steps=60
        )
        return promote.Promoter(args)

    def run_env(self, env, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = self.promoter(env, **kw).step()
        return code, out.getvalue()

    def remote_ref(self, ref):
        return self.sh("git", "--git-dir", str(self.remote), "rev-parse", "--verify", "--quiet", ref, check=False)

    def state(self, env):
        out = self.sh("git", "--git-dir", str(self.remote), "show", f"rollout-state:{env}.json", check=False)
        return json.loads(out) if out else {}

    def put_state(self, env, state):
        repo = promote.Repo(str(self.work), "origin")
        repo.fetch()
        repo.write_state("rollout-state", env, state, "test")


class Promote(Fleet):
    def test_the_move_is_recorded_before_the_branch_is_pushed(self):
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nwhile read old new ref; do case $ref in refs/heads/deploy/*) exit 1;; esac; done\n")
        hook.chmod(0o755)
        with self.assertRaises(RuntimeError):
            self.run_env("staging")
        self.assertEqual(self.state("staging")["hosts"]["s1"]["target"], self.c1)
        self.assertEqual(self.remote_ref("deploy/s1"), self.c0)
        hook.unlink()
        _, out = self.run_env("staging")
        self.assertIn("push s1", out)
        self.assertEqual(self.remote_ref("deploy/s1"), self.c1)

    def test_a_hold_on_the_head_of_master_stops_a_roll_of_an_older_commit(self):
        self.put_state("staging", {"staged": [{"commit": self.c1, "at": int(time.time()) - 86400, "class": "switch"}], "convergedTarget": self.c1})
        self.commit("hold", {"rollout/hold": "\n"}, push=True)
        _, out = self.run_env("production")
        self.assertIn("rollout/hold exists on master", out)
        self.assertEqual(self.remote_ref("deploy/p1"), self.c0)
        self.assertEqual(self.state("production")["target"], self.c1)

    def test_an_unsigned_commit_halts_at_once(self):
        c2 = self.commit("unsigned", {"README": "fleet 2\n"}, sign=False, push=True)
        self.write("passed.json", [self.c0, self.c1, c2])
        self.fps[c2] = {h: fp(toplevel="t2") for h in STAGING + PROD}
        self.write("fingerprints.json", self.fps)
        code, out = self.run_env("staging")
        self.assertEqual(code, 1)
        self.assertIn("not signed by an allowed key", out)
        self.assertEqual(self.remote_ref("deploy/s1"), self.c0)

    def test_without_allowed_signers_an_unsigned_commit_moves(self):
        # A fleet with no allowedSignersFile: write access is the trust line.
        self.plan["allowedSigners"] = None
        self.write("plan.json", self.plan)
        c2 = self.commit("unsigned", {"README": "fleet 2\n"}, sign=False, push=True)
        self.write("passed.json", [self.c0, self.c1, c2])
        self.fps[c2] = {h: fp(toplevel="t2") for h in STAGING + PROD}
        self.write("fingerprints.json", self.fps)
        code, out = self.run_env("staging")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.remote_ref("deploy/s1"), c2)

    def test_the_class_comes_from_what_the_host_runs_not_its_branch(self):
        # s1's branch is at c1, but a trial revert left it running c0.
        self.git("push", "-q", "origin", f"{self.c1}:refs/heads/deploy/s1")
        self.put_state("staging", {"target": self.c1, "convergedTarget": self.c1, "staged": []})
        c2 = self.commit("next", {"README": "fleet 2\n"}, push=True)
        self.write("passed.json", [self.c0, self.c1, c2])
        self.fps[self.c1] = {h: fp(toplevel="t1", kernel="k1") for h in STAGING + PROD}
        self.fps[c2] = {h: fp(toplevel="t2", kernel="k1") for h in STAGING + PROD}
        self.write("fingerprints.json", self.fps)
        _, out = self.run_env("staging", apply=False)
        self.assertIn("staging: advance s1 reboot", out)

    def test_a_commit_that_does_not_evaluate_halts(self):
        del self.fps[self.c1]["s1"]
        self.write("fingerprints.json", self.fps)
        code, out = self.run_env("staging")
        self.assertEqual(code, 1)
        self.assertIn("doesn't evaluate", out)

    def test_a_roll_in_progress_keeps_its_target(self):
        self.put_state("staging", {"target": self.c1, "hosts": {}})
        c2 = self.commit("next", {"README": "fleet 2\n"}, push=True)
        self.write("passed.json", [self.c0, self.c1, c2])
        p = self.promoter("staging", apply=False)
        self.assertEqual(p.choose_target(), self.c1)

    def test_resume_rebaselines_the_halted_host(self):
        self.put_state(
            "production",
            {"target": self.c1, "halted": {"reason": "rolled back", "host": "p1"}, "hosts": {"p1": {"target": self.c1, "counts": 0, "advancedAt": 1}}},
        )
        self.set_cluster({"s1": self.c0, "p1": self.c0, "p2": self.c0}, p1={"rollbacks": 1})
        self.run_env("production", action="resume")
        state = self.state("production")
        self.assertNotIn("halted", state)
        self.assertEqual(state["hosts"]["p1"]["counts"], 1)

    def gate(self, phase, node, target=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = promote.gate(argparse.Namespace(phase=phase, node=node, context=None, target=target))
        return code, out.getvalue()

    def test_gate_reports_a_node_back_on_its_commit_or_why_not(self):
        self.assertEqual(self.gate("post", "n-p1", self.c0), (0, "n-p1: post gates pass\n"))
        code, out = self.gate("post", "n-p1", self.c1)
        self.assertEqual(code, 1)
        self.assertIn(f"runs {self.c0[:12]}", out)
        self.assertEqual(self.gate("pre", "n-p1"), (0, "n-p1: pre gates pass\n"))
        self.assertEqual(self.gate("pre", "n-missing"), (1, "no Node n-missing\n"))

    def test_gate_post_waits_for_the_pods_and_workloads_on_the_node(self):
        on_node = {"ownerReferences": [{"kind": "StatefulSet", "name": "beacon"}]}

        def cluster(ready, unschedulable=False):
            n = node("n-p1", self.c0)
            n["spec"]["unschedulable"] = unschedulable
            beacon = {"metadata": {"name": "beacon-0", "namespace": "eth", **on_node}, "spec": {"nodeName": "n-p1"}}
            beacon["status"] = {"phase": "Running", "conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}
            job = {"metadata": {"name": "done", "namespace": "eth"}, "spec": {"nodeName": "n-p1"}, "status": {"phase": "Succeeded"}}
            sts = {"metadata": {"name": "beacon", "namespace": "eth"}, "spec": {"replicas": 1}, "status": {"readyReplicas": 1 if ready else 0}}
            self.write("cluster.json", {"nodes": [n], "pods": [beacon, job], "statefulsets": [sts]})

        cluster(ready=False, unschedulable=True)
        self.assertEqual(self.gate("post", "n-p1", self.c0), (1, "cordoned\n"))
        cluster(ready=False)
        self.assertEqual(self.gate("post", "n-p1", self.c0), (1, "workloads not back: eth/StatefulSet/beacon\npods not Ready: eth/beacon-0\n"))
        cluster(ready=True)
        self.assertEqual(self.gate("post", "n-p1", self.c0), (0, "n-p1: post gates pass\n"))

    def test_abandon_drops_the_target(self):
        self.put_state("staging", {"target": self.c1, "halted": {"reason": "x", "host": "s1"}, "hosts": {}})
        self.run_env("staging", action="abandon")
        self.assertEqual(self.state("staging")["abandoned"], [self.c1])
        _, out = self.run_env("staging", apply=False)
        self.assertIn("nothing to roll", out)

    def test_a_state_push_another_environment_beat_is_retried_on_top_of_it(self):
        self.put_state("production", {"target": OLD_STATE})
        repo = promote.Repo(str(self.work), "origin")
        repo.fetch()
        # Another environment's run, in its own clone, pushes after this one fetched.
        other = self.dir / "other"
        self.sh("git", "clone", "-q", str(self.remote), str(other), cwd=self.dir)
        theirs = promote.Repo(str(other), "origin")
        theirs.fetch()
        theirs.write_state("rollout-state", "production", {"target": self.c0}, "production: test")
        repo.write_state("rollout-state", "staging", {"target": self.c1}, "staging: test")
        self.assertEqual(self.state("staging"), {"target": self.c1})
        self.assertEqual(self.state("production"), {"target": self.c0})

    def converge(self, plan=None):
        if plan:
            self.write("plan.json", plan)
        p = self.promoter("staging")
        p.state = {"target": self.c1, "hosts": {"s1": {"target": self.c1, "class": "switch", "settledAt": 1}}}
        with contextlib.redirect_stdout(io.StringIO()):
            p.converge(self.c1, types.SimpleNamespace(urgent=False))
        return p.state

    def test_a_later_host_the_target_does_not_evaluate_for_stages_as_the_worst_class(self):
        del self.fps[self.c1]["p1"]
        self.write("fingerprints.json", self.fps)
        entry = self.converge()["staged"][-1]
        self.assertEqual((entry["commit"], entry["class"], entry.get("needsApproval")), (self.c1, "release", True))

    def test_every_environment_but_the_last_stages_for_the_next(self):
        plan = copy.deepcopy(self.plan)
        plan["environmentOrder"] = ["staging", "production", "later"]
        plan["environments"]["later"] = {"waves": []}
        self.write("plan.json", plan)
        p = self.promoter("production")
        p.state = {"target": self.c1, "hosts": {h: {"target": self.c1, "class": "switch"} for h in PROD}}
        with contextlib.redirect_stdout(io.StringIO()):
            p.converge(self.c1, types.SimpleNamespace(urgent=False))
        self.assertEqual(p.state["staged"][-1]["commit"], self.c1)
        plan["environmentOrder"] = ["staging", "production"]
        self.write("plan.json", plan)
        p = self.promoter("production")
        p.state = {"target": self.c1, "hosts": {}}
        with contextlib.redirect_stdout(io.StringIO()):
            p.converge(self.c1, types.SimpleNamespace(urgent=False))
        self.assertNotIn("staged", p.state)


class Urgency(Fleet):
    def urgent(self, start, end, restore=None):
        repo = promote.Repo(str(self.work), "origin")
        return promote.urgent_range(repo, self.plan, promote.Fingerprints(repo), "staging", start, end, restore or start)

    def test_a_nixpkgs_only_security_commit_is_urgent(self):
        c2 = self.commit("nixpkgs\n\nUrgency: security\nFixes: CVE-2026-0001", {"flake.lock": self.lock("n1")})
        self.assertEqual(self.urgent(self.c1, c2), "security")

    def test_a_security_trailer_on_anything_else_is_not(self):
        c2 = self.commit("nixpkgs\n\nUrgency: security", {"flake.lock": self.lock("n1"), "README": "sneaky\n"})
        self.assertEqual(self.urgent(self.c1, c2), "")

    def test_one_normal_commit_in_the_range_is_enough_to_lose_urgency(self):
        self.commit("feature", {"README": "x\n"})
        c3 = self.commit("nixpkgs\n\nUrgency: security", {"flake.lock": self.lock("n1")})
        self.assertEqual(self.urgent(self.c1, c3), "")

    def test_without_allowed_signers_an_unsigned_security_commit_is_urgent(self):
        self.plan["allowedSigners"] = None
        c2 = self.commit("nixpkgs\n\nUrgency: security", {"flake.lock": self.lock("n1")}, sign=False)
        self.assertEqual(self.urgent(self.c1, c2), "security")

    def test_an_unsigned_urgent_commit_is_not_urgent(self):
        c2 = self.commit("nixpkgs\n\nUrgency: security", {"flake.lock": self.lock("n1")}, sign=False)
        self.assertEqual(self.urgent(self.c1, c2), "")

    def test_a_revert_counts_only_when_it_restores_what_last_converged(self):
        # c1 converged; c2 is bad; c3 reverts it.
        c2 = self.commit("bad", {"README": "bad\n"})
        c3 = self.commit("revert\n\nUrgency: revert", {"README": "fleet 1\n"})
        self.fps[c2] = {h: fp(toplevel="t2") for h in STAGING + PROD}
        self.fps[c3] = {h: fp(toplevel="t1") for h in STAGING + PROD}
        self.write("fingerprints.json", self.fps)
        self.assertEqual(self.urgent(c2, c3, restore=self.c1), "revert")
        self.fps[c3] = {h: fp(toplevel="t9") for h in STAGING + PROD}
        self.write("fingerprints.json", self.fps)
        self.assertEqual(self.urgent(c2, c3, restore=self.c1), "")


if __name__ == "__main__":
    unittest.main()
