# Test build for CoreELEC/common_drivers#42

Branch `ci-test-build` of the fork carries only this CI. It rebuilds the
Amlogic-no kernel of an official CoreELEC nightly from the exact CoreELEC
revision that nightly reports as its BUILD_ID, twice: unmodified, and with
`common_drivers` swapped to the PR head (base + one patch). It checks each
rebuilt kernel's `Module.symvers` against the modules the official SYSTEM
ships (CRC for CRC), then publishes, as a GitHub release, an update tar that is
the official nightly with only `target/KERNEL` and `target/KERNEL.md5` replaced.

- `ci/build-test-kernel.sh`: the build, comparison and tar assembly
- `ci/modcompare.py`: reads `__versions`, `vermagic`, `srcversion` out of `.ko` ELF files
- `ci/split_bootimg.py`: splits the Android boot image CoreELEC ships as KERNEL
- `.github/workflows/test-kernel-build.yml`: runs it on `ubuntu-24.04`

The fix under test lives on branch `fix-hpd-suspend-state-leak`; nothing on
this branch touches kernel source.
