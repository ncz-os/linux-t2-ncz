# linux-t2-ncz

Complete corresponding source for the NCZ-OS amd64 kernel
**`7.3.0-t2-ncz`, Debian package version `7.3.0-2`**, as shipped in
NCZ-OS Preview 4 (`linux-image-7.3.0-t2-ncz_7.3.0-2_amd64.deb` and its
`linux-headers` / `linux-libc-dev` companions, SHA256 hashes in
`SHIPPED-ARTIFACTS.sha256`).

The kernel is mainline Linux **v7.3** (`c03c1a14507dfaf8b856c2608f9ac216021fc222`)
plus the patch series in `patches/`, configured with
`config/kernel_config_7.3.0-t2-ncz`, built and packaged by `build.sh`.
Nothing else goes into the binary.

## Building

    KERNEL_VERSION=7.3 KERNEL_REF=v7.3 REQUIRE_PRERELEASE=0 PKGREL=2 ./build.sh

on an amd64 host (the build runs in a container; see the dependencies at the
top of `build.sh`). `config/` is copied into the tree as `.config`;
`patches/` is applied in filename order; `templates/` holds the Debian
packaging.

## Patch set

`patches/` carries the 24 patches the shipped build applied, in numeric order:
the T2 BCE audio/input stack (1001-1003), the i915/gmux/vga-switcheroo
display quirks (2008-2010), the Asahi trackpad + apple HID series (4001-4004),
the Touch Bar keyboard/display series (5001-5002), the amd/gpu PM fixes
(6001-6002), the i915 fbdev patch (7001), the APFS driver (8001-8002), the
ACPI/Bluetooth/PCI platform fixes (9001-9002, 9013), the integrity and
Bluetooth identification fixes (9101-9102) and the brcmfmac Wi-Fi series
(9503, 9504, 9506).

## Provenance

`PROVENANCE-7.3.0-2.txt` records the kernel ref, the source commit, the exact
sha256 of every patch the shipped build applied, and the one patch whose file
in this tree differs from the bytes that build used. Read it before claiming
byte-exact correspondence.
