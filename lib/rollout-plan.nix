# lib.rolloutPlan: the plan a fleet's promoter follows (rollout/promoter),
# from what every host says about itself. In the fleet's flake:
#
#   rolloutPlan = nixos-modules.lib.rolloutPlan {
#     hosts = self.nixosConfigurations;
#     environments = [ "staging" "production" ];
#     groups = [ "small" "large" "server" ];
#     last = [ "precious" ];
#   };
#
# and `nix eval --json .#rolloutPlan` is what the promoter reads.
#
# Every host must be a Kubernetes node (ethpandaops.kubernetes.nodeName): the
# promoter reads what a host runs, and whether it's healthy and ready, from
# the annotations node-report writes on its Node.
#
# Order, outermost first: environment (ethpandaops.host.environment, in
# `environments` order; a later one takes only commits the one before
# converged on and soaked), then waves: the canaries (ethpandaops.rollout.
# canary, cheapest group first), each group in `groups` order (its `lead`
# host first), groups not listed, then the `last` groups, which are never
# canaries. One host moves at a time per environment.
#
# A change's class decides the soak. classify compares a host's fingerprint
# (ethpandaops.fingerprint) at the commit it runs and at the target: none when
# the revision-free system is the same, otherwise the most disruptive class
# whose `fields` differ (or whose `series` fields differ in major.minor). A
# class can name groups that go `first` and fields it must not be mixed with
# (`alone`). Soaks are minutes: per canary (and, with group canaries, per
# group's first host, then one bake at the group's end), the extra for a later
# environment's first canary, and the promote soak before the next
# environment may take a commit.
{ lib }:
{
  hosts,
  environments ? [
    "staging"
    "production"
  ],
  groups ? [ ],
  last ? [ ],
  groupCanaries ? true,
  classes ? [
    { name = "switch"; }
    {
      name = "reboot";
      fields = [
        "kernel"
        "initrd"
        "systemd"
        "kernelParams"
        "kernelModules"
        "inhibitors"
      ];
    }
    {
      name = "kernel-series";
      series = [ "kernelVersion" ];
    }
    {
      name = "release";
      fields = [ "nixosRelease" ];
    }
  ],
  soak ? { },
  canaryExtra ? { },
  promote ? { },
  urgent ? { },
  # env -> { days = [ 1 2 3 4 5 ]; start = "08:00"; end = "17:00"; fromClass = "reboot"; }, UTC, Monday is 1.
  windows ? { },
  # kured's flags, in minutes, for the lock and drain budgets.
  kured ? { },
  budgets ? { },
  # Wait while a Grafana-managed alert fires for a host or its fleet and environment.
  alerts ? false,
  sourceBranch ? "master",
  stateBranch ? "rollout-state",
  holdFile ? "rollout/hold",
  checkWorkflow ? "check.yaml",
  vulnixWhitelist ? null,
}:
let
  info = lib.mapAttrs (
    name: host:
    let
      c = host.config;
      readiness = lib.filter (check: check.enable && check.kind == "readiness") (
        lib.attrValues (c.ethpandaops.checks or { })
      );
      trial = c.ethpandaops.reboot.trial or { enable = false; };
    in
    {
      env = c.ethpandaops.host.environment;
      fleet = c.ethpandaops.host.fleet;
      inherit (c.ethpandaops.rollout) group canary lead;
      node = c.ethpandaops.kubernetes.nodeName;
      deployBranch = c.ethpandaops.deploy.branch;
      readinessMinutes = (lib.foldl' lib.max 0 (map (check: check.timeout) readiness) + 59) / 60;
      trialMinutes = if trial.enable then (trial.deadline + 59) / 60 else 0;
      signers =
        let
          f = c.ethpandaops.deploy.allowedSignersFile;
        in
        if f == null then null else builtins.readFile f;
    }
  ) hosts;

  groupIndex = g: lib.lists.findFirstIndex (x: x == g) (builtins.length groups) groups;
  byName = hs: lib.sort lib.lessThan (lib.attrNames hs);
  leadFirst =
    hs: lib.filter (h: hs.${h}.lead) (byName hs) ++ lib.filter (h: !hs.${h}.lead) (byName hs);

  wavesFor =
    env:
    let
      mine = lib.filterAttrs (_: h: h.env == env) info;
      inLast = h: lib.elem h.group last;
      early = lib.filterAttrs (_: h: !inLast h) mine;
      canaries = lib.filterAttrs (_: h: h.canary) early;
      rest = lib.filterAttrs (_: h: !h.canary) early;
      inGroup = g: lib.filterAttrs (_: h: h.group == g) rest;
      waves = [
        {
          name = "canary";
          hosts = map (x: x.name) (
            lib.sort (a: b: if a.i == b.i then a.name < b.name else a.i < b.i) (
              lib.mapAttrsToList (name: h: {
                inherit name;
                i = groupIndex h.group;
              }) canaries
            )
          );
        }
      ]
      ++ map (g: {
        name = g;
        hosts = leadFirst (inGroup g);
      }) groups
      ++ [
        {
          name = "other";
          hosts = leadFirst (lib.filterAttrs (_: h: !(lib.elem h.group groups)) rest);
        }
      ]
      ++ map (g: {
        name = g;
        hosts = leadFirst (lib.filterAttrs (_: h: h.group == g) mine);
        last = true;
      }) last;
    in
    lib.filter (w: w.hosts != [ ]) waves;

  defaults = {
    soak = {
      staging = {
        switch = 5;
        reboot = 15;
        kernel-series = 30;
        release = 30;
      };
      production = {
        switch = 5;
        reboot = 20;
        kernel-series = 60;
        release = 60;
      };
    };
    canaryExtra = {
      switch = 30;
      reboot = 240;
      kernel-series = 1440;
      release = 1440;
    };
    promote = {
      switch = 60;
      reboot = 360;
      kernel-series = 1440;
      release = 1440;
    };
  };
  soakFor = lib.genAttrs environments (
    env: (defaults.soak.${env} or defaults.soak.production) // (soak.${env} or { })
  );
  canaryExtra' = defaults.canaryExtra // canaryExtra;
  promote' = defaults.promote // promote;
  classNames = map (c: c.name) classes;

  kured' = {
    period = 5;
    lockTtl = 120;
    drainTimeout = 15;
  }
  // kured;
  trialMinutes = lib.foldl' lib.max 0 (lib.mapAttrsToList (_: h: h.trialMinutes) info);
  budgets' = {
    deploy = 20;
    lock = kured'.period + kured'.lockTtl;
    drain = kured'.period + kured'.drainTimeout;
    # Through a trial boot and, if it fails, the boot back.
    boot = if trialMinutes > 0 then trialMinutes + 15 else 20;
    readyMargin = 5;
    regression = 30;
    watchGrace = 10;
    waitNotice = 120;
  }
  // budgets;

  clock =
    t:
    let
      m = builtins.match "([0-9][0-9]):([0-9][0-9])" t;
    in
    lib.toIntBase10 (builtins.elemAt m 0) * 60 + lib.toIntBase10 (builtins.elemAt m 1);

  signers = lib.unique (lib.mapAttrsToList (_: h: h.signers) info);
  fleets = lib.unique (lib.mapAttrsToList (_: h: h.fleet) info);

  waves = lib.genAttrs environments wavesFor;
  inWaves = lib.concatMap (env: lib.concatMap (w: w.hosts) waves.${env}) environments;

  missing = lib.concatMap (env: lib.filter (c: !(soakFor.${env} ? ${c})) classNames) environments;
  windows' = lib.mapAttrs (_: w: {
    days =
      w.days or [
        1
        2
        3
        4
        5
      ];
    start = clock w.start;
    end = clock w.end;
    fromClass = w.fromClass or "reboot";
  }) windows;
in
assert lib.assertMsg (lib.all (h: h.node != null) (lib.attrValues info))
  "rolloutPlan: every host must set ethpandaops.kubernetes.nodeName; the promoter reads each host's state from its Node";
assert lib.assertMsg (lib.elem "reboot" classNames)
  "rolloutPlan: `classes` must have a reboot class; the drain gate and the promotion window start there";
assert lib.assertMsg (lib.all (w: lib.elem w.fromClass classNames) (
  lib.attrValues windows'
)) "rolloutPlan: a window's fromClass must be one of `classes`";
assert lib.assertMsg (lib.sort lib.lessThan inWaves == lib.sort lib.lessThan (lib.attrNames info))
  "rolloutPlan: every host must be in exactly one wave; check each host's environment is in `environments`";
assert lib.assertMsg (lib.all (h: !(h.canary && lib.elem h.group last)) (
  lib.attrValues info
)) "rolloutPlan: a host in a `last` group can't be a canary";
assert lib.assertMsg (missing == [ ]) "rolloutPlan: soak has no minutes for ${toString missing}";
assert lib.assertMsg (lib.all (
  c: canaryExtra' ? ${c} && promote' ? ${c}
) classNames) "rolloutPlan: canaryExtra and promote need minutes for every class";
assert lib.assertMsg (
  builtins.length signers <= 1
) "rolloutPlan: every host must deploy with the same allowedSignersFile";
assert lib.assertMsg (builtins.length fleets <= 1) "rolloutPlan: every host must be in one fleet";
{
  fleet = lib.head (fleets ++ [ "fleet" ]);
  environmentOrder = environments;
  environments = lib.mapAttrs (_: ws: { waves = ws; }) waves;
  hosts = lib.mapAttrs (
    _: h:
    removeAttrs h [
      "signers"
      "trialMinutes"
    ]
  ) info;
  inherit
    classes
    groupCanaries
    alerts
    sourceBranch
    stateBranch
    holdFile
    checkWorkflow
    vulnixWhitelist
    ;
  soak = soakFor;
  canaryExtra = canaryExtra';
  promote = promote';
  urgent = {
    soak = 10;
    promote = 60;
  }
  // urgent;
  budgets = budgets';
  kured = kured';
  windows = windows';
  allowedSigners = lib.head (signers ++ [ null ]);
}
