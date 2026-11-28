# AGENTS.md: nixos-modules

Shared NixOS modules and host-repo workflows. **This repository is public.**
Its code, comments, tests, commit messages, and pull request titles, bodies
and comments can be read by anyone, and they stay readable after an edit or a
force-push: GitHub keeps old commits and old revisions of a body.

## Rules

1. **Nothing private, ever.** No host, cluster or fleet names, IP addresses,
   drive serials, MACs or other hardware identifiers, keys, tokens or other
   secrets, internal URLs, or names of private repositories or of their
   options, scripts and files. Examples and test data are made up: addresses
   from the documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`,
   `203.0.113.0/24`, `2001:db8::/32`), hosts under `example.org`.
2. **Describe a change from the module's point of view:** what it does, why
   that is right for any host that uses it, and how it was tested. The
   reasons one fleet needs it, and that fleet's numbers, stay in the fleet's
   own repository and pull request.
3. **No agent trailers** (such as `Amp-Thread-ID`) or links to agent threads
   in commits or pull requests.
4. **Pull requests only.** `master` takes a change through a pull request
   whose `check` is green; never push or force-push `master`.
5. **Run the leak check before every push and every title or body edit:**
   read the diff (`git diff origin/master...HEAD`), the commit messages
   (`git log origin/master..HEAD`) and the title and body for anything rule 1
   lists, and run the check your fleet repository keeps for its own names
   (that list can't live here). Anything it finds blocks the push.
