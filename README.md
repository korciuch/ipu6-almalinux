# Intel IPU6 Camera on AlmaLinux 10.1 (Meteor Lake)

> Fix for camera not working on Intel Meteor Lake laptops running AlmaLinux 10.1 / RHEL 10 / kernel 6.12.

**Platform:** Intel Meteor Lake · **Sensor:** OmniVision OVTI02C1 · **Status:** Working as of 2026-03-15

---

## Quick Start

```bash
git clone https://github.com/korciuch/ipu6-almalinux.git
sudo bash ipu6-almalinux/setup.sh
```

`setup.sh` clones the Intel driver and firmware repos, applies all three patches,
installs via DKMS, downloads missing VSC firmware, and rebuilds the initramfs.
Use `--dry-run` to preview all steps without making changes.

---

## What Breaks and Why

Three separate issues prevent the camera from working on AlmaLinux 10.1:

**1. DKMS module array gaps** ([patch 1](patches/0001-dkms-conf-fix-module-array-gaps.patch))
AlmaLinux does not ship `CONFIG_V4L2_CCI_I2C`, so the `ov05c10` sensor module is
conditionally skipped.  The original `dkms.conf` used static indices `[0]..[21]`;
skipping `ov05c10` created a gap that caused DKMS to silently drop all subsequent
modules.  The fix rewrites the array with a `$_idx` counter incremented after each entry.

**2. ov05c10 build failure** ([patch 2](patches/0002-makefile-guard-ov05c10-v4l2-cci.patch))
Even with the DKMS fix, the Makefile unconditionally set `CONFIG_ICAMERA_OV05C10=m`,
causing the build to fail because `cci.h` is unavailable.  The fix probes
`/boot/config-$(KERNELRELEASE)` at build time and only enables ov05c10 when
`CONFIG_V4L2_CCI_I2C` is present.

**3. MODULE_IMPORT_NS build error** ([patch 3](patches/0003-psys-module-import-ns-rhel-compat.patch))
AlmaLinux 10.1's 6.12 kernel includes the RHEL backport of the `MODULE_IMPORT_NS`
string-literal form introduced upstream in 6.13.  The upstream guard
`#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 13, 0)` incorrectly selects the old
macro form on this kernel.  Adding `&& !defined(RHEL_RELEASE_CODE)` to the guard
fixes the build.

---

## VSC Firmware Gap

> **This is the most common failure cause.**  Without the missing firmware, the
> camera is permanently stuck in deferred probe with no error message.

AlmaLinux's `linux-firmware` package (`linux-firmware-20260130-19.3.el10_1`) does
**not** include all required Intel VSC firmware files.  The `mei_vsc_hw` driver
loads firmware in three stages:

| Stage | File | AlmaLinux status |
|-------|------|-----------------|
| 1 | `intel/vsc/ivsc_fw.bin` | **MISSING** |
| 2 | `intel/vsc/ivsc_pkg_ovti02c1_0.bin` | Present |
| 3 | `intel/vsc/ivsc_skucfg_ovti02c1_0_1.bin` | **MISSING** |

If Stage 1 fails, `mei_vsc_hw` retries 3 times then **explicitly disables the
ACPI device** (`INTC10D0`).  This causes `ipu_bridge` to wait forever for the
IVSC CSI node — the IPU6 is stuck with no timeout and no error message.

`setup.sh` downloads both missing files automatically.  To install manually:

```bash
sudo mkdir -p /lib/firmware/intel/vsc

sudo curl -fsSL \
  "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/vsc/ivsc_fw.bin" \
  -o /lib/firmware/intel/vsc/ivsc_fw.bin

sudo curl -fsSL \
  "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/vsc/ivsc_skucfg_ovti02c1_0_1.bin" \
  -o /lib/firmware/intel/vsc/ivsc_skucfg_ovti02c1_0_1.bin

sudo dracut --force
```

> If your sensor is not OVTI02C1, run `sudo dmesg | grep ivsc` after a failed boot
> to see the exact filenames the driver is requesting.

---

## Manual Steps

If you prefer not to run the script:

1. **Clone repos**
   ```bash
   git clone https://github.com/intel/ipu6-drivers.git
   git clone https://github.com/intel/ipu6-camera-bins.git
   git clone https://github.com/korciuch/ipu6-almalinux.git
   ```

2. **Apply patches**
   ```bash
   cd ipu6-drivers
   git apply ../ipu6-almalinux/patches/0001-dkms-conf-fix-module-array-gaps.patch
   git apply ../ipu6-almalinux/patches/0002-makefile-guard-ov05c10-v4l2-cci.patch
   git apply ../ipu6-almalinux/patches/0003-psys-module-import-ns-rhel-compat.patch
   ```

3. **Build and install via DKMS**
   ```bash
   sudo mkdir -p /usr/src/ipu6-drivers-1.0
   sudo cp -r . /usr/src/ipu6-drivers-1.0/
   sudo dkms add ipu6-drivers/1.0
   sudo dkms build ipu6-drivers/1.0
   sudo dkms install ipu6-drivers/1.0
   ```

4. **Install IPU6 firmware**
   ```bash
   sudo mkdir -p /lib/firmware/intel/ipu
   sudo cp ../ipu6-camera-bins/firmware/ipu6epmtl_fw.bin \
       /lib/firmware/intel/ipu/ipu6epmtl_fw.bin
   ```

5. **Install missing VSC firmware** (see [VSC Firmware Gap](#vsc-firmware-gap) above)

6. **Rebuild initramfs and reboot**
   ```bash
   sudo dracut --force
   sudo reboot
   ```

---

## Hardware Architecture

```
intel-ipu6 (PCI 0000:00:05.0)
  └── ipu_bridge_init()
        └── waits for IVSC (INTC10CF:00 at \_SB_.PC00.SPFD.CVFD)
              └── mei_vsc_hw → INTC10D0:00 (SPI transport, \_SB_.PC00.SPFD)
                    └── loads ivsc_fw.bin  ← Stage 1 (missing from AlmaLinux)
                          └── mei_vsc → ivsc-csi / ivsc-ace (MEI UUID drivers)
                                └── ipu_bridge connects OVTI02C1 sensor
                                      └── intel-ipu6 loads ipu6epmtl_fw.bin
                                            └── /dev/video* nodes appear
```

Additional hardware on USB LJCA bridge (8086:0b63 at XHCI HS09):
- `INTC10D1:00` — LJCA GPIO chip (gpiochip)
- `INT3472:01` (DSC1) — discrete PMIC for OVTI02C1 (reset/power GPIOs)
- `INT3472:0c` (DSC0) — PMIC for a different sensor (harmless boot noise)

---

## Verification

After reboot:

```bash
# Full chain — should show VSC loaded, sensor found, IPU6 authenticated
sudo dmesg | grep -E "(intel_vsc|ivsc|ipu6|ipu_bridge|OVTI|ov02c10)" \
  | grep -v "bridge window"
```

Expected key lines:
```
intel_vsc intel_vsc: silicon stepping version is 0:2
pci 0000:00:05.0: Found supported sensor OVTI02C1:00
intel-ipu6 0000:00:05.0: CSE authenticate_run done
intel-ipu6 0000:00:05.0: IPU6-v4[xxxx] hardware version 6
```

```bash
# Camera devices should exist
ls /dev/video* /dev/media*
```

A working system shows `/dev/media0` and approximately **48 `/dev/video*` nodes** —
this is normal for IPU6's ISYS/PSYS topology, not a bug.

---

## Known Boot Noise

```
int3472-discrete INT3472:0c: cannot find GPIO chip INTC10D1:00, deferring
```

This message appears ~30 times during boot (t=6–7s).  It is `INT3472:0c` (DSC0),
the PMIC for a **different sensor**, racing against LJCA GPIO chip initialization.
It does not affect OVTI02C1 or the camera pipeline.  It is harmless.

---

## ACPI Quirk

The OVTI02C1 sensor (`Device LNK1` at `\_SB_.PC00.LNK1`) has a `_DEP` method that
gates on an `L1EN` variable.  At boot `L1EN = 0`, so `DSC1` (the OVTI02C1 PMIC,
`INT3472:01`) is never declared as a dependency in the ACPI graph.

In practice this does not block operation: `ipu_bridge` uses its own sensor lookup
rather than the ACPI dependency graph, so the camera works despite this ACPI bug.
The quirk is documented here for completeness.

---

## Compatibility Table

| Item | Version |
|------|---------|
| OS | AlmaLinux 10.1 |
| Kernel | 6.12.0-124.43.1.el10_1.x86_64 |
| ipu6-drivers | HEAD as of 2026-03-15 |
| ipu6-camera-bins | HEAD as of 2026-03-15 |
| linux-firmware | 20260130-19.3.el10_1 |
| Sensor | OmniVision OVTI02C1 (ov02c10 driver) |

RHEL 10 and derivatives using the same kernel should work identically.
Other sensors (e.g. OV8856, HM2170) should work once the VSC firmware is
present — open an issue if yours does not.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[camera-not-working issue template](.github/ISSUE_TEMPLATE/camera-not-working.yml).
