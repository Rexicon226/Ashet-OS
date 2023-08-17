#!/bin/sh

# env:
# - ZARG (passed to `zig build)`
# - APP  (used for the debug filter instead of the OS)

set -e

ROOT="$(realpath "$(dirname "$(realpath "$0")")"/../)"

cd "${ROOT}"

if [ -z "$APP" ]; then
    APP="${ROOT}/zig-out/bin/ashet-os"
fi

if [ -z "$MACHINE" ]; then 
    MACHINE="rv32_virt"
fi

BOOTROM="${ROOT}/zig-out/rom/ashet-os.bin"
DISK="${ROOT}/zig-out/disk.img"

clear
zig build install -Dmachine=$MACHINE $ZARG

# compile root disk image

disk_size=33554432
if [ "${MACHINE}" = "efi_pc" ] ; then
    disk_size=536870912
fi
if [ "${MACHINE}" = "bios_pc" ] ; then
    disk_size=536870912
fi

truncate -s "${disk_size}" "${DISK}"


rootfs_path="${ROOT}/zig-out/rootfs"
rootfs="ashet-fs"
case $MACHINE in
    *_pc)
        rootfs="fat32"
        ;;
esac

echo "rootfs = ${rootfs}"

# validate wiki integrity
for file in $(find "${rootfs_path}/wiki" -name "*.hdoc"); do 
    hyperdoc "$file" > /dev/null
done

copyToFAT()
{
    mcopy -i "${DISK}@@1M" "$@"
}

case $rootfs in
    ashet-fs)
        # copy system root
        "${ROOT}/zig-out/bin/afs-tool" format --verbose --image "${DISK}" "${rootfs_path}"

        ;;
    
    fat32)
        ./zig-out/bin/init-disk "${DISK}" --create --sector_offset 2048 --root "${rootfs_path}"

        sfdisk "${DISK}" <<EOF
label: dos
label-id: 0xd917590e
device: zig-out/disk.img
unit: sectors
sector-size: 512

zig-out/disk.img1 : start=        2048, size=      260096, type=c, bootable
EOF
        ;;
    
    *)
        echo "Unsupported filesystem $rootfs"
        exit 1
        ;;
esac

echo "----------------------"

qemu_generic_flags="-d guest_errors,unimp -display gtk,show-tabs=on -serial stdio -no-reboot -no-shutdown"

case $MACHINE in
    rv32_virt)
        fallocate -l 33554432 "${BOOTROM}"
        qemu-system-riscv32 ${qemu_generic_flags} \
                -M virt \
                -m 32M \
                -netdev user,id=hostnet \
                -object filter-dump,id=hostnet-dump,netdev=hostnet,file=ashet-os.pcap \
                -device virtio-gpu-device,xres=400,yres=300 \
                -device virtio-keyboard-device \
                -device virtio-mouse-device \
                -device virtio-net-device,netdev=hostnet,mac=52:54:00:12:34:56 \
                -bios none \
                -drive "if=pflash,index=0,file=${BOOTROM},format=raw" \
                -drive "if=pflash,index=1,file=${DISK},format=raw" \
                -s "$@" \
        | "${ROOT}/zig-out/bin/debug-filter" "${APP}"
        ;;

    microvm)
        qemu-system-i386 ${qemu_generic_flags} \
            -M microvm \
            -m 32M \
            -netdev user,id=hostnet \
            -object filter-dump,id=hostnet-dump,netdev=hostnet,file=ashet-os.pcap \
            -device virtio-gpu-device,xres=400,yres=300 \
            -device virtio-keyboard-device \
            -device virtio-mouse-device \
            -device virtio-net-device,netdev=hostnet,mac=52:54:00:12:34:56 \
            -s "$@" \
        | "${ROOT}/zig-out/bin/debug-filter" "${APP}"
        ;;

    bios_pc)
        # Install syslinux and kernel:
        copyToFAT rootfs-x86/* ::
        copyToFAT ./zig-out/bin/ashet-os ::/ashet-os

        # setup MBR:
        dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr.bin "of=${DISK}" # TODO: Vendor mbr.bin
        
        # install syslinux
        syslinux --offset 1048576 --install "${DISK}"

        qemu-system-i386 ${qemu_generic_flags} \
          -machine pc \
          -cpu pentium2 \
          -hda "${DISK}" \
          -vga std \
          -s "$@" \
        | llvm-addr2line -e "${APP}"
        ;;

        # -device bochs-display,xres=800,yres=600 \
        # -device VGA,xres=800,yres=600,xmax=800,ymax=600 \
    efi_pc)
        qemu-system-x86_64 ${qemu_generic_flags} \
            -cpu qemu64 \
            -drive if=pflash,format=raw,unit=0,file=/usr/share/qemu/edk2-x86_64-code.fd,readonly=on \
            -drive if=ide,format=raw,unit=0,file="${DISK}" \
            -s "$@"
        ;;
        
    *)
        echo "Cannot start machine $MACHINE yet."
        exit 1
        ;;
esac

# tcpdump -r ashet-os.pcap 
