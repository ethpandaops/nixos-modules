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
| `default` | `base`, `users`, `secrets`, `deploy`, `reboot-detect`, `monitoring` and `banlist` (off until a host sets its mode): what every server gets |
| `base` | srvos's server profile plus key-only SSH for group `ssh-users`, passwordless sudo for `wheel`, Nix GC, persistent journal, kernel and network hardening, and the module lock (`ethpandaops.kernelModules`: collect what loads after boot, then lock) |
| `users` | `ethpandaops.users.<name>`: fixed UID, SSH keys, sudo, expiry, notify targets |
| `secrets` | sops-nix with the host's SSH ed25519 key as its age identity |
| `deploy` | comin pulls a deploy branch; after each deployment a health check (sshd, route, firewall, DNS, git remote) rolls back to the last good system if the deploy broke the box. `ethpandaops.fingerprint` is what a rollout compares between commits to classify a change |
| `reboot-detect` | reports when the deployed system needs a reboot (kernel, initrd, modules, kernel parameters, systemd, or a system set to boot that isn't running yet), as `/run/reboot-required` for tools such as kured |
| `reboot-interactive` | reboots in a nightly window when nobody is logged in, or at a deadline, with notices and `reboot-status`, `reboot-hold`, `reboot-at`, `reboot-now`; a new kernel series waits for an admin |
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

## Change

Pull requests only: `master` needs a green `check`, which runs every flake
check (the example server, each VM test, formatting and workflow lint) as
its own job. `nix flake check -L` runs the same locally on x86_64-linux with
KVM. A weekly workflow opens a pull request that updates the flake inputs.
Hosts pick up a change when their repo bumps its `nixos-modules` lock, which
`host-bump-modules` does on a schedule.
