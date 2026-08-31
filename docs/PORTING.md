# WSL2/Linux porting notes

This document records the engineering work involved in porting `ICH_A12_plus_Ramdisk` from its original macOS/Darwin host assumptions to Windows 11 + WSL2 Linux.

It is a technical history of the port: upstream assumptions, compatibility work, failed approaches, measurements, verified behavior, and the current unresolved boot-stage issue.

## Upstream baseline

Upstream project:

- `Pa7r0n/ICH_A12_plus_Ramdisk`
- ICHA12A13 / `new_ramdisk`
- original author/contact: `@Official_I_C_H`

The upstream project is structured around Darwin tooling. Its environment points at `tools/darwin`, and the RestoreRamDisk workflow depends on macOS facilities including `hdiutil` and `diskutil`.

The WSL2 port preserves the upstream build and boot logic where practical and replaces host-specific dependencies rather than replacing the exploit or patchfinder stack.

## Development test platform

The current bring-up target is:

```text
Host:        Windows 11
Guest:       Kali Linux under WSL2
Device:      iPhone 11
Product:     iPhone12,1
Board:       n104ap
SoC:         Apple A13
CPID:        0x8030
Installed:   iOS 26.0.1
Build:       23A355
DFU exploit: usbliter8
```

Confirmed pwned DFU identity:

```text
CPID: 0x8030
BDID: 0x04
PWND: usbliter8
MODE: DFU
PRODUCT: iPhone12,1
MODEL: n104ap
NAME: iPhone 11
```

## Port architecture

```text
Windows 11
    │
    ├── usbipd-win
    │
    ▼
WSL2 / Kali
    │
    ├── custom WSL kernel
    │    ├── USB core
    │    ├── USB/IP core
    │    ├── vhci-hcd
    │    └── external linux-apfs-rw
    │
    ├── native Linux host tools
    ├── Python virtual environment
    ├── upstream ICH sources
    ├── WSL port orchestration
    └── generated bootchain
             │
             ▼
       Apple DFU / Recovery USB
```

Development paths used during bring-up:

```text
~/ICH_A12_plus_Ramdisk-wsl2
~/ich-wsl2-port.sh
~/ICH_A12_plus_Ramdisk-wsl2/.local
~/ICH_A12_plus_Ramdisk-wsl2/.wsl-vendor
~/ICH_A12_plus_Ramdisk-wsl2/tools/linux
```

These paths describe the development environment and are not part of the device boot protocol.

## Native Linux toolchain

The port currently verifies the following Linux-side tools:

```text
irecovery
pzb
img4
gtar
trustcache
jq
usbliter8ctl
usbliter8_boot
iproxy
sshpass
ibootim
mkapfs
ipsw
```

Python dependencies are isolated in a project-local virtual environment. The upstream Python requirements include:

```text
pyimg4>=0.8
capstone>=5.0
Pillow>=10.0
```

The Linux `usbliter8ctl` wrapper also launches its Python implementation through that virtual environment.

## Native-build compatibility work

### lzfse / modern CMake

The bundled `lzfse` metadata declares:

```text
cmake_minimum_required(VERSION 2.8.6)
```

Modern CMake rejects that policy level by default. The Linux build supplies:

```text
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

`img4lib` also expects the static archive at:

```text
lzfse/build/bin/liblzfse.a
```

The WSL2 build therefore configures `lzfse` as a static build and explicitly directs archive, library, and runtime outputs into the expected layout.

### ibootim

`realnp/ibootim` uses the BSD/macOS `EFTYPE` errno value. glibc does not define `EFTYPE`, so the Linux build applies a local compatibility substitution before compilation.

No bootchain logic is changed by this compatibility patch.

## APFS support inside WSL2

The upstream project modifies Apple's RestoreRamDisk with macOS-native APFS tooling. WSL2 does not provide an equivalent writable APFS stack by default.

The port uses `linux-apfs-rw` for host-side modification of disposable RestoreRamDisk build images.

The development kernel currently in use is:

```text
6.18.33.2-microsoft-standard-WSL2+
```

A matching `linux-apfs-rw` module was built against that kernel and loaded successfully.

The initial bring-up required a full matching WSL kernel build because the running kernel did not expose enough prepared build state for the external APFS module. That full build became part of the development history, not a fundamental property of the ramdisk format.

## USB/IP with the custom WSL kernel

Switching away from Microsoft's stock WSL kernel exposed a second dependency: `usbipd-win` still requires the guest USB/IP/VHCI stack.

The working development module set included:

```text
usb-common.ko
usbcore.ko
usbip-core.ko
vhci-hcd.ko
```

The dependency failures appeared incrementally:

- `usbip-core` initially lacked `usb_speed_string`; loading/installing `usb-common` resolved it.
- `vhci-hcd` then lacked USB HCD/core symbols; loading/installing `usbcore` resolved those symbols.

With those pieces installed for the custom kernel, `usbipd attach --wsl` resumed working.

## Windows → WSL Apple USB passthrough

Apple USB identities observed during bring-up:

```text
05ac:1227  Apple Mobile Device (DFU Mode)
05ac:1281  Apple Mobile Device (Recovery Mode)
```

The DFU → Recovery transition changes the USB identity and can cause Windows to detach the device from WSL. The repository includes `windows/attach-apple-usb.ps1` to detect either identity, bind the BUSID when required, and attach it to WSL.

The WSL-side orchestration also recognizes both DFU and Recovery identities.

## Linux USB permissions

Initial USB passthrough worked only when `irecovery` was run as root.

A udev rule for Apple's vendor ID (`05ac`) and membership in the appropriate USB-access group removed that requirement. After the rule was applied and udev was retriggered, `irecovery -q` worked as the normal WSL user.

## RestoreRamDisk reconstruction failure

The first Linux implementation recreated the RestoreRamDisk in a newly formatted APFS image:

```text
stock Apple APFS image
        ↓
mount read-only
        ↓
create new APFS image
        ↓
copy logical contents
        ↓
inject SSH payload
```

That approach failed because the stock Apple APFS image is much smaller than the logical size of the mounted files.

Measurements from the iOS 26.0.1 build:

```text
Stock image bytes:        197132288
Logical file bytes:       769927773
Allocated logical bytes:  770205696
SSH archive bytes:         11701808
SSH unpacked bytes:        38625718
```

The stock image is approximately 188 MiB while the mounted logical contents are approximately 734 MiB.

A recreated image near the ramdisk size ceiling ran out of space. A 1 GiB reconstruction succeeded at the filesystem-copy stage but produced a ramdisk far beyond the bootchain's accepted size.

This established that APFS read/write itself was functional while also showing that full filesystem reconstruction was not viable for this boot path.

## RestoreRamDisk direct injection

The original RestoreRamDisk contained approximately:

```text
Image size: 197132288 bytes
Used:       ~160 MiB
Available:  ~29 MiB
```

The unmodified SSH payload required approximately 38.6 MiB unpacked, so direct injection also failed initially.

The working host-side method preserves Apple's original APFS image and modifies that image directly:

```text
stock Apple RestoreRamDisk
        ↓
working copy
        ↓
mount existing APFS image read/write
        ↓
inject slimmed SSH payload
        ↓
unmount
        ↓
wrap original-size image into bootchain
```

This retains the compact on-disk representation already present in Apple's image.

## SSH payload slimming

The largest removable payload components identified during bring-up included:

```text
~7.0 MiB  usr/share/misc/magic.mgc
~2.3 MiB  usr/share/locale
~196 KiB  usr/share/nano
          unused terminfo entries
```

The slim payload removes those nonessential rescue-environment resources while retaining the terminal classes required by the ramdisk environment.

Measured result:

```text
Slim unpacked payload: ~29 MiB
Before injection:      ~29 MiB free
After injection:       ~4.6 MiB free
Final APFS image:      ~188 MiB
Injection result:      SUCCESS
```

The injection implementation keeps a backup of the working image and restores it when injection fails.

## Bootchain build status

The iOS 26.0.1 / 23A355 build reached a clean host-side preflight with:

```text
product=iPhone12,1
model=n104ap
cpid=0x8030
chip=A13
version=26.0.1
build=23A355
ibss=0
sptm=0
txm=0
kernel=patched
kpf_set=ios18
with_fw=1
packaging=img4-with-im4m
trustcache=restore-append
```

`ios18` is the kernel-patch family selected by the upstream project for this firmware generation; it is not the firmware version.

Host-side validation passed for the generated DeviceTree, ramdisk, trustcache, kernelcache, iBoot boot arguments, board checks, and patched-kernel mode.

## usbliter8ctl wrapper failure

The first WSL boot attempt exposed a Linux wrapper integration bug.

`tools/linux/usbliter8ctl` is a Bash wrapper around the upstream Python implementation:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
exec /path/to/.venv/bin/python /path/to/usbliter8ctl "$@"
```

The generated `boot.sh` initially invoked that wrapper through Python:

```bash
python3 "$USBLITER8CTL" boot "$image"
```

Python attempted to parse the Bash wrapper and failed on:

```text
set -Eeuo pipefail
```

The same boot path also masked the child-process failure and continued into the Recovery wait loop.

The WSL patch now executes the wrapper directly and propagates its exit status.

After that correction the host reported:

```text
Loading iBEC (direct, no iBSS)...
usbliter8ctl boot iBoot.patched.bin
sent - 0x2545a0
```

and the device transitioned from pwned DFU into patched iBoot Recovery.

## First complete WSL2 host-side bootchain delivery

The corrected host path successfully performed:

```text
pwned DFU
  ↓
patched iBoot upload
  ↓
DFU → Recovery re-enumeration
  ↓
Recovery command channel
  ↓
signed logo / setpicture
  ↓
RestoreSEP
  ↓
PMP
  ↓
AOP
  ↓
ANE
  ↓
AVE
  ↓
ISP
  ↓
GFX
  ↓
SIO
  ↓
DeviceTree
  ↓
trustcache
  ↓
ramdisk
  ↓
kernelcache
  ↓
setenvnp boot-args
  ↓
bootx
```

Every host-side upload completed successfully.

## Current blocker: direct-iBEC `bootx`

The current A13 test reaches `bootx` but does not enter XNU. The display remains black and the device continues to enumerate as:

```text
05ac:1281 Apple Mobile Device [Recovery Mode]
MODE: Recovery
```

A direct `irecovery -c bootx` retry returns exit code 0 and leaves the device in Recovery.

This result confirms the following portions of the WSL2 path:

- device access through WSL2;
- USB/IP transport across the DFU/Recovery workflow;
- patched iBoot execution;
- Recovery command-channel operation;
- firmware and IMG4 payload transfer;
- ramdisk and kernelcache transfer;
- delivery of `bootx` to iBoot.

Upstream issue `Pa7r0n/ICH_A12_plus_Ramdisk#4` reports a closely matching direct-iBEC symptom on macOS with the same `iPhone12,1 / n104ap / A13` family: successful payload uploads followed by no transition after `bootx`.

The matching symptom does not establish a shared root cause, but it shows that the observed failure is not unique to WSL2.

## Alternate iBSS → iBEC validation

The next boot-path experiment uses the upstream alternate chain:

```text
pwned DFU
  ↓
usbliter8ctl boots patched iBSS
  ↓
iBEC IMG4 loaded via irecovery
  ↓
go
  ↓
Recovery
  ↓
firmware / DeviceTree / trustcache / ramdisk / kernel
  ↓
bootx
```

The generated chain for this experiment includes:

```text
iBSS.patched.bin
iBEC.patched.img4
use-ibss
```

and records `ibss=1` / `use-ibss=1` in chain metadata.

Logo/display handling is excluded from the first alternate-path comparison so the boot-stage change remains the only intentional variable.

## Recovery timeout behavior

During testing, a device left in iBoot Recovery eventually exited Recovery and booted the installed operating system without an explicit host reset.

That behavior is consistent with an iBoot autoboot timeout and is tracked separately from the current `bootx` handoff failure.

## Release architecture status

The development environment currently contains both reproducible code and machine-specific build state. The repository is being converted from that development state into a deterministic installer and release layout.

The release automation covers these components:

```text
upstream ICH revision pinning
project-local Python environment
pinned/native Linux tool sources
Linux host-tool builds
Apple udev configuration
Windows usbipd detection/attachment
matching WSL kernel and module support
writable APFS verification
USB/IP guest verification
DFU / Recovery device detection
pwned-DFU verification
bootchain construction
preflight validation
DFU → Recovery re-enumeration handling
iproxy / SSH verification after ramdisk boot
```

Long kernel builds are treated as build jobs with persistent logs rather than as interactive orchestration steps.

## Release layout

Current release-oriented files and planned artifacts are organized around:

```text
ich-wsl2-port.sh
windows/attach-apple-usb.ps1
udev configuration
pinned dependency metadata
checksums
WSL kernel build recipe or release artifact
matching kernel modules where required
native Linux tool wrappers/build logic
README.md
docs/PORTING.md
NOTICE
THIRD_PARTY_NOTICES.md
```

Third-party components remain under their upstream licenses and copyright terms.

## Attribution

Project attribution is intentionally explicit:

```text
Original project by @Official_I_C_H
WSL2/Linux port by @SpaceDudem
```

The upstream MIT notice and third-party credits remain intact.

## Current completion boundary

The WSL2 host port is verified through delivery of `bootx`.

The current milestone is complete only when the same environment also demonstrates:

```text
pwned DFU detection
valid bootchain generation
patched iBoot/iBEC transition
XNU boot into the modified RestoreRamDisk
ramdisk USB enumeration
iproxy connectivity
root SSH login
mount_ich execution
clean rebuild from documented repository state
```

Until the XNU/ramdisk transition is demonstrated, the repository remains an active WSL2 port and bring-up tree rather than a finished SSH-ramdisk release.
