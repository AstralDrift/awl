# Releasing awl

A release is a `vX.Y.Z` tag on a `main` commit that passed CI. The Release workflow
(`.github/workflows/release.yml`) refuses anything else.

## Checks

| Command | What it checks | Where it runs |
|---|---|---|
| `zig build lint` | `zig fmt`, the `== {}` and test-import rules, the Zig version matches in its four places, no arena/LOG.md promise older than two weeks, every src commit over main names a size/RSS/startup figure, shellcheck, ruff (pyflakes), actionlint | CI `lint` job; locally, `mise install` gives the pinned tools |
| `zig build test` | unit tests in Debug (overflow, bounds and `unreachable` checks on) | CI on x86_64 and aarch64 |
| `zig build check` | static binary, startup under 3 ms, peak RSS under 8 MB; reports size and idle RSS | CI, numbers in each run's summary |
| `zig build e2e`, `zig build sandbox` | end-to-end, TUI, embedder contract, sandbox escapes, against `tests/fake_sse.py` | CI (needs Linux and bubblewrap) |

Every push to `main` also uploads `awl-<commit>` (both binaries and `SHA256SUMS`) as a
workflow artifact, kept 14 days. A weekly scheduled run catches runner image changes.

## Cutting a release

1. In a PR, set `.version` in `build.zig.zon` to the new version (semver; before 1.0 a
   minor bump may break things). Merge it once CI is green.
2. Wait for CI on that `main` commit to finish green (`gh run list -b main -L 1`).
3. Tag that commit and push the tag:

       git checkout main && git pull --ff-only
       git tag -a v0.1.0 -m "awl v0.1.0"
       git push origin v0.1.0

4. The Release workflow checks the tag against `build.zig.zon`, checks the commit is on
   `main` and that `lint` and both `test` jobs passed on it, builds both binaries on two
   runners, and publishes only if all four builds are byte-identical. Release notes are
   GitHub's generated list of merged PRs, under the checksums.

If the gate fails because CI was still running, re-run the workflow from the Actions tab
once CI is green. A bad tag: delete the release and the tag, fix on `main`, and use the
next patch version; never move a published tag.

To check reproducibility without publishing, run the Release workflow by hand
(workflow_dispatch) on any branch.

## Changing the Zig version

Update all four: `mise.toml`, `build.zig.zon` (`minimum_zig_version`), `scripts/release.sh`
(`version=` and the four sha256 lines from https://ziglang.org/download/index.json) and the
path in `release.yml`. `zig build lint` fails until they agree.

## Repository settings

These live on GitHub, not in the repo:

- Ruleset for `main`: require a pull request, require the `lint`, `test (ubuntu-24.04)` and
  `test (ubuntu-24.04-arm)` checks, block force-pushes and deletion.
- Ruleset for tags `v*`: block deletion and updates, so a published tag cannot move.
