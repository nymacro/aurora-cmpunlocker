# Aurora nvidia-open + cmpunlocker

An unofficial [Aurora](https://github.com/ublue-os/aurora) **nvidia-open** bootc
variant that rebuilds the NVIDIA open kernel modules with
[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) patches for the
NVIDIA CMP 170HX.

> This is a community project, not affiliated with NVIDIA, Universal Blue,
> Aurora, or the cmpunlocker maintainers. NVIDIA driver redistribution and
> cmpunlocker usage are subject to their upstream licenses and terms.

The result is an immutable, rebaseable Fedora/Aurora image containing:

- Aurora's KDE Plasma desktop and NVIDIA userspace/firmware from the pinned
  `ghcr.io/ublue-os/aurora-nvidia-open` base.
- cmpunlocker-patched `nvidia`, `nvidia-modeset`, `nvidia-uvm`,
  `nvidia-drm` and `nvidia-peermem` kernel modules.
- Runtime geometry selection for both CMP 170HX variants:
  - `10de:20c2` → 8 GB card, 64 GB unlock
  - `10de:2082` → 10 GB card, 40 GB unlock
  - mixed multi-GPU systems are handled by the `mixed` build profile.
- cmpunlocker's early-boot PCIe Gen2 retrain service.
- cmpunlocker's VFIO passthrough helpers (optional; see below).
- `cmpunlocker-verify` and `cmpunlocker-passthrough` commands.

> cmpunlocker restores features disabled in the CMP 170HX firmware/OTP
> configuration. It does **not** add display outputs. Read the upstream
> documentation and warnings before using it.

---

## Compatibility matrix

The NVIDIA kernel module must match the installed userspace driver exactly.
cmpunlocker v0.5 supports `610.43.02` through `615.71.09`; it does **not** yet
support the `620.70.06` driver in Aurora's current `stable`/`latest` images.

The default build is therefore pinned to a known-good Aurora stable image:

| Aurora base tag | NVIDIA | Kernel | cmpunlocker ref | Status |
|---|---|---|---|---|
| `stable-44.20260922.1` | 615.71.09 | `7.1.10-200.fc44.x86_64` | `v0.5` | **default** |
| `testing-45.20260924.4` | 615.71.09 | `7.2.7-300.fc45.x86_64` | `v0.5` | compatible alternative |
| `stable` (2026-11-17) | 620.70.06 | `7.2.11-300.fc45.x86_64` | any current ref | ❌ unsupported |

The build fails fast if the base image's NVIDIA version is not in
cmpunlocker's `driver/VERSION`, and also if it differs from
`EXPECTED_NVIDIA_VERSION` (default `615.71.09`). To move to a newer Aurora
base, first update `CMPUNLOCKER_REF`/`BASE_TAG` and set
`EXPECTED_NVIDIA_VERSION` to a combination that upstream supports.

The matching kernel headers come from Universal Blue's pinned akmods image
(`coreos-testing` for Aurora stable, `main` for testing/latest). The build
derives that tag from the base image's `ostree.linux` label in CI.

---

## Repository layout

This repository is laid out like the [Universal Blue image-template](https://github.com/ublue-os/image-template),
so the usual template workflow applies:

| Path | Purpose |
|---|---|
| `Containerfile` | Four-stage build: `ctx` (build assets), `akmods` (kernel headers), `builder` (patched modules), final bootc image. |
| `build_files/build.sh` | Main builder. Clones cmpunlocker, validates the driver version, builds/signs the modules and stages `/out`. |
| `build_files/install-modules.sh` | Final-stage install, `depmod`, `modinfo` guard, initramfs rebuild. |
| `build_files/sign-modules.sh`, `generate-mok.sh`, `service.sh` | MOK signing, key generation, bootc-friendly service helper. |
| `system_files/` | Files copied verbatim into the image; paths mirror the final filesystem (the image-template convention). |
| `image-template.env` | Image name/organisation and the pinned build inputs. |
| `Justfile` | `just build`, `check`, `lint`, `lint-image`, `verify`, `rechunk`, VM/disk recipes. |
| `.github/workflows/build.yml` | Build, lint, optional rechunk, push and cosign-sign. |
| `.github/workflows/build-disk.yml` | qcow2/ISO images via bootc-image-builder. |
| `disk_config/` | Filesystem size and Anaconda ISO kickstart. |
| `artifacthub-repo.yml` | Optional ArtifactHub repository metadata. |

---

## Repository setup (one-time)

1. Create a GitHub repository and push this tree. The workflow triggers on
   pushes to `main` **or** `master` and can also be started manually with
   `workflow_dispatch`.
2. Edit `image-template.env`: set `IMAGE_NAME`, `REPO_ORGANIZATION` and, if you
   build disk images, the image reference in `disk_config/iso.toml`. The pinned
   `BASE_TAG`/`AKMODS_TAG`/`CMPUNLOCKER_REF` values should only change after
   checking the compatibility matrix above.
3. Enable **Settings → Actions → General → Allow all actions and reusable
   workflows** (or allow the actions used here).
4. The workflow job already requests `packages: write` and `id-token: write`.
   If the repository is in an organization, make sure org policy allows GitHub
   Actions to create and write packages, and that Actions can use the
   `ublue-os/remove-unwanted-software`, `extractions/setup-just` and
   `sigstore/cosign-installer` actions.
5. The first successful run publishes to
   `ghcr.io/<owner>/<repo>:stable`. Set the GHCR package visibility to public
   if you want unauthenticated `bootc switch`, or log in to GHCR on the target
   before switching.
6. Signing is optional for the container and required for Secure Boot:
   - The image is cosign-signed keyless by default. To sign with a key instead,
     add a `SIGNING_SECRET` repository secret containing an unprotected
     `cosign.key` (as described by image-template).
   - Add `MOK_KEY`/`MOK_CERT` repository secrets if Secure Boot will stay
     enabled (see below). Without them the image builds with unsigned modules
     and Secure Boot must be disabled.

The workflow has no other required secrets; `GITHUB_TOKEN` is automatic.

---

## Install / rebase

Build and publish the image first (see below), or use an image published by
someone you trust.

```bash
sudo bootc switch ghcr.io/<owner>/aurora-cmpunlocker:stable
sudo systemctl reboot
```

A cold power cycle is recommended for the memory geometry to take effect:

```bash
sudo shutdown -h now
# power on
```

Verify:

```bash
nvidia-smi
sudo cmpunlocker-verify
systemctl status gen2.service
modinfo -n nvidia            # must contain /updates/cmpunlocker/
cat /usr/share/aurora-cmpunlocker/build-info
```

To go back to stock Aurora:

```bash
sudo bootc switch ghcr.io/ublue-os/aurora-nvidia-open:stable-44.20260922.1
sudo systemctl reboot
```

If you want a pristine `/etc` after rebasing to a non-cmpunlocker image, remove
`/etc/modprobe.d/zz-cmpunlocker-*.conf` and the `cmpunlocker-passthrough` /
`gen2` enablement symlinks under `/etc/systemd/system/*.wants`.

---

## Secure Boot

cmpunlocker's upstream modules are unsigned, so the default build is too.
**You must disable Secure Boot** unless you sign the modules with a MOK key and
enroll that key on the machine.

To sign:

1. Generate a key/cert pair:

   ```bash
   just generate-mok
   # or: ./build_files/generate-mok.sh keys
   ```

2. Add repository secrets (base64, no wrapping):

   ```text
   MOK_KEY=<base64 of keys/mok.key>
   MOK_CERT=<base64 of keys/mok.der>
   ```

   For local builds via `just build`, `MOK_KEY` and `MOK_CERT` are **file
   paths** instead; for GitHub Actions they are base64-encoded secrets.

3. Rebuild/publish the image. The build signs every staged `.ko` and installs
   the certificate at:

   ```text
   /usr/share/aurora-cmpunlocker/mok.der
   /etc/pki/akmods/certs/aurora-cmpunlocker.der
   ```

4. On each machine, enroll the certificate once:

   ```bash
   sudo mokutil --import /usr/share/aurora-cmpunlocker/mok.der
   sudo reboot
   # choose "Enroll MOK" in the blue MOK manager screen
   ```

The private key is only supplied to the build as a BuildKit secret and is not
stored in the image. If you rotate the key, re-enroll the new certificate.

---

## Build

Requirements: `podman`/`buildah` (BuildKit-style `RUN --mount` support),
network access, and enough disk for the Aurora and akmods images.

```bash
# Uses the pins in image-template.env; override with e.g. BASE_TAG=... just build.
just build

# or directly (the Containerfile builds a `ctx` stage for build_files/system_files):
podman build \
  --pull=newer \
  --platform linux/amd64 \
  --build-arg BASE_TAG=stable-44.20260922.1 \
  --build-arg AKMODS_TAG=coreos-testing-44-7.1.10-200.fc44.x86_64 \
  --build-arg CMPUNLOCKER_REF=v0.5 \
  --secret id=mok_key,src=/path/to/mok.key \
  --secret id=mok_cert,src=/path/to/mok.der \
  -t localhost/aurora-cmpunlocker:stable .
```

`just build [target_image] [tag]` tags the image (default
`aurora-cmpunlocker:stable`, from `image-template.env`). It always mounts both
MOK secrets; when `MOK_KEY`/`MOK_CERT` are unset it creates empty files and
builds unsigned modules. A plain `podman build` needs explicit `--secret` flags
(point them at empty files for an unsigned build).

Handy recipes: `just check` (Justfile syntax), `just lint` (shellcheck),
`just lint-image` (bootc container lint), `just verify` (module resolution and
`build-info` from inside the image), and `just generate-mok`.

Useful build args:

| Arg | Default | Meaning |
|---|---|---|
| `BASE_IMAGE` | `ghcr.io/ublue-os/aurora-nvidia-open` | Aurora nvidia-open repo |
| `BASE_TAG` | `stable-44.20260922.1` | Aurora image tag |
| `AKMODS_IMAGE` | `ghcr.io/ublue-os/akmods-nvidia-open` | Universal Blue akmods repo |
| `AKMODS_TAG` | `coreos-testing-44-7.1.10-200.fc44.x86_64` | exact kernel headers |
| `CMPUNLOCKER_REPO` | upstream GitHub URL | cmpunlocker clone URL |
| `CMPUNLOCKER_REF` | `v0.5` | tag, branch or commit |
| `CMPUNLOCKER_PROFILE` | `mixed` | `mixed`, `8gb` or `10gb` |
| `EXPECTED_NVIDIA_VERSION` | `615.71.09` | fail fast if the base driver differs |
| `ENABLE_GEN2_SERVICE` | `1` | install/enable early PCIe Gen2 retrain |
| `ENABLE_PASSTHROUGH` | `1` | install VFIO helpers and `cmp_no_bus_reset.ko` |
| `ENABLE_IOMMU_KARGS` | `1` | add `intel_iommu=on amd_iommu=on iommu=pt` via bootc kargs |
| `REBUILD_INITRAMFS` | `1` | rebuild the image initramfs |

The `just build` recipe exposes the four pinned inputs plus `SOURCE_URL` /
`SOURCE_REVISION`; pass any other build arg with a direct `podman build`.

Example: newer Fedora 45 testing base (same supported NVIDIA 615.71.09):

```bash
podman build \
  --build-arg BASE_TAG=testing-45.20260924.4 \
  --build-arg AKMODS_TAG=main-45-7.2.7-300.fc45.x86_64 \
  --build-arg CMPUNLOCKER_REF=v0.5 \
  -t localhost/aurora-cmpunlocker:testing-45 .
```

### CI

`.github/workflows/build.yml` calls the same `Justfile` recipes used locally:
`just check`, `just build`, `just lint-image`, an optional `just ostree-rechunk`
(disable with the `rechunk` workflow input), tag generation, push to GHCR on the
default branch/schedule/manual runs, and cosign signing of the digest (keyless,
or with `SIGNING_SECRET` if set). Pull requests build but never push.

### Disk images

`disk_config/disk.toml` and `disk_config/iso.toml` feed
`.github/workflows/build-disk.yml` (bootc-image-builder), producing qcow2 and
Anaconda ISO artifacts, optionally uploaded to S3 via the `S3_*` secrets. Update
the GHCR reference in `iso.toml` first. Locally, `just build-qcow2`,
`just build-iso` and `just run-vm` work the same way as in image-template.

### ArtifactHub

The `io.artifacthub.package.*` labels written by the `Justfile` build recipe and
`artifacthub-repo.yml` make the image indexable on
[artifacthub.io](https://artifacthub.io). Fill in `repositoryID` and the owner
details there once, then verify the repository on ArtifactHub. This is optional.

---

## How the image is built

1. **akmods stage**: pulls the Universal Blue akmods image matching the base
   kernel. It provides `kernel-devel-<kver>` and `kernel-devel-matched` RPMs.
2. **builder stage**: starts from the Aurora nvidia-open base, installs the exact
   headers, clones the pinned cmpunlocker ref, verifies that the base NVIDIA
   version is supported, and runs cmpunlocker's `driver/build.sh` with a fake
   `uname -r` pointing at the image kernel. The `mixed` profile keeps the 8 GB /
   10 GB geometry selection at runtime from the PCI device ID, so the image is
   not tied to a card that was present at build time.
3. The builder (`build_files/build.sh`) also compiles `cmp_no_bus_reset.ko`,
   optionally signs all modules, copies `system_files/` into the staged root,
   and stages runtime files under `/usr` (never `/usr/local`, which is a symlink
   to `/var/usrlocal` on bootc systems).
4. **final stage**: copies the staged files, installs modules into
   `/usr/lib/modules/<kver>/updates/cmpunlocker/`, runs `depmod`, verifies with
   `modinfo -k <kver> -n` that `nvidia*` resolves to the patched tree, rebuilds
   the initramfs with dracut, restores SELinux labels, and runs
   `bootc container lint --fatal-warnings`.

Files installed by the variant:

```text
/usr/lib/modules/<kver>/updates/cmpunlocker/nvidia*.ko
/usr/libexec/cmpunlocker/{gen2-hammer,passthrough-arm,gsp-restore,gsp-regs.conf}
/usr/lib/systemd/system/{gen2.service,cmpunlocker-passthrough.service}
/usr/lib/udev/rules.d/99-cmpunlocker-passthrough.rules
/etc/modprobe.d/zz-cmpunlocker-{gen2,vfio}.conf
/usr/lib/bootc/kargs.d/60-cmpunlocker-iommu.toml
/usr/share/cmpunlocker/                  upstream tools, README, LICENSE
/usr/share/aurora-cmpunlocker/build-info
/usr/bin/cmpunlocker-verify
/usr/bin/cmpunlocker-passthrough         (when passthrough is enabled)
```

The stock modules remain in `/usr/lib/modules/<kver>/extra/nvidia/` as a
fallback, but kmod's `updates/` directory has priority. `install-modules.sh`
fails the build if `modinfo` resolves to the stock tree.

---

## VFIO / VM passthrough

With `ENABLE_PASSTHROUGH=1` (default) the image contains:

- `cmp_no_bus_reset.ko`, which blocks PCI bus resets that would lose the unlock.
- `cmpunlocker-passthrough.service`, enabled at boot, which disables NVIDIA
  persistence mode, clears `reset_method`, and loads `cmp_no_bus_reset`.
- A udev rule that restores GSP boot registers when a card binds to `vfio-pci`.
- `cmpunlocker-passthrough`, a bootc-friendly copy of upstream's passthrough
  tool (`status`, `prepare`, `restore`).

IOMMU kernel arguments are added through
`/usr/lib/bootc/kargs.d/60-cmpunlocker-iommu.toml`. Enable VT-d/AMD-Vi in the
firmware; `iommu=pt` is used for passthrough. Set `ENABLE_IOMMU_KARGS=0` if you
manage kernel arguments yourself.

A guest should use a **stock** NVIDIA driver. Do not install cmpunlocker in the
guest.

See upstream `docs/INSTALLATION.md` and `tools/passthrough.sh` for details.

---

## Verification and troubleshooting

```bash
# Driver and module
nvidia-smi
modinfo -k "$(uname -r)" -n nvidia
modinfo -k "$(uname -r)" -F version nvidia
modinfo -k "$(uname -r)" -F signer nvidia

# Unlock
sudo cmpunlocker-verify
cat /usr/share/aurora-cmpunlocker/build-info
sudo dmesg | grep -E 'SEC2_DEBUG|CMP Gen2'

# PCIe Gen2 retrain
systemctl status gen2.service
sudo tail -n 50 /var/log/gen2.log
sudo /usr/share/cmpunlocker/tools/service.sh verify

# VFIO helpers
sudo cmpunlocker-passthrough status
```

Common problems:

- **`nvidia-smi` fails / module rejected**: Secure Boot is enabled and the
  modules are unsigned or the MOK key is not enrolled. Disable Secure Boot or
  enroll `/usr/share/aurora-cmpunlocker/mok.der`.
- **Build fails with “NVIDIA x.y.z is not supported”**: the base image has a
  newer driver than the selected cmpunlocker ref supports. Use a compatible
  `BASE_TAG`/`CMPUNLOCKER_REF` (see the matrix).
- **Build fails in the akmods stage or kernel-devel is missing**: the
  `AKMODS_TAG` does not match the base kernel. CI derives it automatically;
  for manual builds use the tag shown in the README matrix.
- **`modinfo` resolves to `extra/nvidia`**: the build should have failed. Check
  `depmod` output and `/usr/lib/modules/<kver>/modules.dep`.
- **Memory still shows stock size**: the card needs a cold power cycle, not a
  warm reboot, after installing patched modules.
- **PCIe stays at Gen1**: verify `gen2.service` ran and that `setpci` is
  available; check `/var/log/gen2.log`. The recovery boot option is
  `systemd.mask=gen2.service`.
- **VM loses the unlock after being killed**: use
  `sudo cmpunlocker-passthrough restore <pci-address>` (see upstream tooling).

---

## Credits and license

- [Aurora](https://github.com/ublue-os/aurora) / [Universal Blue](https://universal-blue.org/) —
  base image and build patterns. Apache-2.0.
- [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) by Amogh Munikote
  and contributors — patches and runtime tooling. GPL-2.0.
- NVIDIA open GPU kernel modules.

This repository's integration scripts are Apache-2.0. The cmpunlocker files
fetched and installed into the image remain GPL-2.0; their license is installed
at `/usr/share/cmpunlocker/LICENSE`.
