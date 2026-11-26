# Where a host stands in its fleet's staged rollout. The fleet's flake turns
# every host's answer into the plan the promoter follows
# (nixos-modules.lib.rolloutPlan): environment (ethpandaops.host.environment),
# then group, with canaries first and a fleet's `last` groups at the end.
{ lib, ... }:
{
  options.ethpandaops.rollout = {
    group = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9][a-z0-9-]*";
      default = "default";
      example = "storage";
      description = "The group the host rolls with, such as a hardware pool or `server`. The plan orders groups.";
    };
    canary = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Roll in the environment's first wave, ahead of every group, and soak there.";
    };
    lead = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Go first within its group. With group canaries the first host of a group soaks like a canary, so mark the host a change should be proven on, such as one with persistent volumes.";
    };
  };
}
