# Patches

Three patches are required to build `intel/ipu6-drivers` on AlmaLinux 10.1 / RHEL 10 / kernel 6.12.

## Upstream reference

These patches apply against `intel/ipu6-drivers` at commit `HEAD` as of 2026-03-15.
Check `git log --oneline -1` in your clone to confirm you are on a compatible base.

## Patches

| File | What it fixes |
|------|---------------|
| `0001-dkms-conf-fix-module-array-gaps.patch` | Replaces static `[0]`..[21]` indices with a `$_idx` counter so the module array has no gaps when `ov05c10` is conditionally skipped |
| `0002-makefile-guard-ov05c10-v4l2-cci.patch` | Guards `CONFIG_ICAMERA_OV05C10=m` behind a `HAS_V4L2_CCI` probe; prevents build failure when `cci.h` is absent |
| `0003-psys-module-import-ns-rhel-compat.patch` | Adds `&& !defined(RHEL_RELEASE_CODE)` to the `< 6.13.0` guard so RHEL kernels use the string-literal `MODULE_IMPORT_NS("DMA_BUF")` form |

## How to apply

```bash
cd ipu6-drivers

# Option A — git apply (preferred, applies cleanly or errors out)
git apply ../ipu6-almalinux/patches/0001-dkms-conf-fix-module-array-gaps.patch
git apply ../ipu6-almalinux/patches/0002-makefile-guard-ov05c10-v4l2-cci.patch
git apply ../ipu6-almalinux/patches/0003-psys-module-import-ns-rhel-compat.patch

# Option B — patch(1)
patch -p1 < ../ipu6-almalinux/patches/0001-dkms-conf-fix-module-array-gaps.patch
patch -p1 < ../ipu6-almalinux/patches/0002-makefile-guard-ov05c10-v4l2-cci.patch
patch -p1 < ../ipu6-almalinux/patches/0003-psys-module-import-ns-rhel-compat.patch
```

## Why not upstream PRs?

These fixes are distro-specific (RHEL kernel config / RHEL macro definitions).
They are not appropriate for upstream `intel/ipu6-drivers` which targets
vanilla kernels.  They are maintained here for AlmaLinux / RHEL users.
