"""Tests for the promoter's decisions. Run: python3 -m unittest (in this directory).

The plan below has the shape lib.rolloutPlan produces, with the classes a k3s
fleet adds (k3s-restart, and k3s-minor, which starts on the server and can't
be mixed with boot changes). Several tests reproduce what the design reviews
found in the first prototype; their names say which rule they hold.
"""

import calendar
import copy
import json
import os
import time
import unittest

import logic

OLD, TARGET, NEWER = "a" * 40, "b" * 40, "c" * 40
NOW = calendar.timegm((2026, 11, 25, 10, 0, 0))  # a Wednesday, 10:00 UTC


def fp(**over):
    base = {
        "toplevel": "/nix/store/1-system.drv",
        "kernel": "/nix/store/k1.drv",
        "kernelVersion": "6.18.4",
        "initrd": "/nix/store/i1.drv",
        "systemd": "/nix/store/s1.drv",
        "kernelParams": ["audit=1"],
        "kernelModules": ["overlay"],
        "inhibitors": {"k3s-version": "1.35.10+k3s1"},
        "nixosRelease": "26.05",
        "k3sVersion": "1.35.10+k3s1",
        "k3sUnit": "u1",
    }
    base.update(over)
    return base


REBOOT_FIELDS = ["kernel", "initrd", "systemd", "kernelParams", "kernelModules", "inhibitors"]
CLASSES = [
    {"name": "switch"},
    {"name": "k3s-restart", "fields": ["k3sUnit"]},
    {"name": "reboot", "fields": REBOOT_FIELDS},
    {"name": "kernel-series", "series": ["kernelVersion"]},
    {"name": "release", "fields": ["nixosRelease"]},
    {"name": "k3s-minor", "series": ["k3sVersion"], "first": ["server"], "alone": ["kernel", "initrd", "systemd", "kernelParams", "kernelModules"]},
]
SOAK = {"switch": 5, "k3s-restart": 10, "reboot": 20, "kernel-series": 60, "release": 60, "k3s-minor": 60}


def host(env, group, node, canary=False, readiness=30):
    return {
        "env": env,
        "fleet": "fleet",
        "group": group,
        "canary": canary,
        "lead": False,
        "node": node,
        "deployBranch": f"deploy/{env}-{node}",
        "readinessMinutes": readiness,
        "trialMinutes": 20,
    }


PLAN = {
    "fleet": "fleet",
    "environmentOrder": ["staging", "production"],
    "environments": {
        "staging": {"waves": [{"name": "small", "hosts": ["s-small-1"]}, {"name": "server", "hosts": ["s-server"]}]},
        "production": {
            "waves": [
                {"name": "canary", "hosts": ["p-small-1"]},
                {"name": "large", "hosts": ["p-large-1", "p-large-2"]},
                {"name": "server", "hosts": ["p-server"]},
                {"name": "precious", "hosts": ["p-precious-1"], "last": True},
            ]
        },
    },
    "hosts": {
        "s-small-1": host("staging", "small", "small-1"),
        "s-server": host("staging", "server", "server"),
        "p-small-1": host("production", "small", "small-1", canary=True),
        "p-large-1": host("production", "large", "large-1"),
        "p-large-2": host("production", "large", "large-2", readiness=120),
        "p-server": host("production", "server", "server"),
        "p-precious-1": host("production", "precious", "precious-1"),
    },
    "classes": CLASSES,
    "groupCanaries": False,
    "soak": {"staging": {**SOAK, "reboot": 15}, "production": SOAK},
    "canaryExtra": {"switch": 30, "k3s-restart": 60, "reboot": 240, "kernel-series": 1440, "release": 1440, "k3s-minor": 1440},
    "promote": {"switch": 60, "k3s-restart": 120, "reboot": 360, "kernel-series": 1440, "release": 1440, "k3s-minor": 1440},
    "urgent": {"soak": 10, "promote": 60},
    "budgets": {"deploy": 20, "lock": 125, "drain": 20, "boot": 35, "readyMargin": 5, "regression": 30, "watchGrace": 10, "waitNotice": 120},
    "windows": {},
    "alerts": False,
    "holdFile": "rollout/hold",
    "sourceBranch": "master",
}
PROD = [h for w in PLAN["environments"]["production"]["waves"] for h in w["hosts"]]


def node(
    name,
    revision=TARGET,
    boot=None,
    boot_id="boot-1",
    kernel="6.18.4",
    reported=NOW,
    ready=True,
    unschedulable=False,
    reboot="false",
    held="",
    health="ok",
    readiness="ok",
    trial="none",
    boot_check="none",
    rollbacks=0,
    info_boot=None,
    info_kernel=None,
    labels=None,
):
    ann = {
        "revision": revision,
        "boot-revision": boot or revision,
        "reboot-required": reboot,
        "reboot-held": held,
        "health": health,
        "readiness": readiness,
        "readiness-failing": "" if readiness == "ok" else "execution-synced",
        "rollbacks": str(rollbacks),
        "boot-id": boot_id,
        "kernel": kernel,
        "trial": trial,
        "boot-check": boot_check,
        "reported-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(reported)),
    }
    return {
        "metadata": {"name": name, "annotations": {logic.ANNOTATION + k: v for k, v in ann.items()}, "labels": labels or {}},
        "spec": {"unschedulable": unschedulable},
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "nodeInfo": {"bootID": info_boot or boot_id, "kernelVersion": info_kernel or kernel},
        },
    }


def pod(name, node_name, ns="mainnet", labels=None, owner=("StatefulSet", "x"), ready=True, phase="Running"):
    return {
        "metadata": {"name": name, "namespace": ns, "labels": labels or {}, "ownerReferences": [{"kind": owner[0], "name": owner[1]}] if owner else []},
        "spec": {"nodeName": node_name},
        "status": {"phase": phase, "conditions": [{"type": "Ready", "status": "True" if ready else "False"}]},
    }


def sts(name, ns="mainnet", want=1, ready=1):
    return {"metadata": {"name": name, "namespace": ns}, "spec": {"replicas": want}, "status": {"readyReplicas": ready}}


def pdb(name, ns, selector, allowed):
    return {"metadata": {"name": name, "namespace": ns}, "spec": {"selector": selector}, "status": {"disruptionsAllowed": allowed}}


def nodes_on(rev=OLD, **over):
    """Every production Node running `rev`; over maps a node name to node() kwargs."""
    return {h: node(PLAN["hosts"][h]["node"], **{"revision": rev, **over.get(PLAN["hosts"][h]["node"], {})}) for h in PROD}


def snapshot(plan=None, nodes=None, pods=None, pdbs=None, statefulsets=None, hosts=None, **over):
    plan = plan or PLAN
    nodes = nodes if nodes is not None else nodes_on()
    cluster = logic.Cluster(nodes={n["metadata"]["name"]: n for n in nodes.values()}, pods=pods or [], pdbs=pdbs or [], statefulsets=statefulsets or [])
    state = {"target": TARGET, "baseline": {"unready": [], "notReadyNodes": []}, "hosts": copy.deepcopy(hosts or {})}
    state.update(over.pop("state", {}))
    s = dict(
        env="production",
        plan=plan,
        target=TARGET,
        state=state,
        now=NOW,
        refs={h: OLD for h in PROD},
        nodes={h: logic.NodeView(n["metadata"]["name"], n) for h, n in nodes.items()},
        cluster=cluster,
        classes={"p-server": "reboot"},
        provenance={h: "" for h in PROD},
    )
    s.update(over)
    return logic.Snapshot(**s)


def moved(at=NOW - 600, settled=None, cls="reboot", counts=0, boot_id="boot-0", **extra):
    hs = {"target": TARGET, "advancedAt": at, "class": cls, "counts": counts, "bootId": boot_id, "intent": True}
    if settled:
        hs["settledAt"] = settled
    hs.update(extra)
    return hs


class Classify(unittest.TestCase):
    def test_same_system_is_none(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(kernel="other")), "none")

    def test_new_user_is_switch(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2")), "switch")

    def test_k3s_flag_is_restart(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2", k3sUnit="u2")), "k3s-restart")

    def test_kernel_patch_is_reboot_even_with_a_unit_change(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2", k3sUnit="u2", kernel="k2", kernelVersion="6.18.5")), "reboot")

    def test_k3s_patch_is_reboot_through_its_inhibitor(self):
        new = fp(toplevel="2", k3sVersion="1.35.11+k3s1", inhibitors={"k3s-version": "1.35.11+k3s1"})
        self.assertEqual(logic.classify(PLAN, fp(), new), "reboot")

    def test_kernel_series_is_its_own_class(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2", kernel="k2", kernelVersion="6.19.1")), "kernel-series")

    def test_nixos_release_is_its_own_class(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2", systemd="s2", nixosRelease="26.11")), "release")

    def test_k3s_minor_wins_over_everything(self):
        new = fp(toplevel="2", kernel="k2", k3sVersion="1.36.1+k3s1", inhibitors={"k3s-version": "1.36.1+k3s1"})
        self.assertEqual(logic.classify(PLAN, fp(), new), "k3s-minor")
        self.assertEqual(logic.mixed(PLAN, "k3s-minor", fp(), new), ["kernel"])

    def test_pure_k3s_minor_is_not_mixed(self):
        new = fp(toplevel="2", k3sVersion="1.36.1+k3s1", inhibitors={"k3s-version": "1.36.1+k3s1"})
        self.assertEqual(logic.mixed(PLAN, "k3s-minor", fp(), new), [])

    def test_module_list_change_is_reboot(self):
        self.assertEqual(logic.classify(PLAN, fp(), fp(toplevel="2", kernelModules=["overlay", "wireguard"])), "reboot")

    def test_unknown_start_is_reboot(self):
        self.assertEqual(logic.classify(PLAN, None, fp()), "reboot")


class Gates(unittest.TestCase):
    def test_blocks_when_node_holds_more_than_allowed(self):
        c = logic.Cluster(
            nodes={},
            pods=[pod("a", "n", labels={"app": "x"}), pod("b", "n", labels={"app": "x"})],
            pdbs=[pdb("p", "mainnet", {"matchLabels": {"app": "x"}}, 1)],
        )
        self.assertEqual(len(logic.pdb_blockers("n", c)), 1)

    def test_other_namespace_does_not_count(self):
        c = logic.Cluster(nodes={}, pods=[pod("a", "n", ns="other", labels={"app": "x"})], pdbs=[pdb("p", "mainnet", {"matchLabels": {"app": "x"}}, 0)])
        self.assertEqual(logic.pdb_blockers("n", c), [])

    def test_daemonset_and_finished_pods_do_not_count(self):
        c = logic.Cluster(
            nodes={},
            pods=[pod("a", "n", labels={"app": "x"}, owner=("DaemonSet", "d")), pod("b", "n", labels={"app": "x"}, phase="Succeeded")],
            pdbs=[pdb("p", "mainnet", {"matchLabels": {"app": "x"}}, 0)],
        )
        self.assertEqual(logic.pdb_blockers("n", c), [])

    def test_match_expressions(self):
        sel = {"matchExpressions": [{"key": "app", "operator": "In", "values": ["x", "y"]}, {"key": "skip", "operator": "DoesNotExist"}]}
        self.assertTrue(logic.labels_match(sel, {"app": "y"}))
        self.assertFalse(logic.labels_match(sel, {"app": "y", "skip": "1"}))
        self.assertFalse(logic.labels_match(sel, {"app": "z"}))

    def test_only_new_problems_count(self):
        c = logic.Cluster(nodes={"n1": node("n1", ready=False), "n2": node("n2", ready=False)}, statefulsets=[sts("a", ready=0), sts("b", ready=0)])
        self.assertEqual(
            logic.regressions({"unready": ["mainnet/StatefulSet/a"], "notReadyNodes": ["n1"]}, c),
            ["workload mainnet/StatefulSet/b not ready", "node n2 not Ready"],
        )


class Reports(unittest.TestCase):
    def view(self, **kw):
        return logic.NodeView("n", node("n", **kw))

    def test_back_on_target(self):
        self.assertEqual(logic.host_problems(self.view(), TARGET, NOW - 60), [])

    def test_each_reason(self):
        why = logic.host_problems(
            self.view(revision=OLD, boot=TARGET, reboot="true", health="failed", readiness="pending", ready=False, unschedulable=True), TARGET, NOW - 60
        )
        for part in ("not Ready", "cordoned", "runs aaaa", "reboot pending", "health failed", "readiness pending"):
            self.assertTrue(any(part in w for w in why), (part, why))

    def test_a_report_from_another_boot_is_not_trusted(self):
        v = self.view(info_boot="boot-2")
        self.assertFalse(v.trusted)
        self.assertIsNone(v.revision)
        self.assertEqual(logic.host_problems(v, TARGET, 0), ["its report doesn't match the kubelet's boot ID and kernel"])

    def test_a_report_with_another_kernel_is_not_trusted(self):
        self.assertFalse(self.view(info_kernel="6.18.5").trusted)

    def test_an_old_report_does_not_settle(self):
        self.assertIn("no report since it moved", logic.host_problems(self.view(reported=NOW - 3600), TARGET, NOW - 600))

    def test_trial_and_boot_check_must_be_done(self):
        why = logic.host_problems(self.view(trial="pending", boot_check="pending"), TARGET, 0)
        self.assertIn("trial boot pending", why)
        self.assertIn("boot check pending", why)

    def test_a_held_reboot_is_not_settled(self):
        self.assertIn("reboot held: trial-not-armed", logic.host_problems(self.view(reboot="true", held="trial-not-armed"), TARGET, 0))


class Order(unittest.TestCase):
    WAVES = PLAN["environments"]["production"]["waves"]

    def test_a_deferred_host_still_goes_before_the_last_wave(self):
        self.assertEqual(logic.host_order(self.WAVES, [], {"p-small-1"}), ["p-large-1", "p-large-2", "p-server", "p-small-1", "p-precious-1"])

    def test_first_hosts_lead(self):
        self.assertEqual(logic.host_order(self.WAVES, ["p-server"], set())[:2], ["p-server", "p-small-1"])

    def test_window(self):
        plan = {**PLAN, "windows": {"production": {"days": [1, 2, 3, 4, 5], "start": 8 * 60, "end": 16 * 60, "fromClass": "reboot"}}}
        self.assertTrue(logic.in_window(plan, "production", "reboot", NOW))
        self.assertFalse(logic.in_window(plan, "production", "reboot", NOW + 8 * 3600))
        self.assertFalse(logic.in_window(plan, "production", "reboot", NOW + 3 * 86400))  # Saturday
        self.assertTrue(logic.in_window(plan, "production", "switch", NOW + 8 * 3600))
        self.assertTrue(logic.in_window(plan, "staging", "reboot", NOW + 8 * 3600))


class Targets(unittest.TestCase):
    def test_keeps_its_target_mid_roll(self):
        self.assertFalse(logic.newer_target(NEWER, {"target": TARGET}, False))

    def test_takes_a_new_target_once_converged(self):
        self.assertTrue(logic.newer_target(NEWER, {"target": TARGET, "convergedTarget": TARGET}, False))

    def test_only_an_urgent_range_preempts(self):
        self.assertTrue(logic.newer_target(NEWER, {"target": TARGET}, True))

    def staged(self, *entries):
        return {"staged": [dict(commit=c, at=at, **{"class": cls}, **extra) for c, at, cls, extra in entries]}

    def test_a_switch_on_top_of_a_kernel_patch_waits_for_the_kernel_soak(self):
        first = self.staged((TARGET, NOW - 3 * 3600, "reboot", {}), (NEWER, NOW - 2 * 3600, "switch", {}))
        self.assertIsNone(logic.promote_target(first, {}, PLAN, NOW))
        self.assertEqual(logic.promote_target(first, {}, PLAN, NOW + 3 * 3600), NEWER)

    def test_starts_after_what_it_last_converged_on(self):
        first = self.staged((OLD, NOW - 9 * 3600, "reboot", {}), (TARGET, NOW - 2 * 3600, "switch", {}))
        self.assertEqual(logic.promote_target(first, {"convergedTarget": OLD}, PLAN, NOW), TARGET)

    def test_a_change_bigger_than_staging_saw_waits_for_approval(self):
        first = self.staged((TARGET, NOW - 2 * 86400, "k3s-minor", {"needsApproval": True}))
        self.assertIsNone(logic.promote_target(first, {}, PLAN, NOW))
        self.assertEqual(logic.promote_target(first, {"approved": [TARGET]}, PLAN, NOW), TARGET)

    def test_an_urgent_commit_promotes_after_an_hour(self):
        first = self.staged((TARGET, NOW - 3700, "reboot", {"urgent": True}))
        self.assertEqual(logic.promote_target(first, {}, PLAN, NOW), TARGET)


class Step(unittest.TestCase):
    def test_classifies_then_checks_provenance_then_advances_the_canary(self):
        s = snapshot(provenance={})
        self.assertEqual((logic.plan_step(s).kind, logic.plan_step(s).host), ("need", "p-small-1"))
        s.classes["p-small-1"] = "reboot"
        self.assertEqual(logic.plan_step(s).data, {"need": "provenance"})
        s.provenance["p-small-1"] = ""
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.host, a.reason), ("advance", "p-small-1", "reboot"))

    def test_an_unsigned_commit_halts_at_once(self):
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, provenance={"p-small-1": "not signed by an allowed key: cccc"})
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.host), ("halt", "p-small-1"))

    def test_unmigrated_hosts_are_left_alone(self):
        s = snapshot(refs={h: None for h in PROD})
        self.assertEqual(logic.plan_step(s).kind, "done")

    def test_waits_while_a_host_deploys(self):
        s = snapshot(hosts={"p-small-1": moved()}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=nodes_on(OLD))
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["state"]), ("wait", "deploy"))

    def test_halts_past_the_deploy_budget_and_names_it(self):
        hs = moved(at=NOW - 3600, state="deploy", stateSince=NOW - 21 * 60)
        s = snapshot(hosts={"p-small-1": hs}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=nodes_on(OLD))
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["state"]), ("halt", "deploy"))

    def test_a_reboot_gets_its_drain_and_boot_budgets_not_the_deploy_one(self):
        # Waiting 30 min on a drain halts (drain budget 20); 30 min in a trial boot doesn't (35).
        draining = nodes_on(OLD, **{"small-1": dict(boot=TARGET, reboot="true", unschedulable=True, reported=NOW, boot_id="boot-0")})
        hs = moved(at=NOW - 3600, state="drain", stateSince=NOW - 30 * 60)
        s = snapshot(hosts={"p-small-1": hs}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=draining)
        self.assertEqual(logic.plan_step(s).data["state"], "drain")
        self.assertEqual(logic.plan_step(s).kind, "halt")
        booting = nodes_on(OLD, **{"small-1": dict(revision=TARGET, boot_id="boot-1", trial="pending", boot_check="pending")})
        hs = moved(at=NOW - 3600, state="boot", stateSince=NOW - 30 * 60)
        s = snapshot(hosts={"p-small-1": hs}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=booting)
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["state"]), ("wait", "boot"))

    def test_a_two_hour_readiness_check_gets_two_hours(self):
        syncing = nodes_on(OLD, **{"large-2": dict(revision=TARGET, readiness="pending")})
        hs = moved(at=NOW - 7000, state="ready", stateSince=NOW - 100 * 60, cls="switch")
        refs = {**{h: TARGET for h in ["p-small-1", "p-large-1"]}, "p-large-2": TARGET, "p-server": OLD, "p-precious-1": OLD}
        hosts = {"p-small-1": moved(settled=NOW - 9000), "p-large-1": moved(settled=NOW - 8000), "p-large-2": hs}
        nodes = {**syncing, "p-small-1": node("small-1"), "p-large-1": node("large-1")}
        a = logic.plan_step(snapshot(hosts=hosts, refs=refs, nodes=nodes))
        self.assertEqual((a.kind, a.data.get("state")), ("wait", "ready"))

    def test_a_failed_readiness_check_halts(self):
        nodes = nodes_on(OLD, **{"small-1": dict(revision=TARGET, readiness="failed")})
        s = snapshot(hosts={"p-small-1": moved()}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=nodes)
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["state"]), ("halt", "ready"))

    def test_a_failing_host_with_its_breaker_open_halts_at_once(self):
        nodes = nodes_on(OLD, **{"small-1": {"revision": TARGET, "health": "failed"}})
        nodes["p-small-1"]["metadata"]["annotations"][logic.ANNOTATION + "rollback-breaker"] = "open"
        s = snapshot(
            hosts={"p-small-1": moved(at=NOW - 60, state="deploy", stateSince=NOW - 60)}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=nodes
        )
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["state"]), ("halt", "breaker"))

    def test_halts_on_a_rollback(self):
        nodes = nodes_on(OLD, **{"small-1": dict(rollbacks=1)})
        s = snapshot(hosts={"p-small-1": moved()}, refs={**{h: OLD for h in PROD}, "p-small-1": TARGET}, nodes=nodes)
        self.assertEqual(logic.plan_step(s).kind, "halt")

    def test_a_trial_that_reverts_after_its_host_settled_halts_the_roll(self):
        # Review: the next host moved on stale health while the trial reverted.
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET}
        nodes = nodes_on(OLD, **{"small-1": dict(revision=OLD, boot=OLD, boot_id="boot-2", rollbacks=1)})
        s = snapshot(hosts={"p-small-1": moved(settled=NOW - 300)}, refs=refs, nodes=nodes)
        self.assertEqual(logic.plan_step(s).kind, "halt")

    def test_a_settled_host_that_stops_reporting_halts_after_the_grace(self):
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET}
        nodes = nodes_on(OLD, **{"small-1": dict(revision=TARGET, info_boot="boot-9")})
        s = snapshot(hosts={"p-small-1": moved(settled=NOW - 300)}, refs=refs, nodes=nodes)
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.host), ("wait", "p-small-1"))
        s = snapshot(hosts={"p-small-1": moved(settled=NOW - 3000, watchSince=NOW - 11 * 60)}, refs=refs, nodes=nodes)
        self.assertEqual(logic.plan_step(s).kind, "halt")

    def test_settles_then_soaks_longer_after_the_first_canary(self):
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET}
        nodes = {**nodes_on(OLD), "p-small-1": node("small-1")}
        s = snapshot(hosts={"p-small-1": moved()}, refs=refs, nodes=nodes)
        self.assertEqual(logic.plan_step(s).kind, "settle")
        s.state["hosts"]["p-small-1"]["settledAt"] = NOW
        s.now = NOW + 3600
        self.assertEqual(logic.plan_step(s).kind, "wait")  # 20 + 240 minutes after a reboot
        s.now = NOW + 261 * 60
        s.classes["p-large-1"] = "reboot"
        self.assertEqual(logic.plan_step(s).kind, "advance")

    def test_urgent_soaks_are_short_but_keep_the_canary(self):
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET}
        nodes = {**nodes_on(OLD), "p-small-1": node("small-1")}
        s = snapshot(hosts={"p-small-1": moved(settled=NOW)}, refs=refs, nodes=nodes, urgent=True, classes={"p-server": "reboot", "p-large-1": "reboot"})
        s.now = NOW + 9 * 60
        self.assertEqual(logic.plan_step(s).kind, "wait")
        s.now = NOW + 10 * 60
        self.assertEqual(logic.plan_step(s).kind, "advance")

    def test_group_canaries_soak_the_first_host_and_bake_the_group_once(self):
        plan = {**PLAN, "groupCanaries": True}
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET, "p-large-1": TARGET}
        nodes = {**nodes_on(OLD), "p-small-1": node("small-1"), "p-large-1": node("large-1")}
        hosts = {"p-small-1": moved(at=NOW - 90000, settled=NOW - 80000), "p-large-1": moved(at=NOW - 2000, settled=NOW - 600)}
        s = snapshot(plan=plan, hosts=hosts, refs=refs, nodes=nodes, classes={"p-server": "reboot", "p-large-2": "reboot"})
        self.assertEqual(logic.plan_step(s).kind, "wait")  # the group's first host soaks 20 min
        s.now = NOW + 15 * 60
        self.assertEqual((logic.plan_step(s).kind, logic.plan_step(s).host), ("advance", "p-large-2"))
        # The group's second host settles: no soak of its own, but the group bakes before the server.
        s.refs["p-large-2"] = TARGET
        s.state["hosts"]["p-large-2"] = moved(at=NOW, settled=NOW + 16 * 60)
        s.nodes["p-large-2"] = logic.NodeView("large-2", node("large-2", reported=NOW + 15 * 60))
        s.now = NOW + 17 * 60
        a = logic.plan_step(s)
        self.assertEqual(a.kind, "wait")
        self.assertIn("baking", a.reason)

    def test_without_group_canaries_every_host_soaks(self):
        refs = {**{h: OLD for h in PROD}, "p-small-1": TARGET, "p-large-1": TARGET}
        nodes = {**nodes_on(OLD), "p-small-1": node("small-1"), "p-large-1": node("large-1")}
        hosts = {"p-small-1": moved(at=NOW - 90000, settled=NOW - 80000), "p-large-1": moved(at=NOW - 2000, settled=NOW - 600)}
        a = logic.plan_step(snapshot(hosts=hosts, refs=refs, nodes=nodes))
        self.assertIn("soaking", a.reason)

    def test_defers_a_host_a_pdb_would_block(self):
        pods = [pod("geth-0", "small-1", labels={"app": "geth"})]
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "reboot"}, pods=pods, pdbs=[pdb("geth", "mainnet", {"matchLabels": {"app": "geth"}}, 0)])
        self.assertEqual(logic.plan_step(s).kind, "defer")

    def test_a_switch_ignores_pdbs(self):
        pods = [pod("geth-0", "small-1", labels={"app": "geth"})]
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, pods=pods, pdbs=[pdb("geth", "mainnet", {"matchLabels": {"app": "geth"}}, 0)])
        self.assertEqual(logic.plan_step(s).kind, "advance")

    def test_a_host_not_ready_now_is_deferred(self):
        nodes = nodes_on(OLD, **{"small-1": dict(readiness="pending")})
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, nodes=nodes)
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.host), ("defer", "p-small-1"))

    def test_the_server_is_classified_before_anything_else(self):
        s = snapshot(classes={})
        self.assertEqual((logic.plan_step(s).kind, logic.plan_step(s).host), ("need", "p-server"))

    def test_k3s_minor_starts_on_the_server(self):
        a = logic.plan_step(snapshot(classes={"p-server": "k3s-minor"}))
        self.assertEqual((a.kind, a.host, a.reason), ("advance", "p-server", "k3s-minor"))

    def test_a_mixed_k3s_minor_halts(self):
        s = snapshot(classes={"p-server": "k3s-minor"}, mixed={"p-server": ["kernel"]})
        self.assertEqual(logic.plan_step(s).kind, "halt")

    def test_the_hold_waits(self):
        self.assertEqual(logic.plan_step(snapshot(held=True)).kind, "wait")

    def test_a_testing_branch_halts(self):
        self.assertEqual(logic.plan_step(snapshot(testing=["testing-p-small-1"])).kind, "halt")

    def test_an_unchanged_system_is_skipped(self):
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "none"})
        self.assertEqual(logic.plan_step(s).kind, "skip")

    def test_a_recorded_move_that_did_not_push_is_pushed(self):
        s = snapshot(hosts={"p-small-1": moved()})
        self.assertEqual((logic.plan_step(s).kind, logic.plan_step(s).host), ("push", "p-small-1"))

    def test_halted_stays_halted(self):
        self.assertEqual(logic.plan_step(snapshot(state={"halted": {"reason": "x", "host": "p-small-1"}})).kind, "halt")

    def test_converges_when_every_host_runs_the_target(self):
        refs = {h: TARGET for h in PROD}
        nodes = {h: node(PLAN["hosts"][h]["node"]) for h in PROD}
        hosts = {h: moved(settled=NOW - 3600 * 30) for h in PROD}
        self.assertEqual(logic.plan_step(snapshot(refs=refs, nodes=nodes, hosts=hosts)).kind, "converge")

    def test_the_revert_lane_skips_readiness_and_regressions_but_keeps_pdbs(self):
        nodes = nodes_on(OLD, **{"small-1": dict(readiness="failed", ready=False)})
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, nodes=nodes, lane={"p-small-1"}, statefulsets=[sts("geth", ready=0)])
        self.assertEqual(logic.plan_step(s).kind, "advance")
        pods = [pod("geth-0", "small-1", labels={"app": "geth"})]
        s = snapshot(
            classes={"p-server": "reboot", "p-small-1": "reboot"},
            nodes=nodes,
            lane={"p-small-1"},
            pods=pods,
            pdbs=[pdb("g", "mainnet", {"matchLabels": {"app": "geth"}}, 0)],
        )
        self.assertEqual(logic.plan_step(s).kind, "defer")

    def test_a_regression_waits_then_halts(self):
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, statefulsets=[sts("geth", ready=0)])
        a = logic.plan_step(s)
        self.assertEqual((a.kind, a.data["regressionSince"]), ("wait", NOW))
        s = snapshot(classes={"p-server": "reboot", "p-small-1": "switch"}, statefulsets=[sts("geth", ready=0)], state={"regressionSince": NOW - 31 * 60})
        self.assertEqual(logic.plan_step(s).kind, "halt")

    def test_a_firing_alert_waits(self):
        plan = {**PLAN, "alerts": True}
        s = snapshot(plan=plan, classes={"p-server": "reboot", "p-small-1": "switch"})
        self.assertEqual(logic.plan_step(s).data, {"need": "alerts"})
        s.alerts = {"p-small-1": ["DiskFull"]}
        self.assertEqual(logic.plan_step(s).kind, "wait")

    def test_a_reboot_outside_the_promotion_window_waits(self):
        plan = {**PLAN, "windows": {"production": {"days": [1, 2, 3, 4, 5], "start": 0, "end": 8 * 60, "fromClass": "reboot"}}}
        self.assertEqual(logic.plan_step(snapshot(plan=plan, classes={"p-server": "reboot", "p-small-1": "reboot"})).kind, "wait")
        self.assertEqual(logic.plan_step(snapshot(plan=plan, classes={"p-server": "reboot", "p-small-1": "switch"})).kind, "advance")


class GeneratedPlan(unittest.TestCase):
    """The plan nixos-modules' lib.rolloutPlan generates (the rollout-plan
    check passes its JSON in PLAN_JSON) has every key the promoter reads."""

    def setUp(self):
        path = os.environ.get("PLAN_JSON")
        if not path:
            self.skipTest("PLAN_JSON isn't set")
        with open(path) as f:
            self.plan = json.load(f)

    def test_the_promoter_can_step_through_it(self):
        plan = self.plan
        for env in plan["environmentOrder"]:
            hosts = [h for w in logic.waves_of(plan, env) for h in w["hosts"]]
            for cls in logic.class_names(plan)[1:]:
                logic.soak_minutes(plan, env, logic.waves_of(plan, env), hosts[0], cls, False)
                self.assertIn(cls, plan["promote"])
            for h in hosts:
                for state in ("deploy", "lock", "drain", "boot", "ready"):
                    logic.budget_minutes(plan, h, state)
            nodes = {h: logic.NodeView(f"n-{h}", node(f"n-{h}", revision=OLD)) for h in hosts}
            s = logic.Snapshot(
                env=env, plan=plan, target=TARGET, state={"target": TARGET, "hosts": {}}, now=NOW,
                refs={h: OLD for h in hosts}, nodes=nodes, cluster=logic.Cluster(nodes={}),
                classes={h: "reboot" for h in hosts}, provenance={h: "" for h in hosts}, alerts={},
            )  # fmt: skip
            a = logic.plan_step(s)
            self.assertEqual((a.kind, a.host), ("advance", logic.waves_of(plan, env)[0]["hosts"][0]))


if __name__ == "__main__":
    unittest.main()
