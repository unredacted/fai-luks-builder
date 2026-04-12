# fai-luks-builder

Build a self-contained, bootable FAI ISO for **unattended Debian
installation** with UEFI boot, LUKS full-disk encryption, LVM, SSH key
injection, and per-host hostname assignment.

## Features

- **One command** → bootable USB ISO with full-disk encryption
- **UEFI + GPT** with EFI System Partition, `/boot`, and LUKS+LVM
- **Release-agnostic** — targets any Debian release (Bookworm, Trixie, Forky, ...)
- **SSH key injection** from GitHub, URL, file, or inline
- **MAC-based hostname assignment** for fleet deployments
- **SSH hardened** — key-only auth, no password login
- **Cross-platform** — native Linux or macOS via Docker
- **Reproducible** — pins upstream FAI config, templates everything from YAML

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/yourusername/fai-luks-builder.git
cd fai-luks-builder
cp build.yaml.example build.yaml
vim build.yaml    # Set your passphrase, SSH key, release, etc.

# 2. Build the ISO
sudo ./build.sh -v

# 3. Write to USB
sudo dd if=./output/fai-luks.iso of=/dev/sdX bs=4M status=progress
```

On **macOS**, Docker is used automatically — no `sudo` needed:

```bash
./build.sh -v
```

## Configuration

Copy `build.yaml.example` to `build.yaml` and customize:

| Field | Required | Default | Description |
|---|---|---|---|
| `luks_passphrase` | ✓ | | LUKS encryption passphrase (min 8 chars) |
| `admin_user` | ✓ | | Linux username for the admin account |
| `admin_password` | ✓ | | Password (plaintext or SHA-512 hash) |
| `ssh_key_github` | ✓* | | GitHub username to fetch SSH keys |
| `ssh_key_url` | ✓* | | URL to fetch SSH public key |
| `ssh_key_file` | ✓* | | Path to local SSH public key file |
| `ssh_key_literal` | ✓* | | Inline SSH public key |
| `release` | | `trixie` | Debian codename (bookworm, trixie, forky, ...) |
| `timezone` | | `UTC` | System timezone |
| `locale` | | `en_US.UTF-8` | System locale |
| `keyboard` | | `us` | Keyboard layout |
| `disk_device` | | `auto` | Target disk (auto-detect or device name) |
| `swap_size` | | `4` | Swap size in GB |
| `efi_size` | | `512M` | EFI System Partition size |
| `boot_size` | | `1G` | /boot partition size |
| `root_size` | | `4G-` | Root partition min size (`-` = fill remaining) |
| `extra_packages` | | | Space-separated list of additional packages |
| `default_hostname` | | `debian-server` | Default hostname |
| `hosts` | | | List of `{hostname, mac}` for MAC-based naming |
| `post_install_script` | | | Path to custom post-install shell script |
| `output` | | `./output/fai-luks.iso` | ISO output path |

\* Exactly one `ssh_key_*` field is required.

## CLI Options

```
./build.sh [OPTIONS]
  -c, --config FILE    Path to build.yaml (default: ./build.yaml)
  -o, --output FILE    Override output ISO path
  -v, --verbose        Verbose output
  -h, --help           Show help and exit
  --skip-setup         Skip fai-setup (reuse existing nfsroot)
  --skip-mirror        Skip fai-mirror (reuse existing mirror)
  --clean              Remove all build artifacts and cached data
  --dry-run            Validate config and show what would be built
```

## How It Works

1. **Clones** the official [faiproject/fai-config](https://github.com/faiproject/fai-config)
   at build time
2. **Cherry-picks** useful upstream files (base classes, debconf, hooks)
3. **Layers** custom LUKS/server configs from `overlay/` on top
4. **Templates** in user-provided values from `build.yaml` (all values are
   injected as variables — no hardcoded release names or partition sizes)
5. **Drives** the FAI build pipeline (`fai-setup` → `fai-mirror` → `fai-cd`)

The `overlay/` directory mirrors the FAI config space structure exactly. Only
files we wrote live in this repo — upstream files are pulled fresh each build.

## Disk Layout

The ISO produces this partition layout (sizes are configurable):

```
GPT Disk
├── Partition 1:  /boot/efi   512M   vfat   (EFI System Partition)
├── Partition 2:  /boot        1G    ext4   (unencrypted boot)
└── Partition 3:  LUKS encrypted container
    └── LVM VG: vg0
        ├── lv root:  /       4G+    ext4
        └── lv swap:  swap    4G     swap
```

## Post-Install

After booting the installed system:

1. **Enter LUKS passphrase** at the GRUB prompt
2. **Change the LUKS passphrase**: `sudo cryptsetup luksChangeKey /dev/<partition>`
3. **Change the admin password**: `passwd <admin_user>`
4. **SSH in**: `ssh <admin_user>@<hostname>`

## Requirements

### Linux (native)
- Debian (Bookworm or newer) or Ubuntu 24.04+
- Root access
- ~5GB disk space for build artifacts

### macOS (Docker)
- Docker Desktop
- ~5GB disk space

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
