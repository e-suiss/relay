# Release checklist

Copy into the release pull request or issue and tick every item before tagging.

- [ ] `just check` is green on the release commit; the nightly run of the same commit is green.
- [ ] No quarantined test remains (`mix relay.lint.tests --release`).
- [ ] Every policy default the released features depend on has a decided value; none is still waiting for measurement.
- [ ] Every engineering assumption number quoted in release notes has its benchmark code, raw output and run command in the repository, or carries "awaiting reproduction".
- [ ] Release notes use only the allowed claim language (`mix relay.lint.claims`).
- [ ] Dependency and toolchain versions in the release are at least seven days old; security fixes are listed.
- [ ] The image is signed, has an SBOM and a provenance attestation (`release` workflow).
- [ ] The Helm chart and the image carry the same version.
