#!/bin/bash

while [ $# -gt 0 ]
do
    case $1 in
    -i|--install) dkms_action='install';;
    -k|--kernel) dkms_kernel=$2; [[ -z $dkms_kernel ]] && echo '-k|--kernel must be followed by a kernel version' && exit 1;;
    -r|--remove) dkms_action='remove';;
    -u|--uninstall) dkms_action='remove';;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done

if [[ $dkms_action == 'install' ]]; then
    bash dkms.sh
    exit
elif [[ $dkms_action == 'remove' ]]; then
    bash dkms.sh -r
    exit
fi

[[ -n $dkms_kernel ]] && uname_r=$dkms_kernel || uname_r=$(uname -r)
kernel_version=$(echo $uname_r | cut -d '-' -f1 | cut -d '_' -f1) #ie 6.4.15

major_version=$(echo $kernel_version | cut -d '.' -f1)
minor_version=$(echo $kernel_version | cut -d '.' -f2)
major_minor=${major_version}${minor_version}
kernel_short_version="$major_version.$minor_version" #ie 5.2

build_dir="build"
patch_dir='patch_cirrus'
hda_dir="$build_dir/hda"

[[ -d $hda_dir ]] && rm -rf $hda_dir
[[ ! -d $build_dir ]] && mkdir $build_dir

# The build needs the kernel's hda source tree to compile the patched codecs
# against. Normally that comes from the matching mainline tarball on kernel.org.
# Ubuntu-versioned kernels (e.g. 26.04's "7.0.0") have NO mainline release there,
# so fall back to the Ubuntu linux-source-<ver> package, which ships the exact
# ABI-matched tree as /usr/src/linux-source-<ver>.tar.bz2.
kernel_src_archive=''
kernel_src_topdir=''

# Prefer the distro's exact source tree when it is already installed. Ubuntu
# kernel versions (e.g. 7.0.0-42) share their x.y name with the mainline
# tarball, so the wget block below would otherwise pull mainline linux-7.0 and
# compile it against a 7.0.0-42 ABI. The distro tarball is the tree this kernel
# was actually built from, so use it whenever it is on disk.
pkg_tarball="/usr/src/linux-source-$kernel_version.tar.bz2"
if [[ -s $pkg_tarball ]] && tar -tf "$pkg_tarball" >/dev/null 2>&1; then
    echo "=== using installed distro kernel source $pkg_tarball ==="
    kernel_src_archive="$pkg_tarball"
    kernel_src_topdir="$(tar -tf "$kernel_src_archive" 2>/dev/null | head -1 | cut -d/ -f1)"
    [[ -n $kernel_src_topdir ]] || { echo "could not read $kernel_src_archive...exiting"; exit 1; }
elif [[ -e $pkg_tarball ]]; then
    # A zero-byte / truncated tarball (e.g. an interrupted apt download) must
    # not be mistaken for a usable source tree.
    echo "WARNING: ignoring unusable $pkg_tarball"
fi

# attempt to download linux-x.x.x.tar.xz, then linux-x.x.tar.xz, from kernel.org
if [[ -z $kernel_src_archive ]]; then
    if wget -c "https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_version.tar.xz" -P $build_dir; then
        kernel_src_archive="$build_dir/linux-$kernel_version.tar.xz"
        kernel_src_topdir="linux-$kernel_version"
    elif wget -c "https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_short_version.tar.xz" -P $build_dir; then
        kernel_src_archive="$build_dir/linux-$kernel_short_version.tar.xz"
        kernel_src_topdir="linux-$kernel_short_version"
    fi
fi

# No mainline tarball (Ubuntu-versioned kernel): use the Ubuntu linux-source pkg.
if [[ -z $kernel_src_archive ]]; then
    src_pkg="linux-source-$kernel_version"
    echo "=== kernel.org has no linux-$kernel_version; falling back to Ubuntu $src_pkg ==="
    # Reuse an already-installed tarball if present; only touch apt when missing
    # or unusable (the -s test rules out the zero-byte stub left by an
    # interrupted download). (An apt-triggered DKMS rebuild already holds the
    # dpkg lock, so pre-installing linux-source-$ver yourself avoids a
    # self-deadlock in that path.)
    if [[ ! -s $pkg_tarball ]]; then
        [[ -e $pkg_tarball ]] && rm -f "$pkg_tarball"
        apt-get install -y --reinstall "$src_pkg" || { echo "could not install $src_pkg...exiting"; exit 1; }
    fi
    [[ -f $pkg_tarball ]] || { echo "$pkg_tarball missing after install...exiting"; exit 1; }
    kernel_src_archive="$pkg_tarball"
    # Detect the archive's top-level dir rather than assuming its name.
    kernel_src_topdir="$(tar -tf "$kernel_src_archive" 2>/dev/null | head -1 | cut -d/ -f1)"
    [[ -n $kernel_src_topdir ]] || { echo "could not read $kernel_src_archive...exiting"; exit 1; }
fi

# remove stale kernel tar.xz archives from the build dir (keep the current one)
find build/ -type f | grep -E 'linux.*\.tar\.xz' | grep -v "$(basename "$kernel_src_archive")" | xargs -r rm -f

if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
    makefile_name="Makefile_cs420x"
    tar --strip-components=2 -xvf "$kernel_src_archive" --directory=build/ "$kernel_src_topdir/sound/hda"
    mv $hda_dir/codecs/cirrus/Makefile $hda_dir/codecs/cirrus/Makefile.orig
    mv $hda_dir/codecs/cirrus/cs420x.c $hda_dir/codecs/cirrus/cs420x.c.orig
    cp $patch_dir/cs420x.c $patch_dir/patch_cirrus_macbook81_setup.h $patch_dir/patch_cirrus_a1534_setup.h $patch_dir/patch_cirrus_a1534_pcm.h $hda_dir/codecs/cirrus
    cp $patch_dir/$makefile_name $hda_dir/codecs/cirrus/Makefile
else
    makefile_name="Makefile_cirrus"
    tar --strip-components=3 -xvf "$kernel_src_archive" --directory=build/ "$kernel_src_topdir/sound/pci/hda"
    mv $hda_dir/Makefile $hda_dir/Makefile.orig
    mv $hda_dir/patch_cirrus.c $hda_dir/patch_cirrus.c.orig
    cp $patch_dir/patch_cirrus.c $patch_dir/patch_cirrus_macbook81_setup.h $patch_dir/patch_cirrus_a1534_setup.h $patch_dir/patch_cirrus_a1534_pcm.h $hda_dir/
    cp $patch_dir/$makefile_name $hda_dir/Makefile
fi

# if kernel version is 6.17 and beyond, replace the .free callback with .remove
if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
   sed -i 's/\.free/.remove/' $hda_dir/codecs/cirrus/patch_cirrus_a1534_pcm.h
fi

# if kernel version is between 6.12 and 6.16 then change
# snd_pci_quirk to hda_quirk
# SND_PCI_QUIRK to HDA_CODEC_QUIRK
# but leave alone SND_PCI_QUIRK_VENDOR

if (( major_version == 6 && minor_version >= 12 && minor_version < 17 )); then
   sed -i 's/snd_pci_quirk/hda_quirk/' $hda_dir/patch_cirrus.c
   sed -i 's/SND_PCI_QUIRK\b/HDA_CODEC_QUIRK/' $hda_dir/patch_cirrus.c
fi

if (( major_version == 6 && minor_version <= 11 )); then
   sed -i 's/hda_quirk/snd_pci_quirk/' $hda_dir/patch_cirrus.c
fi

# if kernel version is < 5.6 then change
# timespec64 to timespec
# ktime_get_real_ts64 to getnstimeofday

if [ $major_minor -lt 56 ]; then
   sed -i 's/timespec64/timespec/' $hda_dir/patch_cirrus.c
   sed -i 's/timespec64/timespec/' $hda_dir/patch_cirrus_a1534_pcm.h
   sed -i 's/ktime_get_real_ts64/getnstimeofday/' $hda_dir/patch_cirrus_a1534_pcm.h
fi

update_dir="/lib/modules/$uname_r/updates"
[[ ! -d $update_dir ]] && mkdir $update_dir
if ((${#dkms_kernel[@]})); then
    cp $makefile_name Makefile
fi
# Build against the TARGET kernel ($uname_r), not necessarily the running one —
# KERNELRELEASE selects KERNELDIR in Makefile_cs420x/Makefile_cirrus. This makes
# DKMS builds for a freshly-installed kernel correct even before reboot.
make -f $makefile_name KERNELRELEASE=$uname_r
# BUILD_ONLY=1 (set by dkms_build.sh) leaves installation to DKMS so the module
# lands once under updates/dkms instead of being double-copied into updates/.
if [[ -z "${BUILD_ONLY:-}" ]]; then
    make -f $makefile_name install
    echo -e "\ncontents of $update_dir"
    ls -lA $update_dir
else
    # BUILD_ONLY (DKMS): DKMS installs the .ko itself. Return success so the
    # PRE_BUILD chain (dkms_build.sh, set -e) continues to generic + azx.
    echo "=== built (BUILD_ONLY): build/hda/codecs/cirrus/snd-hda-codec-cs420x.ko ==="
fi
