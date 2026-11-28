# AGENTS.md: nixos-modules

Shared NixOS modules and host-repo workflows. **This repository is public.**
Its code, comments, tests, branch names, commit messages, and issue and pull
request titles, bodies, reviews and comments can be read by anyone, and they
stay readable after an edit or a force-push: GitHub keeps old commits and old
revisions of a body or comment.

## Rules

1. **Nothing private, ever.** No host, cluster or fleet names, IP addresses,
   drive serials, MACs or other hardware identifiers, keys, tokens or other
   secrets, internal URLs, or names of private repositories or of their
   options, scripts and files. Examples and test data are made up: hosts
   under `example.org`, and addresses from the documentation ranges
   (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`, or
   a wider prefix around one). A test that needs a private or special-purpose
   address takes one from the private, CGNAT, loopback, link-local or
   benchmarking ranges, made up rather than copied from a real network.
2. **Describe a change from the module's point of view:** what it does, why
   that is right for any host that uses it, and how it was tested. The
   reasons one fleet needs it, and that fleet's numbers, stay in the fleet's
   own repository and pull request.
3. **No agent trailers** (the thread ID an agent's `git commit` can append)
   or links to agent threads, in commits, pull requests or comments.
4. **Pull requests only.** `master` takes a change through a pull request
   whose `check` is green; never push or force-push `master`.
5. **Run the leak check before every push, and before posting or editing a
   title, body or comment:** read the diff (`git diff origin/master...HEAD`),
   the commit messages (`git log origin/master..HEAD`) and the text for
   anything rule 1 lists, and run the check your fleet repository keeps for
   its own names over them (that list can't live here). Anything it finds
   blocks the push or the post.
6. **If something private gets out anyway,** tell the maintainers first:
   editing or force-pushing it away doesn't remove it. Rotate a secret at
   once, delete the old revision of an edited body or comment from its edit
   history, and leave purging old commits and pull request diffs to GitHub
   Support.
