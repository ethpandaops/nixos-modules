#!/usr/bin/env python3
"""Move a fleet's hosts to a target commit, one at a time, behind gates.

One run, for one environment, in a checkout of the fleet repo:

  1. reads the plan (`nix eval --json .#rolloutPlan`), each host's
     deploy/<host> branch, the cluster (read-only kubectl), and every
     environment's state from the rollout-state branch;
  2. keeps the environment's target until it converges or halts, then takes
     the newest eligible commit: the first environment the newest master
     commit whose check passed, a later one the newest commit the one before
     it converged on whose promote soak (and every earlier one's) is over;
  3. asks logic.plan_step what to do and repeats until it has to wait,
     filling in what the step needs (a class from fingerprints, a commit
     range's provenance, firing alerts);
  4. with --apply, records a move in rollout-state before it pushes the
     host's branch, so a failed push is retried and never lost.

It never writes to a cluster. comin on the host applies the commit; kured
drains and reboots. Every host is a Kubernetes node: the promoter reads what
a host runs and how it is from the annotations on its Node.

  host-promote --env staging [--apply]
  host-promote --env production --action resume|abandon [--apply]
  host-promote --env production --action approve --commit <sha> [--apply]
  host-promote gate --node <node> pre|post [--target <sha>]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import logic  # noqa: E402


def run(*cmd: str, check: bool = True, input: str | None = None) -> str:
    proc = subprocess.run(cmd, check=False, text=True, capture_output=True, input=input)
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:4])} failed ({proc.returncode}): {proc.stderr.strip()[-2000:]}")
    return proc.stdout


class Repo:
    def __init__(self, path: str, remote: str):
        self.path, self.remote = path, remote

    def git(self, *args: str, check: bool = True, input: str | None = None) -> str:
        return run("git", "-C", self.path, *args, check=check, input=input).strip()

    def ok(self, *args: str) -> bool:
        return subprocess.run(["git", "-C", self.path, *args], capture_output=True).returncode == 0

    def fetch(self) -> None:
        self.git("fetch", "--quiet", "--prune", self.remote, f"+refs/heads/*:refs/remotes/{self.remote}/*")

    def ref(self, branch: str) -> str | None:
        return self.git("rev-parse", "--verify", "--quiet", f"{self.remote}/{branch}^{{commit}}", check=False) or None

    def branches(self, pattern: str) -> list[str]:
        out = self.git("for-each-ref", "--format=%(refname:strip=3)", f"refs/remotes/{self.remote}/{pattern}")
        return [b for b in out.splitlines() if b]

    def has(self, rev: str) -> bool:
        return self.ok("cat-file", "-e", f"{rev}^{{commit}}")

    def ancestor(self, old: str, new: str) -> bool:
        return self.ok("merge-base", "--is-ancestor", old, new)

    def file(self, rev: str, path: str) -> str | None:
        out = subprocess.run(["git", "-C", self.path, "show", f"{rev}:{path}"], capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else None

    def commits(self, old: str | None, new: str) -> list[str]:
        """Commits in old..new, oldest first."""
        spec = f"{old}..{new}" if old else new
        return self.git("rev-list", "--reverse", spec).split()

    def read_state(self, branch: str, env: str) -> dict:
        out = self.file(f"{self.remote}/{branch}", f"{env}.json")
        return json.loads(out) if out else {}

    def write_state(self, branch: str, env: str, state: dict, message: str, attempts: int = 4) -> None:
        """Commit <env>.json on the state branch with plumbing and push it.

        Each environment writes only its own file, so when another
        environment's run pushed first, the commit is rebuilt on the new
        parent and pushed again. Runs of one environment never overlap (the
        workflow's concurrency group), so nothing of this one is lost."""
        blob = self.git("hash-object", "-w", "--stdin", input=json.dumps(state, indent=2, sort_keys=True) + "\n")
        for attempt in range(attempts):
            parent = self.ref(branch)
            entries = self.git("ls-tree", parent).splitlines() if parent else []
            entries = [e for e in entries if not e.endswith(f"\t{env}.json")] + [f"100644 blob {blob}\t{env}.json"]
            tree = self.git("mktree", input="\n".join(entries) + "\n")
            commit = self.git("commit-tree", tree, *(["-p", parent] if parent else []), "-m", message)
            if self.ok("push", "--quiet", self.remote, f"{commit}:refs/heads/{branch}"):
                self.git("update-ref", f"refs/remotes/{self.remote}/{branch}", commit)
                return
            if attempt + 1 == attempts:
                break
            time.sleep(2 * (attempt + 1))
            self.git("fetch", "--quiet", self.remote, f"+refs/heads/{branch}:refs/remotes/{self.remote}/{branch}", check=False)
        raise RuntimeError(f"couldn't push {branch} after {attempts} tries")


# Facts


def nix_eval(repo: Repo, attr: str, rev: str | None = None, apply: str | None = None):
    flake = f"git+file://{Path(repo.path).resolve()}" + (f"?rev={rev}" if rev else "")
    cmd = ["nix", "eval", "--json", f"{flake}#{attr}"] + (["--apply", apply] if apply else [])
    return json.loads(run(*cmd))


class Fingerprints:
    """Fingerprints per commit, evaluated once per commit for every host asked."""

    def __init__(self, repo: Repo):
        self.repo, self.cache = repo, {}

    def get(self, rev: str, hosts: list[str]) -> dict[str, dict]:
        have = self.cache.setdefault(rev, {})
        missing = [h for h in hosts if h not in have]
        if missing:
            names = " ".join(json.dumps(h) for h in missing)
            have.update(
                nix_eval(
                    self.repo,
                    "nixosConfigurations",
                    rev,
                    f"cs: builtins.listToAttrs (map (n: {{ name = n; value = cs.${{n}}.config.ethpandaops.fingerprint; }}) [ {names} ])",
                )
            )
        return {h: have[h] for h in hosts}


def check_passed(repo_name: str, workflow: str, sha: str, cache: dict) -> bool:
    if sha not in cache:
        out = run(
            "gh", "api", f"repos/{repo_name}/actions/workflows/{workflow}/runs?head_sha={sha}&status=success&per_page=1", "--jq", ".total_count", check=False
        )
        cache[sha] = out.strip() not in ("", "0")
    return cache[sha]


def unsigned(repo: Repo, signers: str | None, commits: list[str]) -> list[str]:
    """Commits not signed by an allowed key. A fleet whose hosts set no
    allowedSignersFile deploys any commit on its branch, write access being
    its trust line, so nothing counts as unsigned there."""
    if not commits or not signers:
        return []
    with tempfile.NamedTemporaryFile("w", suffix=".allowed_signers", delete=False) as f:
        f.write(signers)
    try:
        return [c for c in commits if not repo.ok("-c", f"gpg.ssh.allowedSignersFile={f.name}", "verify-commit", c)]
    finally:
        os.unlink(f.name)


def trailers(repo: Repo, commit: str) -> dict[str, list[str]]:
    out = repo.git("log", "-1", "--format=%(trailers:only,unfold)", commit)
    found: dict[str, list[str]] = {}
    for line in out.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            found.setdefault(key.strip().lower(), []).append(value.strip())
    return found


def security_only(repo: Repo, commit: str, whitelist: str | None) -> bool:
    """The commit changes flake.lock's nixpkgs entry and nothing else, apart
    from the vulnix whitelist."""
    files = set(repo.git("diff-tree", "--no-commit-id", "--name-only", "-r", f"{commit}^", commit).split())
    if not files or not files <= {"flake.lock"} | ({whitelist} if whitelist else set()):
        return False
    if "flake.lock" not in files:
        return True
    old, new = (json.loads(repo.file(c, "flake.lock") or "{}") for c in (f"{commit}^", commit))
    for lock in (old, new):
        lock.get("nodes", {}).pop("nixpkgs", None)
    return old == new


def urgent_range(repo: Repo, plan: dict, fps: Fingerprints, env: str, start: str | None, end: str, restore: str | None) -> str:
    """'' unless every commit in start..end carries an Urgency: trailer backed
    by evidence; then 'security' or 'revert'. A revert counts only when every
    host's fingerprint at `end` equals its fingerprint at `restore`, the
    commit the environment last converged on."""
    if not start or not repo.ancestor(start, end):
        return ""
    commits = repo.commits(start, end)
    if not commits or unsigned(repo, plan.get("allowedSigners"), commits):
        return ""
    kinds = set()
    for c in commits:
        urgency = [u.lower() for u in trailers(repo, c).get("urgency", [])]
        if urgency == ["security"] and security_only(repo, c, plan["vulnixWhitelist"]):
            kinds.add("security")
        elif urgency == ["revert"]:
            kinds.add("revert")
        else:
            return ""
    if "revert" in kinds:
        hosts = [h for h, info in plan["hosts"].items() if info["env"] == env]
        if not restore:
            return ""
        try:
            if fps.get(end, hosts) != fps.get(restore, hosts):
                return ""
        except RuntimeError:
            return ""
        return "revert"
    return "security"


def kubectl_get(context: str | None, *kinds: str) -> dict[str, list[dict]]:
    """Read-only: one `kubectl get -A -o json` per kind."""
    base = ["kubectl", "--request-timeout=60s"] + (["--context", context] if context else [])
    return {kind: json.loads(run(*base, "get", kind, "-A", "-o", "json"))["items"] for kind in kinds}


def load_cluster(context: str | None) -> logic.Cluster:
    got = kubectl_get(context, "nodes", "pods", "poddisruptionbudgets", "replicasets", "deployments", "statefulsets")
    return logic.Cluster(
        nodes={n["metadata"]["name"]: n for n in got["nodes"]},
        pods=got["pods"],
        pdbs=got["poddisruptionbudgets"],
        replicasets=got["replicasets"],
        deployments=got["deployments"],
        statefulsets=got["statefulsets"],
    )


def firing_alerts(plan: dict, hosts: list[str]) -> dict[str, list[str]]:
    """Grafana-managed alerts firing for each host or its fleet and
    environment, read with a viewer token (GRAFANA_URL, GRAFANA_TOKEN)."""
    url, token = os.environ.get("GRAFANA_URL"), os.environ.get("GRAFANA_TOKEN")
    if not url or not token:
        raise RuntimeError("the alert gate is on but GRAFANA_URL or GRAFANA_TOKEN is missing")
    req = urllib.request.Request(url.rstrip("/") + "/api/prometheus/grafana/api/v1/alerts", headers={"Authorization": f"Bearer {token}"})
    alerts = json.load(urllib.request.urlopen(req, timeout=30)).get("data", {}).get("alerts", [])
    out = {}
    for host in hosts:
        info = plan["hosts"][host]
        out[host] = sorted(
            a["labels"].get("alertname", "?")
            for a in alerts
            if a.get("state") == "firing"
            and (
                a["labels"].get("nixhost") == host
                or ("nixhost" not in a["labels"] and a["labels"].get("fleet") == info["fleet"] and a["labels"].get("environment") == info["env"])
            )
        )
    return out


def notify(message: str, apply: bool) -> None:
    """Print, and with --apply post to Discord too."""
    print(message if apply else f"(dry run) {message}")
    url = os.environ.get("ROLLOUT_DISCORD_WEBHOOK")
    if not url or not apply:
        return
    req = urllib.request.Request(url, data=json.dumps({"content": message[:1900]}).encode(), headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except OSError as err:
        print(f"notify failed: {err}", file=sys.stderr)


def views(plan: dict, cluster: logic.Cluster, hosts: list[str]) -> dict[str, logic.NodeView | None]:
    """Each host's Node, or None when the cluster has no such Node."""
    nodes = {h: plan["hosts"][h]["node"] for h in hosts}
    return {h: logic.NodeView(n, cluster.nodes[n]) if n in cluster.nodes else None for h, n in nodes.items()}


# One run


class Promoter:
    def __init__(self, args):
        self.args = args
        self.repo = Repo(args.repo, args.remote)
        self.repo.fetch()
        self.plan = nix_eval(self.repo, args.plan)
        self.env = args.env
        self.source = self.plan["sourceBranch"]
        self.branch = self.plan["stateBranch"]
        self.now = int(time.time())
        self.fps = Fingerprints(self.repo)
        self.checks: dict[str, bool] = {}
        self.state = self.repo.read_state(self.branch, self.env)
        self.saved = json.dumps(self.state, sort_keys=True)
        self.hosts = [h for w in logic.waves_of(self.plan, self.env) for h in w["hosts"]]
        self.repo_name = os.environ.get("GITHUB_REPOSITORY") or run("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
        self.cluster = load_cluster(args.context)
        self.nodes = views(self.plan, self.cluster, self.hosts)

    @property
    def first(self) -> bool:
        return logic.env_index(self.plan, self.env) == 0

    def say(self, message: str) -> None:
        notify(f"{self.plan['fleet']} {self.env}: {message}", self.args.apply)

    def save(self, message: str) -> None:
        self.saved = json.dumps(self.state, sort_keys=True)
        if self.args.apply:
            self.repo.write_state(self.branch, self.env, self.state, f"{self.env}: {message}")
        else:
            print(f"(dry run) state: {message}")

    def push(self, host: str, target: str) -> None:
        if self.args.apply:
            self.repo.git("push", "--quiet", self.repo.remote, f"{target}:refs/heads/{self.plan['hosts'][host]['deployBranch']}")

    def candidate(self) -> str | None:
        abandoned = set(self.state.get("abandoned", []))
        if self.first:
            head = self.repo.ref(self.source)
            for c in self.repo.git("rev-list", "--first-parent", "-n", "30", head).split():
                if check_passed(self.repo_name, self.plan["checkWorkflow"], c, self.checks):
                    return None if c in abandoned else c
            return None
        before = self.plan["environmentOrder"][logic.env_index(self.plan, self.env) - 1]
        prev = self.repo.read_state(self.branch, before)
        target = logic.promote_target(prev, self.state, self.plan, self.now)
        return None if target in abandoned else target

    def new_roll(self, target: str, lane: list[str], why: str) -> None:
        keep = {k: self.state[k] for k in ("staged", "convergedTarget", "approved", "abandoned", "canariesSettled") if k in self.state}
        # startedAt, like each host's "from", is a record for people reading
        # rollout-state; the promoter doesn't read it.
        self.state = {**keep, "target": target, "startedAt": self.now, "baseline": logic.baseline(self.cluster), "hosts": {}, "lane": lane}
        self.say(f"rolling {target[:12]} ({why})")

    def choose_target(self) -> str | None:
        current = self.state.get("target")
        candidate = self.candidate()
        if current in self.state.get("abandoned", []):
            if candidate and candidate != current and self.repo.ancestor(current, candidate):
                self.new_roll(candidate, [], f"after {current[:12]} was abandoned")
                return candidate
            return None
        if not candidate or candidate == current or (current and not self.repo.ancestor(current, candidate)):
            return current
        halted = self.state.get("halted")
        urgency = urgent_range(self.repo, self.plan, self.fps, self.env, current, candidate, self.state.get("convergedTarget")) if current else ""
        on_bad = [h for h, hs in self.state.get("hosts", {}).items() if hs.get("target") == current and hs.get("advancedAt") and not hs.get("skipped")]
        if halted:
            hs = self.state.get("hosts", {}).get(halted.get("host") or "", {})
            in_flight = hs.get("target") == current and hs.get("advancedAt") and not hs.get("settledAt")
            if in_flight or urgency == "revert":
                self.new_roll(candidate, on_bad, f"supersedes the halt on {current[:12]}")
                return candidate
            return current
        if logic.newer_target(candidate, self.state, bool(urgency)):
            lane = on_bad if urgency == "revert" else []
            self.new_roll(candidate, lane, f"urgent: {urgency}" if urgency and current != self.state.get("convergedTarget") else "new target")
            return candidate
        return current

    def manual(self) -> int:
        action, target = self.args.action, self.state.get("target")
        if action == "approve":
            if self.first or not self.args.commit:
                raise SystemExit("approve takes --commit and applies to a later environment")
            commit = self.repo.git("rev-parse", "--verify", f"{self.args.commit}^{{commit}}")
            self.state.setdefault("approved", []).append(commit)
            self.say(f"{commit[:12]} approved for this environment")
            self.save(f"approve {commit[:12]}")
            return 0
        if action == "resume":
            halted = self.state.pop("halted", None)
            if not halted:
                raise SystemExit("not halted")
            self.state["baseline"] = logic.baseline(self.cluster)
            self.state.pop("regressionSince", None)
            for h, hs in self.state.get("hosts", {}).items():
                view = self.nodes.get(h)
                hs["counts"] = view.counts if view and view.trusted else None
                hs.pop("watchSince", None)
                if hs.get("state"):
                    hs["stateSince"] = self.now
            self.say(f"resumed on {target[:12] if target else 'no target'} (halted: {halted['reason']})")
            self.save("resume")
            return 0
        if action == "abandon":
            if not target:
                raise SystemExit("no target to abandon")
            self.state.setdefault("abandoned", []).append(target)
            self.state.pop("halted", None)
            self.say(f"abandoned {target[:12]}; waiting for the next eligible commit")
            self.save(f"abandon {target[:12]}")
            return 0
        raise SystemExit(f"unknown action {action}")

    def classify(self, host: str, snap: logic.Snapshot) -> str | None:
        """Fill snap.classes[host]; a reason to halt if a commit won't evaluate."""
        view = self.nodes.get(host)
        running = view.revision if view else None
        if running and not self.repo.has(running):
            running = None
        try:
            new = self.fingerprint(snap.target, host)
            old = self.fingerprint(running, host) if running else None
        except RuntimeError as err:
            return f"a commit doesn't evaluate for {host}: {err}"
        snap.classes[host] = logic.classify(self.plan, old, new)
        snap.mixed[host] = logic.mixed(self.plan, snap.classes[host], old, new)
        return None

    def fingerprint(self, rev: str, host: str) -> dict:
        """One host's fingerprint at a commit, evaluated with the rest of the
        environment's hosts in one go; alone if that fails, to name the host."""
        env = self.plan["hosts"][host]["env"]
        batch = [h for h, info in self.plan["hosts"].items() if info["env"] == env]
        try:
            return self.fps.get(rev, batch)[host]
        except RuntimeError:
            return self.fps.get(rev, [host])[host]

    def provenance(self, host: str, snap: logic.Snapshot) -> str:
        branch, target = snap.refs[host], snap.target
        if not self.repo.ancestor(target, self.repo.ref(self.source)):
            return f"{target[:12]} isn't on {self.source}"
        if not self.repo.ancestor(branch, target):
            return f"{target[:12]} isn't a fast-forward of {branch[:12]}"
        if not check_passed(self.repo_name, self.plan["checkWorkflow"], target, self.checks):
            return f"check didn't pass on {target[:12]}"
        bad = unsigned(self.repo, self.plan.get("allowedSigners"), self.repo.commits(branch, target))
        if bad:  # only when the fleet's hosts set allowedSignersFile
            return f"not signed by an allowed key: {', '.join(c[:12] for c in bad[:5])}"
        return ""

    def converge(self, target: str, snap: logic.Snapshot) -> None:
        """Record that every host runs the target; for any environment that
        has one after it, stage the commit for the next one, with the worst
        class it brings to this or any later environment."""
        mine = logic.worst(self.plan, [hs.get("class", "reboot") for hs in self.state["hosts"].values() if hs.get("target") == target])
        self.state["convergedTarget"] = target
        order = self.plan["environmentOrder"]
        later = set(order[logic.env_index(self.plan, self.env) + 1 :])
        if not later:
            self.say(f"every host runs {target[:12]}")
            return
        classes = []
        for h in (h for h, info in self.plan["hosts"].items() if info["env"] in later):
            ref = self.repo.ref(self.plan["hosts"][h]["deployBranch"])
            if not ref:
                continue
            # Best effort: a later host the target doesn't evaluate for counts
            # as the most disruptive class (its own environment halts on it),
            # and one whose start doesn't evaluate as a reboot.
            try:
                new = self.fingerprint(target, h)
            except RuntimeError:
                classes.append(logic.class_names(self.plan)[-1])
                continue
            try:
                old = self.fingerprint(ref, h)
            except RuntimeError:
                old = None
            classes.append(logic.classify(self.plan, old, new))
        theirs = logic.worst(self.plan, classes)
        entry = {"commit": target, "at": self.now, "class": logic.worst(self.plan, [mine, theirs]), "urgent": snap.urgent}
        if logic.rank(self.plan, theirs) > logic.rank(self.plan, mine):
            entry["needsApproval"] = True
        self.state.setdefault("staged", []).append(entry)
        note = " It changes later environments more than this one, so they wait for a person's approval." if entry.get("needsApproval") else ""
        self.say(f"converged on {target[:12]} ({entry['class']}).{note}")

    def wait(self, action: logic.Action) -> None:
        """Record a wait; post a notice once when the same wait lasts long."""
        key = f"{action.host or ''}: {action.reason.split(':')[0]}"
        wait = self.state.get("wait") or {}
        if wait.get("key") != key:
            self.state["wait"] = wait = {"key": key, "since": self.now}
        if not wait.get("notified") and self.now - wait["since"] >= 60 * self.plan["budgets"]["waitNotice"]:
            wait["notified"] = True
            self.say(f"waiting for {(self.now - wait['since']) // 3600} h: {action.host or ''} {action.reason}".replace("  ", " "))

    def step(self) -> int:
        if self.args.action != "run":
            return self.manual()
        if not self.plan.get("allowedSigners"):
            print(f"{self.env}: the hosts set no allowedSignersFile, so commits aren't checked for signatures")
        target = self.choose_target()
        if not target:
            print(f"{self.env}: nothing to roll")
            return 0
        refs = {h: self.repo.ref(self.plan["hosts"][h]["deployBranch"]) for h in self.hosts}
        lane = set(self.state.get("lane", []))
        start = self.state.get("convergedTarget")
        snap = logic.Snapshot(
            env=self.env,
            plan=self.plan,
            target=target,
            state=self.state,
            now=self.now,
            refs=refs,
            nodes=self.nodes,
            cluster=self.cluster,
            held=self.repo.file(self.repo.ref(self.source), self.plan["holdFile"]) is not None,
            testing=self.repo.branches(logic.TESTING_BRANCHES),
            urgent=bool(start and start != target and urgent_range(self.repo, self.plan, self.fps, self.env, start, target, start)),
            lane=lane,
        )
        for h, hs in self.state.get("hosts", {}).items():
            view = self.nodes.get(h)
            if hs.get("target") == target and hs.get("counts") is None and view and view.trusted:
                hs["counts"] = view.counts
        action = logic.Action("done")
        for _ in range(self.args.max_steps):
            action = logic.plan_step(snap)
            print(f"{self.env}: {action.kind} {action.host or ''} {action.reason}".rstrip())
            hs = self.state["hosts"].setdefault(action.host, {}) if action.host else {}
            if action.kind == "need":
                need = action.data["need"]
                if need == "class":
                    error = self.classify(action.host, snap)
                    if error:
                        action = logic.Action("halt", action.host, error)
                    else:
                        continue
                elif need == "provenance":
                    snap.provenance[action.host] = self.provenance(action.host, snap)
                    continue
                elif need == "alerts":
                    try:
                        snap.alerts = firing_alerts(self.plan, self.hosts)
                    except (OSError, RuntimeError, ValueError) as err:
                        action = logic.Action("wait", action.host, f"can't read alerts: {err}")
                    else:
                        continue
            if action.kind == "push":
                self.push(action.host, target)
                refs[action.host] = target
                continue
            if action.kind in ("advance", "skip"):
                view = self.nodes.get(action.host)
                trusted = bool(view and view.trusted)
                hs.clear()
                hs.update(
                    {
                        "target": target,
                        "class": action.reason if action.kind == "advance" else "none",
                        "intent": True,
                        "advancedAt": self.now,
                        "from": view.revision if trusted else None,
                        "counts": view.counts if trusted else None,
                        "bootId": view.boot_id if view else None,
                        "workloads": action.data.get("workloads", []),
                        "state": "deploy",
                        "stateSince": self.now,
                    }
                )
                if action.kind == "skip":
                    hs.update({"skipped": True, "settledAt": self.now})
                self.state.pop("wait", None)
                self.save(f"move {action.host} to {target[:12]}")
                self.push(action.host, target)
                refs[action.host] = target
                if action.kind == "skip":
                    continue
                self.say(f"moved {action.host} to {target[:12]} ({action.reason})")
                break
            if action.kind == "defer":
                hs.update({"target": target, "deferred": True})
                continue
            if action.kind == "settle":
                hs["settledAt"] = self.now
                hs.pop("state", None)
                self.say(f"{action.host} settled on {target[:12]}")
                canaries = next((w["hosts"] for w in logic.waves_of(self.plan, self.env) if w["name"] == "canary"), [])
                done = lambda h: self.state["hosts"].get(h, {}).get("target") == target and self.state["hosts"][h].get("settledAt")  # noqa: E731
                if canaries and all(done(h) or not refs.get(h) for h in canaries) and (self.state.get("canariesSettled") or [{}])[-1].get("commit") != target:
                    # Read by fleets that follow this one (bump-modules --after).
                    self.state.setdefault("canariesSettled", []).append({"commit": target, "at": self.now})
                continue
            if action.kind == "converge":
                self.converge(target, snap)
                break
            if action.kind == "halt":
                if not self.state.get("halted"):
                    self.state["halted"] = {"reason": action.reason, "host": action.host, "state": action.data.get("state", ""), "at": self.now}
                    self.say(f"HALTED at {action.host or 'the roll'}: {action.reason}")
                break
            if action.kind == "wait":
                if "state" in action.data and action.host:
                    hs["state"], hs["stateSince"] = action.data["state"], action.data["stateSince"]
                if "watchSince" in action.data:
                    hs["watchSince"] = action.data["watchSince"]
                if "regressionSince" in action.data:
                    self.state["regressionSince"] = action.data["regressionSince"]
                else:
                    self.state.pop("regressionSince", None)
                self.wait(action)
                break
            break  # done
        if json.dumps(self.state, sort_keys=True) != self.saved:
            self.save(f"{action.kind} {action.host or ''}".strip())
        return 1 if self.state.get("halted") else 0


def gate(args) -> int:
    """Read-only: what blocks moving one node now (pre), or why it isn't back
    on a commit and settled (post), for a person or a script moving a node by
    hand, such as a fleet's migration onto NixOS. post checks what the
    promoter does before it settles a host: first the host itself, then its
    pods and the workloads with a pod on it, which pre required ready."""
    cluster = load_cluster(args.context)
    if args.node not in cluster.nodes:
        print(f"no Node {args.node}")
        return 1
    if args.phase == "pre":
        problems = logic.pdb_blockers(args.node, cluster) + [f"not ready: {w}" for w in logic.workloads_not_ready_on(args.node, cluster)]
    else:
        if not args.target:
            raise SystemExit("post needs --target")
        problems = logic.host_problems(logic.NodeView(args.node, cluster.nodes[args.node]), args.target, 0)
        if not problems:
            problems = logic.unsettled(args.node, cluster, cluster.workloads_on(args.node))
    for p in problems:
        print(p)
    if not problems:
        print(f"{args.node}: {args.phase} gates pass")
    return 1 if problems else 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "gate":
        ap = argparse.ArgumentParser(prog="host-promote gate")
        ap.add_argument("phase", choices=["pre", "post"])
        ap.add_argument("--node", required=True)
        ap.add_argument("--context")
        ap.add_argument("--target")
        return gate(ap.parse_args(sys.argv[2:]))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--action", default="run", choices=["run", "resume", "abandon", "approve"])
    ap.add_argument("--commit", help="approve: the commit a later environment may take")
    ap.add_argument("--context", help="kubectl context, read-only")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--remote", default="origin")
    ap.add_argument("--plan", default="rolloutPlan", help="the flake attribute holding the plan")
    ap.add_argument("--apply", action="store_true", help="push branches and state; without it, only print")
    ap.add_argument("--max-steps", type=int, default=60)
    args = ap.parse_args()
    return Promoter(args).step()


if __name__ == "__main__":
    sys.exit(main())
