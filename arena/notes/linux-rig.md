# Offline rig on a Mac

Moved: the rig is now scripted. See `docs/dev-on-mac.md` (`rig/run.sh`, `rig/Dockerfile`).

The hand-run emulated x86_64 rig this note described (2026-10-30, image `awl-linux:dev`) is
`rig/run.sh all --amd64`. Its baseline at 8d7c9ae, for history: unit 69/70 (the pidfd "background job
holds the pipe" test fails under emulation), e2e 50/51 with AWL_SANDBOX=off, size 356,480 B.
