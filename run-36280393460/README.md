# CI logs — failed run 36280393460

This branch is a plain, orphan branch used only to publish CI logs so they
can be read without signing in to GitHub. It carries no source tree and is
not meant to be merged.

- Repository: avrignaud/common_drivers
- Workflow run: 36280393460
- Job: 108510985926 ("build")
- Failed step: `Build` — `bash ci/build-test-kernel.sh` (ran ~60 minutes before failing)

## Files

- `job-108510985926.log` — full Actions log for the `build` job (935 lines).
- `job-108510985926-tail400.txt` — last 400 lines of that job log.
- `build-unpatched.log` — the script's own build log, uploaded as workflow
  artifact `test-kernel-build` (artifact id 10919084634). This is much more
  detailed (55,461 lines) than the Actions job log.
- `build-unpatched-tail400.txt` — last 400 lines of `build-unpatched.log`.

## Root cause (from build-unpatched.log)

The build failed while fetching third-party sources: `gmp-6.3.0.tar.xz`
could not be downloaded from any of its sources (primary `gmplib.org` and
both mirrors returned HTTP 404), which aborted the package build with
`FATAL: scripts/build linux failed (unpatched) rc=1`.
