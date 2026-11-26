"""The promoter's decisions, as pure functions over plain data.

promote.py gathers the facts (git refs and commits, `kubectl get -o json`,
the plan, fingerprints from `nix eval`, the check workflow's runs, alerts) and carries
out the action plan_step returns. Nothing here does I/O, so every rule has a
unit test in test_logic.py.

Words used throughout:
  target     the commit an environment is rolling; it keeps it until every
             host runs it (converged) or the roll halts.
  converged  every host of the environment with a deploy branch runs the
             target; every environment but the last records it as staged
             for the next, with the worst change class it brings to that
             environment or any later one.
  settled    a moved host is back: Ready, reporting the target from its
             current boot, healthy and ready, nothing pending or held.
  in flight  moved (its branch is at the target) but not settled yet.
"""

from __future__ import annotations

import calendar
import time
from dataclasses import dataclass, field

ANNOTATION = "nixos.ethpandaops.io/"
# The label kured puts on a Node it's draining for a reboot
# (--pre-reboot-node-labels), and comin's testing branches, which a fleet the
# promoter moves must not have.
REBOOTING_LABEL = ("ethpandaops.io/kured", "rebooting")
TESTING_BRANCHES = "testing-*"

# Fingerprint fields compared whole when a class names them in `fields`;
# `series` fields compare major.minor only (1.35.10+k3s1 -> 1.35).


def series(version: str) -> str:
    return ".".join(str(version).split("+")[0].split(".")[:2])


# Change classes


def class_names(plan: dict) -> list[str]:
    return ["none"] + [c["name"] for c in plan["classes"]]


def rank(plan: dict, cls: str) -> int:
    return class_names(plan).index(cls)


def worst(plan: dict, classes) -> str:
    names = class_names(plan)
    return max(classes, key=names.index, default="none")


def differs(old: dict, new: dict, field: str, by=lambda v: v) -> bool:
    """Whether a fingerprint field changed. A field only one side has is
    unknown, not changed: a commit from before the field existed (an older
    nixos-modules, or a fleet that just added it) has no value to compare,
    and the fields that change with it (the kernel's store path for its
    version) still count."""
    return field in old and field in new and by(old[field]) != by(new[field])


def classify(plan: dict, old: dict | None, new: dict) -> str:
    """The most disruptive class between two fingerprints of one host.

    A host whose starting point can't be read or trusted counts as reboot.
    """
    if old is None:
        return "reboot"
    if old["toplevel"] == new["toplevel"]:
        return "none"
    found = plan["classes"][0]["name"]
    for c in plan["classes"]:
        changed = any(differs(old, new, f) for f in c.get("fields", []))
        changed = changed or any(differs(old, new, f, series) for f in c.get("series", []))
        if changed:
            found = c["name"]
    return found


def mixed(plan: dict, cls: str, old: dict | None, new: dict) -> list[str]:
    """Fields a class must not be mixed with that change too, such as a k3s
    minor upgrade that also changes the kernel."""
    if old is None:
        return []
    spec = next((c for c in plan["classes"] if c["name"] == cls), {})
    return [f for f in spec.get("alone", []) if differs(old, new, f)]


# Kubernetes objects


def labels_match(selector: dict | None, labels: dict) -> bool:
    if selector is None:
        return False
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for expr in selector.get("matchExpressions") or []:
        key, op, values = expr["key"], expr["operator"], expr.get("values") or []
        if op == "In" and labels.get(key) not in values:
            return False
        if op == "NotIn" and key in labels and labels[key] in values:
            return False
        if op == "Exists" and key not in labels:
            return False
        if op == "DoesNotExist" and key in labels:
            return False
    return True


def owner_kinds(obj: dict) -> list[str]:
    return [ref["kind"] for ref in obj["metadata"].get("ownerReferences") or []]


def is_evictable(pod: dict) -> bool:
    """What `kubectl drain --ignore-daemonsets` evicts."""
    if pod["status"].get("phase") in ("Succeeded", "Failed"):
        return False
    if "DaemonSet" in owner_kinds(pod):
        return False
    return "kubernetes.io/config.mirror" not in (pod["metadata"].get("annotations") or {})


def condition(obj: dict, kind: str) -> bool:
    return any(c["type"] == kind and c["status"] == "True" for c in obj.get("status", {}).get("conditions") or [])


def pods_on(node: str, pods: list[dict]) -> list[dict]:
    return [p for p in pods if p["spec"].get("nodeName") == node]


def workload_id(pod: dict, replicasets: list[dict]) -> str | None:
    """namespace/Kind/name of the Deployment or StatefulSet a pod belongs to."""
    ns = pod["metadata"]["namespace"]
    for ref in pod["metadata"].get("ownerReferences") or []:
        if ref["kind"] == "StatefulSet":
            return f"{ns}/StatefulSet/{ref['name']}"
        if ref["kind"] == "ReplicaSet":
            for rs in replicasets:
                if rs["metadata"]["namespace"] == ns and rs["metadata"]["name"] == ref["name"]:
                    for owner in rs["metadata"].get("ownerReferences") or []:
                        if owner["kind"] == "Deployment":
                            return f"{ns}/Deployment/{owner['name']}"
    return None


def unready_workloads(deployments: list[dict], statefulsets: list[dict]) -> set[str]:
    out = set()
    for kind, items in (("Deployment", deployments), ("StatefulSet", statefulsets)):
        for w in items:
            want = w["spec"].get("replicas", 1)
            ready = w.get("status", {}).get("readyReplicas", 0)
            if ready < want:
                out.add(f"{w['metadata']['namespace']}/{kind}/{w['metadata']['name']}")
    return out


@dataclass
class Cluster:
    """One `kubectl get -o json` snapshot of what the gates read."""

    nodes: dict[str, dict]
    pods: list[dict] = field(default_factory=list)
    pdbs: list[dict] = field(default_factory=list)
    replicasets: list[dict] = field(default_factory=list)
    deployments: list[dict] = field(default_factory=list)
    statefulsets: list[dict] = field(default_factory=list)

    def unready(self) -> set[str]:
        return unready_workloads(self.deployments, self.statefulsets)

    def not_ready_nodes(self) -> set[str]:
        return {name for name, n in self.nodes.items() if not condition(n, "Ready")}

    def workloads_on(self, node: str) -> set[str]:
        ids = {workload_id(p, self.replicasets) for p in pods_on(node, self.pods) if is_evictable(p)}
        return {i for i in ids if i}


def baseline(cluster: Cluster) -> dict:
    return {"unready": sorted(cluster.unready()), "notReadyNodes": sorted(cluster.not_ready_nodes())}


def pdb_blockers(node: str, cluster: Cluster) -> list[str]:
    """PodDisruptionBudgets that would stop a drain of the node half way."""
    evictable = [p for p in pods_on(node, cluster.pods) if is_evictable(p)]
    out = []
    for pdb in cluster.pdbs:
        ns = pdb["metadata"]["namespace"]
        hit = [
            p["metadata"]["name"]
            for p in evictable
            if p["metadata"]["namespace"] == ns and labels_match(pdb["spec"].get("selector"), p["metadata"].get("labels") or {})
        ]
        allowed = pdb.get("status", {}).get("disruptionsAllowed", 0)
        if len(hit) > allowed:
            out.append(f"{ns}/{pdb['metadata']['name']} allows {allowed}, node has {len(hit)}: {' '.join(hit)}")
    return out


def workloads_not_ready_on(node: str, cluster: Cluster) -> list[str]:
    """Workloads with a pod on the node that aren't fully ready."""
    return sorted(cluster.workloads_on(node) & cluster.unready())


def regressions(base: dict, cluster: Cluster, ignore_nodes=frozenset()) -> list[str]:
    """What is worse than when the roll started."""
    out = [f"workload {w} not ready" for w in sorted(cluster.unready() - set(base.get("unready", [])))]
    for n in sorted(cluster.not_ready_nodes() - set(base.get("notReadyNodes", [])) - set(ignore_nodes)):
        out.append(f"node {n} not Ready")
    return out


# What a host reports on its Node


def parse_time(value: str | None) -> int:
    if not value:
        return 0
    try:
        return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return 0


@dataclass
class NodeView:
    """A host's Node: the annotations its reporter wrote, counted only when
    their boot ID and kernel match what the kubelet reports in
    status.nodeInfo, which nothing but the kubelet can write."""

    name: str
    obj: dict
    rebooting_label: tuple[str, str] = REBOOTING_LABEL

    def ann(self, key: str, default: str = "") -> str:
        return (self.obj["metadata"].get("annotations") or {}).get(ANNOTATION + key, default)

    @property
    def info(self) -> dict:
        return self.obj.get("status", {}).get("nodeInfo", {})

    @property
    def trusted(self) -> bool:
        boot_id, kernel = self.ann("boot-id"), self.ann("kernel")
        return bool(boot_id) and boot_id == self.info.get("bootID") and kernel == self.info.get("kernelVersion")

    @property
    def boot_id(self) -> str:
        return self.info.get("bootID", "")

    @property
    def ready(self) -> bool:
        return condition(self.obj, "Ready")

    @property
    def unschedulable(self) -> bool:
        return bool(self.obj["spec"].get("unschedulable"))

    @property
    def rebooting(self) -> bool:
        key, value = self.rebooting_label
        return (self.obj["metadata"].get("labels") or {}).get(key) == value

    @property
    def revision(self) -> str | None:
        """The commit the host runs, when its report can be trusted."""
        rev = self.ann("revision")
        return rev if self.trusted and rev not in ("", "unknown") else None

    @property
    def reported_at(self) -> int:
        return parse_time(self.ann("reported-at")) if self.trusted else 0

    @property
    def counts(self) -> int:
        try:
            return int(self.ann("rollbacks", "0"))
        except ValueError:
            return 0


def host_problems(view: NodeView | None, target: str, since: int) -> list[str]:
    """Why a moved host isn't settled on the target; empty when it is."""
    if view is None:
        return ["no Node"]
    if not view.trusted:
        return ["its report doesn't match the kubelet's boot ID and kernel"]
    out = []
    if not view.ready:
        out.append("not Ready")
    if view.unschedulable:
        out.append("cordoned")
    if view.reported_at < since:
        out.append("no report since it moved")
    if view.revision != target:
        out.append(f"runs {(view.revision or 'unknown')[:12]}")
    if view.ann("boot-revision") != target:
        out.append(f"boots {view.ann('boot-revision', 'unknown')[:12]}")
    if view.ann("reboot-held"):
        out.append(f"reboot held: {view.ann('reboot-held')}")
    elif view.ann("reboot-required") != "false":
        out.append("reboot pending")
    if view.ann("trial", "none") not in ("none", "confirmed"):
        out.append(f"trial boot {view.ann('trial')}")
    if view.ann("boot-check", "none") not in ("none", "ok"):
        out.append(f"boot check {view.ann('boot-check')}")
    if view.ann("health") != "ok":
        out.append(f"health {view.ann('health', 'unknown')}")
    if view.ann("readiness") != "ok":
        failing = view.ann("readiness-failing")
        out.append(f"readiness {view.ann('readiness', 'unknown')}" + (f" ({failing})" if failing else ""))
    return out


def unsettled(node: str, cluster: Cluster, workloads, baseline_unready=()) -> list[str]:
    """What keeps a host that is back on the target from settling: workloads
    it carried before it moved not ready again (unless they weren't when the
    roll started), and its pods not Ready."""
    out = []
    lost = sorted(set(workloads) & cluster.unready() - set(baseline_unready))
    if lost:
        out.append("workloads not back: " + ", ".join(lost[:5]))
    pods = [
        p["metadata"]["namespace"] + "/" + p["metadata"]["name"]
        for p in pods_on(node, cluster.pods)
        if p["status"].get("phase") not in ("Succeeded", "Failed") and not condition(p, "Ready")
    ]
    if pods:
        out.append("pods not Ready: " + ", ".join(sorted(pods)[:5]))
    return out


def flight_state(view: NodeView | None, hs: dict, target: str) -> str:
    """Where an in-flight host is, for its time budget: deploy, lock, drain,
    boot or ready."""
    if view is None or not view.trusted or view.reported_at < hs["advancedAt"]:
        return "deploy"
    rebooted = view.boot_id != hs.get("bootId")
    if rebooted and (not view.ready or "pending" in (view.ann("trial"), view.ann("boot-check"))):
        return "boot"
    if view.ann("reboot-required") == "true":
        if view.ann("reboot-held"):
            return "boot"
        return "drain" if view.unschedulable or view.rebooting else "lock"
    if view.revision != target or view.ann("boot-revision") != target or view.ann("health") != "ok":
        return "deploy"
    return "ready"


def budget_minutes(plan: dict, host: str, state: str) -> int:
    b = plan["budgets"]
    if state == "ready":
        return plan["hosts"][host].get("readinessMinutes", 0) + b["readyMargin"]
    return b[state]


# Ordering, canaries and soaks


def waves_of(plan: dict, env: str) -> list[dict]:
    return plan["environments"][env]["waves"]


def env_index(plan: dict, env: str) -> int:
    return plan["environmentOrder"].index(env)


def host_order(waves: list[dict], first: list[str], deferred: set[str]) -> list[str]:
    """Hosts in wave order: `first` hosts ahead of everyone, deferred hosts
    after the rest but still ahead of the waves marked last."""

    def deferred_last(hosts: list[str]) -> list[str]:
        return [h for h in hosts if h not in deferred] + [h for h in hosts if h in deferred]

    early = [h for w in waves if not w.get("last") for h in w["hosts"] if h not in first]
    late = [h for w in waves if w.get("last") for h in w["hosts"] if h not in first]
    return list(first) + deferred_last(early) + deferred_last(late)


def wave_of(waves: list[dict], host: str) -> dict | None:
    return next((w for w in waves if host in w["hosts"]), None)


def first_canary(waves: list[dict]) -> str | None:
    for w in waves:
        if w["name"] == "canary" and w["hosts"]:
            return w["hosts"][0]
    return None


def soaks(plan: dict, waves: list[dict], hosts_state: dict, target: str, host: str) -> bool:
    """Whether a host soaks after it settles: a canary does; with group
    canaries so does the first host of each group to move, and the rest of
    the group bakes once at its end; without them every host soaks."""
    wave = wave_of(waves, host)
    if wave is None or wave["name"] == "canary" or not plan.get("groupCanaries"):
        return True
    moved = [
        (hs["advancedAt"], h)
        for h, hs in hosts_state.items()
        if h in wave["hosts"] and hs.get("target") == target and hs.get("advancedAt") and not hs.get("skipped")
    ]
    return bool(moved) and min(moved)[1] == host


def soak_minutes(plan: dict, env: str, waves: list[dict], host: str, cls: str, urgent: bool) -> int:
    if cls == "none":
        return 0
    if urgent:
        return plan["urgent"]["soak"]
    minutes = plan["soak"][env][cls]
    if env_index(plan, env) > 0 and host == first_canary(waves):
        minutes += plan["canaryExtra"][cls]
    return minutes


def in_window(plan: dict, env: str, cls: str, now: int) -> bool:
    """Whether a move of this class may happen now in this environment."""
    window = plan.get("windows", {}).get(env)
    if not window or rank(plan, cls) < rank(plan, window["fromClass"]):
        return True
    t = time.gmtime(now)
    minute = t.tm_hour * 60 + t.tm_min
    if t.tm_wday + 1 not in window["days"]:
        return False
    start, end = window["start"], window["end"]
    return start <= minute < end if start <= end else minute >= start or minute < end


# Targets


def newer_target(candidate: str | None, state: dict, urgent_range: bool) -> bool:
    """Whether the environment takes a new target now: it keeps the one it has
    until it converges or halts, unless every commit between the two carries
    an Urgency: trailer backed by evidence."""
    current = state.get("target")
    if not candidate or candidate == current:
        return False
    if not current or state.get("convergedTarget") == current:
        return True
    return urgent_range


def promote_target(prev_state: dict, state: dict, plan: dict, now: int) -> str | None:
    """A later environment's eligible commit: the newest one the environment
    before it converged on for which every commit staged since this
    environment last converged has finished its promote soak, and has a
    person's approval when it changes this environment more than the one
    before saw."""
    staged = prev_state.get("staged", [])
    done = {state.get("convergedTarget")} | set(state.get("abandoned", []))
    start = 0
    for i, entry in enumerate(staged):
        if entry["commit"] in done:
            start = i + 1
    eligible = None
    for entry in staged[start:]:
        soak = plan["urgent"]["promote"] if entry.get("urgent") else plan["promote"][entry["class"]]
        if now < entry["at"] + 60 * soak:
            break
        if entry.get("needsApproval") and entry["commit"] not in state.get("approved", []):
            break
        eligible = entry["commit"]
    return eligible


# One step


@dataclass
class Action:
    # need, advance, push, skip, defer, settle, converge, halt, wait or done
    kind: str
    host: str | None = None
    reason: str = ""
    data: dict = field(default_factory=dict)


@dataclass
class Snapshot:
    env: str
    plan: dict
    target: str
    state: dict
    now: int
    refs: dict[str, str | None]  # host -> deploy branch commit, None before it runs NixOS
    nodes: dict[str, NodeView | None]  # host -> its Node
    cluster: Cluster
    held: bool = False  # the hold file on the source branch's head
    testing: list[str] = field(default_factory=list)  # comin testing branches on the remote
    urgent: bool = False  # every commit in this roll's range is urgent, with evidence
    lane: set[str] = field(default_factory=set)  # hosts on a bad commit, moved first
    # Filled on demand by promote.py (Action need):
    classes: dict[str, str] = field(default_factory=dict)  # host -> class, from what it runs
    mixed: dict[str, list[str]] = field(default_factory=dict)
    provenance: dict[str, str] = field(default_factory=dict)  # host -> "" when good, else why not
    alerts: dict[str, list[str]] | None = None  # host -> firing alerts; None while not read


def moved(s: Snapshot, host: str) -> dict | None:
    hs = s.state.get("hosts", {}).get(host)
    if hs and hs.get("target") == s.target and hs.get("advancedAt") and not hs.get("skipped"):
        return hs
    return None


def plan_step(s: Snapshot) -> Action:
    """The next thing the promoter does for one environment."""
    plan, env, target = s.plan, s.env, s.target
    waves = waves_of(plan, env)
    hosts_state = s.state.setdefault("hosts", {})
    migrated = [h for w in waves for h in w["hosts"] if s.refs.get(h)]

    if s.state.get("halted"):
        h = s.state["halted"]
        return Action("halt", h.get("host"), f"halted earlier: {h['reason']}")
    if s.testing:
        return Action("halt", None, f"comin testing branches exist: {', '.join(s.testing)}")

    # A move recorded but not pushed: push it again.
    for host in migrated:
        hs = hosts_state.get(host, {})
        if hs.get("target") == target and hs.get("intent") and s.refs.get(host) != target:
            return Action("push", host, "recorded move not on its branch yet")

    # Every host moved in this roll stays watched until the environment converges.
    in_flight = []
    for host in migrated:
        hs = moved(s, host)
        if not hs or s.refs.get(host) != target:
            continue
        view = s.nodes.get(host)
        if view is not None and view.trusted and view.counts > hs.get("counts", 0):
            return Action("halt", host, "it rolled back or reverted a trial boot after it moved", {"state": hs.get("state", "")})
        if view is not None and view.trusted and view.ann("rollback-breaker") == "open" and view.ann("health") == "failed":
            return Action(
                "halt", host, "its health checks fail and its rollback breaker is open, so it won't roll back: a person decides", {"state": "breaker"}
            )
        if view is not None and view.trusted and view.ann("readiness") == "failed":
            return Action("halt", host, f"readiness failed: {view.ann('readiness-failing')}", {"state": "ready"})
        if hs.get("settledAt"):
            why = host_problems(view, target, hs["advancedAt"])
            if why:
                since = hs.get("watchSince") or s.now
                if s.now - since >= 60 * plan["budgets"]["watchGrace"]:
                    return Action("halt", host, "no longer settled: " + "; ".join(why), {"state": "watch"})
                return Action("wait", host, "watching: " + "; ".join(why), {"watchSince": since})
            hs.pop("watchSince", None)
            continue
        in_flight.append(host)

    for host in in_flight:
        hs = hosts_state[host]
        view = s.nodes.get(host)
        why = host_problems(view, target, hs["advancedAt"])
        node = plan["hosts"][host]["node"]
        if not why:
            why = unsettled(node, s.cluster, hs.get("workloads", []), s.state.get("baseline", {}).get("unready", []))
        if not why:
            return Action("settle", host, "back on the target")
        state = flight_state(view, hs, target)
        since = hs["stateSince"] if hs.get("state") == state else s.now
        if s.now - since >= 60 * budget_minutes(plan, host, state):
            return Action("halt", host, f"past its {state} budget: " + "; ".join(why), {"state": state})
        return Action("wait", host, f"{state}: " + "; ".join(why), {"state": state, "stateSince": since})

    if s.held:
        return Action("wait", reason=f"{plan['holdFile']} exists on {plan['sourceBranch']}")

    # Soak after the host that settled last, or bake at the end of its group.
    settled = sorted((hs["settledAt"], h) for h, hs in hosts_state.items() if hs.get("target") == target and hs.get("settledAt") and not hs.get("skipped"))
    pending = [h for h in migrated if s.refs.get(h) != target]
    if settled and pending:
        at, last = settled[-1]
        cls = hosts_state[last].get("class", "reboot")
        wave = wave_of(waves, last)
        if soaks(plan, waves, hosts_state, target, last):
            until = at + 60 * soak_minutes(plan, env, waves, last, cls, s.urgent)
            if s.now < until:
                return Action("wait", last, f"soaking until {time.strftime('%H:%M UTC', time.gmtime(until))}")
        elif wave and not any(h in wave["hosts"] for h in pending):
            group = [hs.get("class", "reboot") for h, hs in hosts_state.items() if h in wave["hosts"] and hs.get("target") == target]
            until = at + 60 * soak_minutes(plan, env, waves, last, worst(plan, group), s.urgent)
            if s.now < until:
                return Action("wait", last, f"group {wave['name']} baking until {time.strftime('%H:%M UTC', time.gmtime(until))}")

    if not pending:
        if not migrated:
            return Action("done", reason="no host of this environment runs NixOS yet")
        if s.state.get("convergedTarget") != target:
            return Action("converge", reason="every host runs the target")
        return Action("done", reason="every host runs the target")

    # Hosts in a group that some class rolls first must be classified first.
    first_groups = {g for c in plan["classes"] for g in c.get("first", [])}
    for host in pending:
        if plan["hosts"][host]["group"] in first_groups and host not in s.classes:
            return Action("need", host, "class", {"need": "class"})
    first = [h for h in s.lane if h in pending]
    for host in pending:
        spec = next((c for c in plan["classes"] if c["name"] == s.classes.get(host)), {})
        if host not in first and plan["hosts"][host]["group"] in spec.get("first", []):
            first.append(host)
    deferred = {h for h, hs in hosts_state.items() if hs.get("target") == target and hs.get("deferred")}
    host = next(h for h in host_order(waves, first, deferred) if h in pending)

    if host not in s.classes:
        return Action("need", host, "class", {"need": "class"})
    cls = s.classes[host]
    if host not in s.provenance:
        return Action("need", host, "provenance", {"need": "provenance"})
    if s.provenance[host]:
        return Action("halt", host, s.provenance[host], {"state": "provenance"})
    if s.mixed.get(host):
        return Action("halt", host, f"a {cls} change also changes {', '.join(s.mixed[host])}; ship those separately")
    if cls == "none":
        return Action("skip", host, "its system doesn't change")

    lane = host in s.lane
    view = s.nodes.get(host)
    node = plan["hosts"][host]["node"]
    blockers = []
    if rank(plan, cls) >= rank(plan, "reboot"):
        blockers += pdb_blockers(node, s.cluster)
    if not lane:
        if view is None or not view.trusted or view.ann("readiness") != "ok":
            blockers.append("not ready: " + (view.ann("readiness-failing") or view.ann("readiness", "unknown") if view else "no Node"))
        blockers += [f"not ready: {w}" for w in workloads_not_ready_on(node, s.cluster)]
    if blockers:
        if host in deferred:
            return Action("wait", host, "; ".join(blockers))
        return Action("defer", host, "; ".join(blockers))
    if not lane:
        regress = regressions(s.state.get("baseline", {}), s.cluster)
        if regress:
            since = s.state.get("regressionSince") or s.now
            if s.now - since >= 60 * plan["budgets"]["regression"]:
                return Action("halt", host, "the cluster stayed worse than when the roll started: " + "; ".join(regress), {"state": "regression"})
            return Action("wait", host, "; ".join(regress), {"regressionSince": since})
    if s.alerts is None and plan.get("alerts"):
        return Action("need", host, "alerts", {"need": "alerts"})
    firing = (s.alerts or {}).get(host, [])
    if firing:
        return Action("wait", host, "alerts firing: " + ", ".join(firing[:5]))
    if not in_window(plan, env, cls, s.now):
        return Action("wait", host, f"a {cls} move waits for the promotion window")
    workloads = sorted(s.cluster.workloads_on(node))
    return Action("advance", host, cls, {"workloads": workloads})
