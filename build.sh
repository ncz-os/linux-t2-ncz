#!/bin/bash

set -eu -o pipefail

### Environment variable
export DEBIAN_FRONTEND=noninteractive

### Dependencies in docker
apt-get update
apt-get install -y lsb-release

# Every knob below can be overridden from the environment so one tree can
# produce the port build and its bisect variants without editing this file.
#   KERNEL_VERSION     label used for messages and the saved config name
#   KERNEL_REF         tag or branch to clone (default v${KERNEL_VERSION})
#   KERNEL_REPOSITORY  where to clone from; a file:// URL of a prepared local
#                      tree lets a variant carry reverts or sit on a
#                      mid-merge-window commit
#   PKGREL             package revision (default 2: the second build of
#                      7.3.0-rc7-t2-ncz, which added patch 2010; the first rc7
#                      build was <version>-1, so apt ordering selects -2)
#   T2_LOCALVERSION    full LOCALVERSION (default -t2-ncz: a fixed, host-independent
#                      name so the release is <kernel version>-t2-ncz, e.g.
#                      7.3.0-t2-ncz or 7.3.0-rc6-t2-ncz; the revision lives in the
#                      package version <version>-${PKGREL}, not in the release
#                      string)
#   REQUIRE_PRERELEASE 1 = refuse to build unless the kernel release carries
#                      an -rcN marker. The installed rEFInd hook classifies
#                      any *-t2-ncz* kernel WITHOUT -rcN as "stable" and makes
#                      the newest one the default boot entry, so a test variant
#                      must never lose that marker. The 7.3.0-final build has
#                      no -rcN, so build it with REQUIRE_PRERELEASE=0.
#   SKIP_PATCHES       space-separated patch basenames to leave out. Each must
#                      exist in patches/; every skip is logged and recorded in
#                      PROVENANCE. Used for merge-window bisect builds, where
#                      the Makefile still says 7.2.0 but VFS APIs are already
#                      7.3, so APFS (8001/8002) picks its pre-7.3 code path and
#                      cannot compile.
#   T2_WORKING_PATH    directory build.sh stages patches, templates and the
#                      kernel clone into (default /root/work). Point it at a
#                      disk-backed directory with ~30 GB free; a kernel build
#                      does not fit on a small tmpfs.
#   T2_ARTIFACTS_DIR   directory the .deb packages, the saved .config and
#                      PROVENANCE are written to (default /tmp/artifacts).
#                      Override to a disk-backed directory.
KERNEL_VERSION="${KERNEL_VERSION:-7.3}"
SKIP_PATCHES="${SKIP_PATCHES:-}"
KERNEL_REF="${KERNEL_REF:-v${KERNEL_VERSION}}"
PKGREL="${PKGREL:-2}"
REQUIRE_PRERELEASE="${REQUIRE_PRERELEASE:-0}"
DISTRO=$(lsb_release -i | cut -d ":" -f 2 | xargs)
CODENAME=$(lsb_release -c | cut -d ":" -f 2 | xargs)
T2_LOCALVERSION="${T2_LOCALVERSION:--t2-ncz}"

if [[ ${DISTRO} = Debian ]]
then
CONFIG=debian
else
CONFIG=ubuntu
fi

#KERNEL_REPOSITORY=git://kernel.ubuntu.com/virgin/linux-stable.git
KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
KERNEL_REPOSITORY_ALT="${KERNEL_REPOSITORY_ALT:-https://github.com/torvalds/linux.git}"

REPO_PATH=$(pwd)
WORKING_PATH="${T2_WORKING_PATH:-/root/work}"
ARTIFACTS_DIR="${T2_ARTIFACTS_DIR:-/tmp/artifacts}"
KERNEL_PATH="${WORKING_PATH}/linux-kernel"

### Debug commands
echo "Kernel version: ${KERNEL_VERSION}"
echo "Config distro: ${CONFIG}"
echo "Working path: ${WORKING_PATH}"
echo "Kernel repository: ${KERNEL_REPOSITORY}"
echo "Current path: ${REPO_PATH}"
echo "CPU threads: $(nproc --all)"
grep 'model name' /proc/cpuinfo | uniq

get_next_version () {
  echo $PKGREL
}

### Clean up
rm -rfv ./*.deb

mkdir -p "${WORKING_PATH}" && cd "${WORKING_PATH}"
cp -rf "${REPO_PATH}"/{patches,templates} "${WORKING_PATH}"
rm -rf "${KERNEL_PATH}"

### Dependencies
apt-get install -y build-essential fakeroot libncurses-dev bison flex libssl-dev libelf-dev \
  openssl dkms libudev-dev libpci-dev libiberty-dev autoconf wget xz-utils git \
  libcap-dev bc rsync cpio debhelper kernel-wedge curl gawk dwarves zstd python3 libdw-dev

### get Kernel and Drivers
if [[ ${KERNEL_REPOSITORY} = file://* ]]; then
  # A prepared local tree is authoritative: never fall back to the network,
  # which would silently build a different source than the one prepared.
  git clone --depth 1 --single-branch --branch "${KERNEL_REF}" \
    "${KERNEL_REPOSITORY}" "${KERNEL_PATH}"
else
  git clone --depth 1 --single-branch --branch "${KERNEL_REF}" \
    "${KERNEL_REPOSITORY}" "${KERNEL_PATH}" || \
  git clone --depth 1 --single-branch --branch "${KERNEL_REF}" \
    "${KERNEL_REPOSITORY_ALT}" "${KERNEL_PATH}"
fi

cd "${KERNEL_PATH}" || exit
SOURCE_COMMIT=$(git rev-parse HEAD)
echo "Kernel source: ${KERNEL_REF} = ${SOURCE_COMMIT}"

#### Patches are vendored in patches/ (run patch_driver.sh out of band to
#### refresh them from t2linux); nothing is fetched at build time.

#### Apply patches
cd "${KERNEL_PATH}" || exit

echo >&2 "===]> Info: Applying patches... "
[ ! -d "${WORKING_PATH}/patches" ] && {
  echo 'Patches directory not found!'
  exit 1
}

# Manifest gate: 9011 is the new SEP ANFE quirk (replaces the dropped 9010
# revert). The series carries exactly the SEP-quirk 9011 and NO 9010: Wunner's
# 79c168e2aa95 ("PCI/AER: Skip error recovery on false alarms") is already in
# the v7.3-rc7 base, and the 9010 revert would conflict with the Wunner
# false-alarm guard now in upstream aer.c. Drop 9011 and this gate once the
# base tree grows a per-device ANFE disable in pci_aer_init() (the cleaner
# fix the SEP-firmware behaviour is being worked towards upstream).
[[ -e "${REPO_PATH}/patches/9011-PCI-AER-skip-ANFE-unmask-on-Apple-T2-SEP.patch" ]] || {
  echo 'ERROR: 9011 (Apple T2 SEP ANFE quirk) is missing from patches/' >&2
  exit 1
}
if compgen -G "${REPO_PATH}/patches/9010-*.patch" >/dev/null || compgen -G "${REPO_PATH}/held/9010-*.patch" >/dev/null; then
  echo 'ERROR: 9010 (plain revert of eddba19b8b5f) is present; the rc7 release carries the SEP ANFE quirk (9011) + Wunner 79c168e2aa95 (already in rc7). Keep 9010 out of this series.' >&2
  exit 1
fi
# 2010 (added in package revision 2) must be in the series: it restores the upstream
# boot-GPU guard that 2009 dropped, scoped to non-T2 Apple (the T2 Macs keep
# the patch-2009 relaxation). Without it a Mac whose APP000B is present but
# whose gmux never registers (Macmini5,1) defers the sole GPU forever.
[[ -e "${REPO_PATH}/patches/2010-vga-switcheroo-keep-boot-gpu-guard-on-non-t2-apple.patch" ]] || {
  echo 'ERROR: 2010 (vga_switcheroo boot-GPU guard) is missing from patches/' >&2
  exit 1
}
grep -qF 'apple_t2_present' "${REPO_PATH}"/patches/2010-*.patch || {
  echo 'ERROR: 2010 does not carry the apple_t2_present() T2 scoping' >&2
  exit 1
}
# 9001 must still carry the local zalloc_cpumask_var fix.
grep -qF 'zalloc_cpumask_var' "${REPO_PATH}"/patches/9001-*.patch || {
  echo 'ERROR: 9001 does not carry the local zalloc_cpumask_var fix' >&2
  exit 1
}

for skip in ${SKIP_PATCHES}; do
  [ -f "${WORKING_PATH}/patches/${skip}" ] || {
    echo "ERROR: SKIP_PATCHES names ${skip}, which is not in patches/" >&2
    exit 1
  }
done

while IFS= read -r file; do
  if [[ " ${SKIP_PATCHES} " == *" ${file##*/} "* ]]; then
    echo "==> Skipping ${file##*/} (SKIP_PATCHES)"
    rm -f "$file"
    continue
  fi
  echo "==> Adding $file"
  patch -p1 <"$file"
done < <(find "${WORKING_PATH}/patches" -type f -name "*.patch" | sort)

#chmod a+x "${KERNEL_PATH}"/debian/rules
#chmod a+x "${KERNEL_PATH}"/debian/scripts/*
#chmod a+x "${KERNEL_PATH}"/debian/scripts/misc/*

echo >&2 "===]> Info: Bulding src... "

cd "${KERNEL_PATH}"
make clean

# Make config friendly with vanilla kernel
sed -i 's/CONFIG_VERSION_SIGNATURE=.*/CONFIG_VERSION_SIGNATURE=""/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"
sed -i 's/CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"
sed -i 's/CONFIG_SYSTEM_REVOCATION_KEYS=.*/CONFIG_SYSTEM_REVOCATION_KEYS=""/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"

# I want silent boot
sed -i 's/CONFIG_CONSOLE_LOGLEVEL_DEFAULT=.*/CONFIG_CONSOLE_LOGLEVEL_DEFAULT=4/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"
sed -i 's/CONFIG_CONSOLE_LOGLEVEL_QUIET=.*/CONFIG_CONSOLE_LOGLEVEL_QUIET=1/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"
sed -i 's/CONFIG_MESSAGE_LOGLEVEL_DEFAULT=.*/CONFIG_MESSAGE_LOGLEVEL_DEFAULT=4/g' "${WORKING_PATH}/templates/default-config-${CONFIG}"

# Copy the modified config
cp -v "${WORKING_PATH}/templates/default-config-${CONFIG}" "${KERNEL_PATH}/.config"

# Disable debug info
./scripts/config --undefine GDB_SCRIPTS
./scripts/config --undefine DEBUG_INFO
./scripts/config --undefine DEBUG_INFO_SPLIT
./scripts/config --undefine DEBUG_INFO_REDUCED
./scripts/config --undefine DEBUG_INFO_COMPRESSED
./scripts/config --set-val  DEBUG_INFO_NONE       y
./scripts/config --set-val  DEBUG_INFO_DWARF5     n
./scripts/config --enable   CONFIG_ANDROID_BINDER_IPC
./scripts/config --enable   CONFIG_ANDROID_BINDERFS
./scripts/config --set-str  CONFIG_ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"

# Enable T2 drivers
./scripts/config --module CONFIG_HID_APPLETB_BL
./scripts/config --module CONFIG_HID_APPLETB_KBD
./scripts/config --module CONFIG_DRM_APPLETBDRM
./scripts/config --module CONFIG_BT_HCIBCM4377
./scripts/config --module CONFIG_APFS_FS
./scripts/config --enable CONFIG_MODULE_FORCE_UNLOAD
./scripts/config --module CONFIG_T2BCE_CORE
./scripts/config --module CONFIG_T2BCE_VHCI
./scripts/config --module CONFIG_T2BCE_AUDIO
./scripts/config --module CONFIG_T2BCE_DMA
./scripts/config --module CONFIG_T2BCE_AVE
#./scripts/config --module CONFIG_MFD_MACSMC
#./scripts/config --module CONFIG_MFD_MACSMC_CORE
#./scripts/config --module CONFIG_MACSMC_RTKIT
#./scripts/config --module CONFIG_MACSMC_ACPI
#./scripts/config --module CONFIG_MACSMC_LIGHT
#./scripts/config --module CONFIG_BACKLIGHT_MACSMC
#./scripts/config --module CONFIG_MACSMC_BATTERY
#./scripts/config --module CONFIG_MACSMC_ACCEL
#./scripts/config --module CONFIG_INPUT_MACSMC_CHAMSHELL
#./scripts/config --module CONFIG_SENSORS_MACSMC_HWMON
#./scripts/config --module CONFIG_RTC_DRV_MACSMC
#./scripts/config --module CONFIG_MACSMC_POWER
#./scripts/config --enable CONFIG_APPLE_BRIGHTNESS
#./scripts/config --disable CONFIG_SENSORS_APPLESMC

make olddefconfig

# The T2 line relies on the t2smc DKMS module; applesmc must stay out (it has
# silently changed state across version bumps before), and the in-tree t2bce
# stack must be present. Check the final config the build consumes.
config_fail=0
grep -qx '# CONFIG_SENSORS_APPLESMC is not set' .config || {
  echo 'ERROR: final .config must not enable CONFIG_SENSORS_APPLESMC' >&2
  config_fail=1
}
for sym in T2BCE_CORE T2BCE_VHCI T2BCE_AUDIO T2BCE_DMA T2BCE_AVE; do
  grep -qx "CONFIG_${sym}=m" .config || {
    echo "ERROR: final .config lacks CONFIG_${sym}=m" >&2
    config_fail=1
  }
done
[ "${config_fail}" = 0 ] || exit 1

KERNEL_RELEASE="$(make -s kernelversion)${T2_LOCALVERSION}"
if [ "${REQUIRE_PRERELEASE}" = 1 ]; then
  case "${KERNEL_RELEASE}" in
    *-rc[0-9]*) ;;
    *) echo "ERROR: ${KERNEL_RELEASE} has no -rcN marker; the rEFInd hook would make it the default stable kernel" >&2
       exit 1 ;;
  esac
fi
echo "Kernel release: ${KERNEL_RELEASE}"

# Get rid of the dirty tag
echo "" >"${KERNEL_PATH}"/.scmversion

# Build Deb packages
make -j "$(getconf _NPROCESSORS_ONLN)" deb-pkg LOCALVERSION="${T2_LOCALVERSION}" KDEB_PKGVERSION="$(make kernelversion)-$(get_next_version)"

# The release the build actually produced must be the one checked above.
BUILT_RELEASE=$(cat include/config/kernel.release)
[ "${BUILT_RELEASE}" = "${KERNEL_RELEASE}" ] || {
  echo "ERROR: built ${BUILT_RELEASE}, expected ${KERNEL_RELEASE}" >&2
  exit 1
}

#### Copy artifacts to shared volume
echo >&2 "===]> Info: Copying debs and calculating SHA256 ... "
mkdir -p "${ARTIFACTS_DIR}"
cp -rfv "${KERNEL_PATH}/.config" "${ARTIFACTS_DIR}/kernel_config_${KERNEL_RELEASE}"
cp -rfv ../*.deb "${ARTIFACTS_DIR}/"

libc_debs=("${ARTIFACTS_DIR}"/linux-libc-dev_*_amd64.deb)
if [[ -e "${libc_debs[0]}" ]]; then
  libc_name=$(basename "${libc_debs[0]}" _amd64.deb)
  mv "${libc_debs[0]}" "${ARTIFACTS_DIR}/${libc_name}-${CODENAME}_amd64.deb"
fi
{
  echo "kernel_release=${KERNEL_RELEASE}"
  echo "kernel_ref=${KERNEL_REF}"
  echo "kernel_repository=${KERNEL_REPOSITORY}"
  echo "source_commit=${SOURCE_COMMIT}"
  echo "t2_repo_commit=$(git -c safe.directory="*" -C "${REPO_PATH}" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "skipped_patches=${SKIP_PATCHES:-<none>}"
  echo "patches:"
  (cd "${WORKING_PATH}/patches" && sha256sum ./*.patch)
} >"${ARTIFACTS_DIR}/PROVENANCE-${KERNEL_RELEASE}"
sha256sum ../*.deb >"${ARTIFACTS_DIR}/sha256-${CODENAME}"