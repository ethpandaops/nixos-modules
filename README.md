# nixos-modules

NixOS modules for ethPandaOps servers: hardened SSH access for a fixed list
of people, sops secrets, pull-based deploys with a health check that rolls
back, reboots that tell people first, and monitoring, drift checks and log
shipping over a tailnet. Every module is tested in a NixOS VM in CI.

## Use

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-modules = {
      url = "github:ethpandaops/nixos-modules";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, nixos-modules, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixos-modules.nixosModules.default
        nixos-modules.nixosModules.static-network # bare metal with a static uplink
        nixos-modules.nixosModules.raid1-disks # two or more mirrored disks
        nixos-modules.nixosModules.reboot-interactive # a box people work on
        ./configuration.nix
      ];
    };
  };
}
```

`configuration.nix` sets values under `ethpandaops.*`. Read each module's
header comment and options for the details; the smallest complete example
is [tests/server.nix](tests/server.nix).

## Modules

| Module | What it does |
| --- | --- |
| `default` | `base`, `users`, `secrets`, `deploy`, `node-report` (off until a host sets `ethpandaops.kubernetes`), `reboot-detect`, `monitoring` and `banlist` (off until a host sets its mode): what every server gets |
| `base` | srvos's server profile plus key-only SSH for group `ssh-users`, passwordless sudo for `wheel`, Nix GC, persistent journal, kernel and network hardening, and the module lock (`ethpandaops.kernelModules`: collect what loads after boot, then lock) |
| `users` | `ethpandaops.users.<name>`: fixed UID, SSH keys, sudo, expiry, notify targets |
| `secrets` | sops-nix with the host's SSH ed25519 key as its age identity |
| `deploy` | comin pulls a deploy branch; after each deployment the health checks roll back to the last good system if the deploy broke the box. Checks are named and typed (`ethpandaops.checks.<name>`: a unit, an HTTP URL, this host's Kubernetes Node or pods, or a script), each health (decides rollbacks; built in: sshd, default route, firewall, DNS, git remote) or readiness (for a rollout to wait for; Kubernetes checks by default), and run at once; their results are in `/run/nixhost/checks/status.json` and `nixhost_check*`, refreshed every minute. `nixhost-boot-check` runs the health checks after a boot, without the rollback. Automatic rollbacks stop at the rollback breaker, which a kept rollback or a reverted trial trips (`nixhost-breaker status\|reset`), and never cross `ethpandaops.rollback.guard`. `ethpandaops.fingerprint` is what a rollout compares between commits to classify a change |
| `node-report` | annotates the host's own Kubernetes Node (`nixos.ethpandaops.io/*`) with its revision, boot revision, pending reboot, health, readiness, rollbacks, rollback breaker and this boot's trial, as the kubelet, for a staged rollout to read |
| `reboot-detect` | reports when the deployed system needs a reboot (kernel, initrd, modules, kernel parameters, systemd, or a system set to boot that isn't running yet), as `/run/reboot-required` for tools such as kured. With `ethpandaops.reboot.trial.enable`, reboots undo themselves: GRUB boots a new system once, as a trial, with the hardware watchdog and a deadline armed from the initrd on, and makes it the default only once `nixhost-boot-check` passes; a trial that hangs or fails comes back on the last confirmed system, and its reboot is held until a fix or `nixhost-boot retry`; while the rollback breaker is open a failing trial stays up instead (held). A system whose rollback guard differs boots without a trial, and so does one a `preArm` hook skips. A live switch that passes its health check and needs no reboot is confirmed too. Each boot's trial and check are in `/run/nixhost/boot/status.json` and `nixhost_boot_status`. Trials need /boot on a plain partition or md RAID1 metadata 1.0; elsewhere they're off and GRUB boots as usual |
| `reboot-interactive` | reboots in a nightly window when nobody is logged in, or at a deadline, with notices (a panda at each SSH login while one is pending, saying when, why and what it waits for) and `reboot-status`, `reboot-hold`, `reboot-at`, `reboot-now`; a new kernel series waits for an admin |
| `monitoring` | node-exporter and comin's exporter on the tailnet only; drift, SSH-login, kernel-protection and BPF metrics; optional journal shipping over OTLP (`monitoring.logs`) and a daily vulnix scan (`monitoring.vulnix`); host labels (`ethpandaops.host`) |
| `banlist` | `ethpandaops.banlist`: pulls a signed fleet ban list every 30 s (by default from the log shipping endpoint) and drops new connections from its sources, or only counts them in shadow mode; private, CGNAT, loopback and link-local sources (and an optional `allowFile`) are never blocked, and a list that's too wide, too large, stale, replayed or badly signed is refused |
| `static-network` | a static, MAC-matched uplink with systemd-networkd |
| `raid1-disks` | disko layout: mdadm RAID1 for the ESP and root on every listed disk, GRUB on each |

Every box-side check writes `nixhost_*` metrics through node-exporter's
textfile collector; alert rules live with the scraper, in platform's
`nix-hosts-monitoring`.

## Host repo CI

A host repo's workflows call the reusable ones here, pinned by commit:

| Workflow | What it does |
| --- | --- |
| `host-check.yaml` | the repo configures exactly the listed hosts, then `nix flake check` |
| `host-deploy.yaml` | builds a host at a commit whose check passed and fast-forwards the branch comin pulls |
| `host-update-nixpkgs.yaml` | moves nixpkgs to the newest channel release at least a day old |
| `host-refresh-keys.yaml` | refreshes `keys/<login>.keys` from GitHub for the people already listed, with a webhook notice |
| `host-bump-modules.yaml` | moves `nixos-modules` to the newest master commit whose check passed and that is old enough |
| `host-promote.yaml` | one run of a fleet's staged rollout for one environment (below) |
| `host-cve-scan.yaml` | scans the hosts' systems with vulnix; takes a channel release at once when it fixes a critical CVE, and proposes whitelisting the critical CVEs that have evidence they don't apply, for a person to check |
| `host-kernel-series.yaml` | proposes moving the pinned kernel series once a newer one is at x.y.4 and has been in the channel 3 weeks; with `auto-merge`, lands it once its check passed |
| `host-nixos-release.yaml` | proposes moving to the next NixOS release a month after it's out, for a person to land after reading the release notes |

```yaml
jobs:
  check:
    uses: ethpandaops/nixos-modules/.github/workflows/host-check.yaml@<commit>
    with:
      hosts: myhost
```

Each one runs its script from `ci/` at the `nixos-modules` commit the
caller's `flake.lock` pins (`nix run --inputs-from . nixos-modules#<script>`),
so the logic moves with the lock and the workflow pin only carries the job
wrapper; `GITHUB_TOKEN` can't edit workflow files, so pins move by hand. The
jobs run with the caller's token and permissions and get only the secrets the
caller passes. Each workflow's header has a caller example.

Deploying from master takes two paths, because the jobs that commit push
with `GITHUB_TOKEN`. That push starts no workflow, so they dispatch the
caller's `check.yaml`; and that check's completion fires no `workflow_run`
either (only `workflow_dispatch` and `repository_dispatch` start a run from
`GITHUB_TOKEN`). So:

- a commit pushed by a person deploys from a `deploy.yaml` on check's
  `workflow_run`, for `event == 'push'`;
- a dispatched check on master deploys itself: `check.yaml` has a second
  job that `needs: check` and calls `host-deploy.yaml` with `github.sha`.

Without the second job, daily updates pass check and never deploy.

The jobs that commit (update-nixpkgs, refresh-keys, bump-modules) take a
`mode`. `push`, the default, pushes to the branch, for a repo whose nodes
deploy any commit. `pr` opens or updates a pull request instead, for a repo
whose nodes deploy only commits signed by an allowed key: neither the bot's
commit nor GitHub's merge button carries one, so a person lands it as their
own signed commit (the pull request says how). host-deploy only
fast-forwards a branch to a commit that's already there, so it works either
way. The jobs that only propose (cve-scan's whitelist, kernel-series,
nixos-release) push the change to a branch, start its check and open a
pull request in either mode; with `pr` it says how to land it signed, and
kernel-series' `auto-merge` needs `push`. Where the repo's Actions settings
don't "Allow GitHub Actions to create and approve pull requests", these
jobs, and `mode: pr`, open an issue instead, with the branch, its check and
how to land it. Callers grant `issues: write` for that.

Every job lands on the branch through check; none writes the branch comin
pulls, so a fleet's staged rollout takes their commits like any other. The
update jobs' commits carry trailers a rollout reads: `Update: nixpkgs`,
`kernel-series`, `nixos-release` or `vulnix-whitelist`, and on cve-scan's
fast path `Urgency: security` with a `Fixes: CVE-…` per CVE. Urgency may
shorten a rollout's waits but never skips its canaries or gates. Land a
proposal with its message intact (`git cherry-pick` keeps it; a squash or
reword loses the trailers).

### Self-hosted runners

Every host workflow takes `runs-on`, `ubuntu-latest` unless the caller sets
it: a label, or JSON for a list of labels or a runner group, such as
`{"group": "my-hosts", "labels": ["my-hosts"]}`. With the group named, no
runner outside it takes the job, whatever its labels. This repo's own check
stays on GitHub-hosted runners.

A job holds the caller's token, and where a repository has no branch rules
(a private one on GitHub Free) a job with `contents: write` can push any
branch, the one comin pulls included: whoever controls the runner is root on
the hosts. So a host repo's self-hosted runners:

- run one job each and are gone: a fresh VM or pod per job (an ephemeral or
  just-in-time runner). A runner that stays keeps what a job left on it, a
  backdoor say, and reads the next job's token; install-nix-action writes
  the token into `/etc/nix/nix.conf`.
- sit in a runner group only the host repos may use, with public
  repositories not allowed: a public repo's pull request from a fork runs
  anyone's code on every runner the repo can use.
- never run a fork's pull request: keep "Allow forking" or "Run workflows
  from fork pull requests" off in the host repos' settings. An `if` in the
  caller can't do it, since a fork's pull request runs the workflow as the
  fork changed it.
- are x86_64-linux with git, plus systemd, curl, xz, python3 and
  passwordless sudo for install-nix-action's multi-user install with the
  build sandbox; on a runner that has Nix, it leaves that Nix alone. No job
  here needs KVM or Docker: the VM tests are this repo's own check.

Caching works as it does on GitHub-hosted runners: `actions/cache`
(cve-scan's NVD feeds) is GitHub's service, and each job's Nix store starts
empty and substitutes from cache.nixos.org. Give the runners no store that
outlives a job and no signing key for a binary cache the hosts trust: the
first lets one job reach the next, the second reaches the hosts.

The runners decide who can take over a job; what a job can do is its
token's. With `ethpandaops.deploy.allowedSignersFile` (the hosts deploy only
commits signed by a listed key, which no runner holds) and `mode: pr`, a job
that pushes the deploy branch still deploys nothing a person didn't sign.
Without it, write access, the runners' included, is root on the hosts.

## Staged rollouts

A fleet of Kubernetes nodes rolls a commit one node at a time instead of
moving one `deploy` branch for all: environment by environment (staging, then
production), canaries first, then groups in order, with `last` groups at the
end. Each host pulls its own `deploy/<host>` branch, and the promoter
(`rollout/promoter`, run by `host-promote.yaml`) is the only writer of those
branches and of `rollout-state`, where it keeps what it did. It reads each
host's state from the annotations `node-report` writes on its Node, so every
host sets `ethpandaops.kubernetes`. It never writes to a cluster: comin
applies the commit, and kured drains and reboots.

- **Where a host stands:** `ethpandaops.rollout.{group,canary,lead}` and
  `ethpandaops.host.environment`. The fleet's flake exports
  `rolloutPlan = nixos-modules.lib.rolloutPlan { hosts = self.nixosConfigurations; groups = [ … ]; last = [ … ]; }`
  ([lib/rollout-plan.nix](lib/rollout-plan.nix) lists every setting: change
  classes, soaks, promotion windows, kured's timings, the alert gate).
- **When a host moves:** the target is on the source branch and its check
  passed; when the hosts set `allowedSignersFile`, every commit up to it is
  signed by a listed key (without it, write access is the trust line). The
  host's readiness checks pass, no PodDisruptionBudget blocks its drain, its
  workloads are ready, nothing in the cluster is worse than when the roll
  started, and no Grafana alert for it fires.
- **When it's done:** it reports the target from its current boot (trusted
  only when the annotations' boot ID and kernel match what the kubelet
  reports), healthy, ready, no reboot pending or held, its trial boot
  confirmed; then a canary soaks for its change class. Every moved host stays
  watched until the environment converges.
- **What stops it:** among others, a rollback or trial revert, a host past its
  time budget in a state (deploy, kured's lock, drain, boot, readiness), a
  failed readiness check, a health check failing with the rollback breaker
  open, the cluster staying worse than when the roll started, a target that
  fails provenance or doesn't evaluate, and a `testing-*` branch. A person
  resumes, abandons the target, or lands a fix; `rollout/hold` on the source
  branch pauses it.
- **Between environments:** a later one takes a commit only after the one
  before converged on it and its promote soak passed for the worst class
  across both; a commit that changes it more than the one before saw waits
  for `approve`. Only a range of `Urgency:` commits with evidence (a
  nixpkgs-only security fix, or a revert that restores the last converged
  systems, signed where the hosts require it) shortens soaks or preempts a
  roll.

## Change

Pull requests only: `master` needs a green `check`, which runs every flake
check (the example server, each VM test, formatting and workflow lint) as
its own job. `nix flake check -L` runs the same locally on x86_64-linux with
KVM. A weekly workflow opens a pull request that updates the flake inputs.
Hosts pick up a change when their repo bumps its `nixos-modules` lock, which
`host-bump-modules` does on a schedule.
