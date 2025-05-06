# Reboot Resize Tool for LVM/Partition Filesystems (Initramfs)

This tool, `reboot_resize.sh`, provides a command-line interface to schedule a one-time resize operation for your EXT4 root filesystem. It's designed for advanced users who need to shrink their root filesystem (either on an LVM logical volume or a standard partition) during the early boot (initramfs) stage, before the filesystem is mounted. This is particularly useful in scenarios where an online resize is not possible or desired.

**⚠️ DANGER ZONE: ADVANCED USERS ONLY ⚠️**

Modifying your root filesystem and LVM/partition structure in initramfs is an inherently risky operation. A mistake can lead to an unbootable system and data loss. **ALWAYS back up your critical data before using this tool. Test thoroughly in a virtual machine that mirrors your production environment first.**

## How it Works

The `reboot_resize.sh install <mode> <size>` command sets up the system for the resize operation:
1.  It creates two temporary scripts that are injected into the initramfs build process:
    *   A **hook script** placed in `/etc/initramfs-tools/hooks/`. This script is executed by `update-initramfs`. Its primary role is to ensure all necessary binaries and tools (like `lvm`, `resize2fs`, `bash`, GNU `date`, `e2fsprogs`, etc.) are copied into the initramfs image being generated. The tools included depend on the chosen `mode` (LVM or partition).
    *   A **premount script** placed in `/etc/initramfs-tools/scripts/local-premount/`. This script is packaged into the generated initramfs image. It is executed during the early boot sequence, after LVM volumes are typically active (if LVM is used for root) but critically *before* the main root filesystem is mounted read-write.
2.  The **premount script** contains the core logic for the resize:
    *   It first performs several safety checks: ensuring required tools are present, verifying the filesystem type is EXT4, and checking if the resize for the given target size has already been performed (using a flag file in `/run`).
    *   It runs `e2fsck -fy` on the unmounted root filesystem to ensure consistency.
    *   **If in `lvm` mode:** It determines the LVM logical volume path from the kernel's root device parameter and then uses the `lvm lvresize --resizefs` command. This command is robust as it coordinates shrinking both the logical volume and the EXT4 filesystem within it to the specified target size.
    *   **If in `partition` mode:** It uses `resize2fs` to shrink only the EXT4 filesystem on the root partition to the target size. **Crucially, this mode does NOT alter the partition table itself.**
    *   All significant actions and errors are logged to the kernel message buffer (`dmesg`).
3.  After creating these scripts, `reboot_resize.sh` executes `update-initramfs -u` to rebuild the initramfs image for the currently running kernel, embedding the new scripts and tools.
4.  Upon the next reboot, the initramfs loads, and the premount script executes its resize logic.
5.  The `DO_RESIZE=1` variable within the generated premount script and the `/run/root_fs_resized_*` flag file are mechanisms to prevent the resize from attempting to run on every boot after the initial setup. However, the definitive way to disable further resize attempts is to use the `sudo reboot_resize uninstall` command after a successful operation.

The `uninstall` command removes both the hook and premount scripts from `/etc/initramfs-tools/...` and runs `update-initramfs -u` again to generate a clean initramfs without the resize logic. The `log` command provides a convenient way to grep `dmesg` for messages logged by the premount script during its execution.

## Features

*   Supports resizing EXT4 filesystems.
*   Two modes of operation:
    *   **`lvm` mode:** Resizes an LVM logical volume and the EXT4 filesystem within it.
    *   **`partition` mode:** Shrinks an EXT4 filesystem on a standard partition. **IMPORTANT:** This mode *only* shrinks the filesystem. The partition itself is NOT resized by this script; you must do that manually afterwards.
*   Operations are scheduled for the next reboot.
*   Provides `install`, `uninstall`, and `log` commands via `reboot_resize.sh`.

## Prerequisites

*   Debian-based system using `initramfs-tools` (e.g., Debian, Ubuntu, Proxmox VE).
*   Root filesystem must be EXT4.
*   If using `lvm` mode, the root filesystem must be on an LVM logical volume.
*   Necessary tools must be available on the host system to be copied into the initramfs. The script attempts to include common requirements like `lvm2`, `e2fsprogs`, `coreutils`, `bash`, and `dmsetup`.

## Installation (from Git Repo)

1.  Clone this repository or download the `reboot_resize.sh` and `Makefile`.
    ```bash
    git clone <repository_url>
    cd <repository_directory>
    ```
2.  Install the script to `/usr/local/bin/reboot_resize`:
    ```bash
    sudo make install
    ```
    This will copy `reboot_resize.sh` to `/usr/local/bin/reboot_resize` and make it executable. You can then run `reboot_resize` from any location.

## Usage

Run `sudo reboot_resize help` or `reboot_resize` with no arguments for detailed command usage, which includes:
*   `install <mode> <TARGET_SIZE>`
*   `uninstall`
*   `log`

**All `install` and `uninstall` commands must be run with `sudo`.**

## Workflow Example (LVM)

1.  **Backup your system!**
2.  Install the tool (if not already): `sudo make install`
3.  Schedule a resize of your LVM root volume to 20G:
    ```bash
    sudo reboot_resize install lvm 20G
    ```
4.  Confirm the dangerous operation when prompted.
5.  Reboot the system: `sudo reboot`
6.  After the system reboots, verify the resize:
    ```bash
    df -h /
    sudo lvs
    sudo reboot_resize log
    ```
7.  **CRITICAL:** Uninstall the hooks to prevent re-running:
    ```bash
    sudo reboot_resize uninstall
    ```

## Workflow Example (Partition Filesystem Shrink)

1.  **Backup your system!**
2.  Install the tool (if not already): `sudo make install`
3.  Schedule a shrink of the EXT4 filesystem on your root partition to 8G:
    ```bash
    sudo reboot_resize install partition 8G
    ```
4.  Confirm.
5.  Reboot: `sudo reboot`
6.  After the system reboots, check the logs and filesystem size:
    ```bash
    sudo reboot_resize log
    df -h /
    ```
    Verify `df -h /` shows the filesystem as 8G. The partition entry in `lsblk` or `fdisk -l` will still show its original, larger size.
7.  **CRITICAL:** Uninstall the initramfs hooks:
    ```bash
    sudo reboot_resize uninstall
    ```
8.  **MANUAL STEP: Resize the Partition Table Entry.**
    After the filesystem is shrunk, you need to update the partition table to reflect the new, smaller end point of the partition.
    *   **Option A (Live Environment - Safest for beginners):** Boot from a Live USB (e.g., GParted Live, or your distribution's installer in rescue mode). Use GParted (graphical) or `cfdisk`/`fdisk`/`parted` (command-line) to shrink the actual partition. This is generally the safest way as the partition is unmounted.
    *   **Option B (Advanced - Online with `gdisk` or `fdisk` - GPT only for `gdisk`):** For **GPT partitioned disks**, you can *sometimes* delete and re-create the partition entry *with the same start sector but a new, smaller end sector* using `gdisk` **on the running system**. This is highly advanced and risky.
        *   You would note the exact start sector of your root partition.
        *   Unmount any non-root filesystems on the same disk if possible (though root will be mounted).
        *   Use `gdisk /dev/sdX` (replace `sdX` with your disk).
        *   Delete the root partition entry (e.g., `d` command).
        *   Re-create it (e.g., `n` command) with the **same start sector**, a new end sector (calculated to match your new 8G filesystem plus a small safety margin), and the **same partition type GUID**.
        *   Write changes (`w`).
        *   You will likely need to run `partprobe /dev/sdX` or reboot for the kernel to re-read the new partition table.
        *   **This online method is extremely risky. A typo can destroy your partition table. It's generally not recommended unless you are very experienced.** The live environment method is much safer.
9.  After the partition table is correctly updated and the system reboots, the OS should see the partition at its new, smaller size.

## Disclaimer

This tool is provided as-is, without any warranty. Use it entirely at your own risk. The author is not responsible for any data loss or system damage that may occur as a result of using this script.

## Contributing

Feel free to open issues or pull requests if you find bugs or have improvements.
