# fai-luks-builder

Build a self-contained, bootable FAI ISO for **unattended Debian
installation** with UEFI boot, LUKS full-disk encryption, LVM, SSH key
injection, per-host hostname/IP assignment, and optional remote LUKS
unlock via dropbear.

## Features

- **One command** → bootable USB ISO with full-disk encryption
- **UEFI + GPT** with EFI System Partition, `/boot`, and LUKS+LVM
- **Release-agnostic** — targets any Debian release (Bookworm, Trixie, Forky, ...)
- **SSH key injection** from GitHub, URL, file, or inline
- **MAC-based host config** — per-host hostname, static IP, and dropbear settings
- **Dropbear-initramfs** — remote LUKS unlock over SSH (optional, per-host)
- **SSH hardened** — key-only auth, no password login
- **Cross-platform** — native Linux or macOS via Docker (with `--arch` for cross-compilation)
- **Reproducible** — pins upstream FAI config, templates everything from YAML

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/unredacted/fai-luks-builder.git
cd fai-luks-builder
cp build.yaml.example build.yaml
vim build.yaml    # Set your passphrase, SSH key, hosts, etc.

# 2. Build the ISO
sudo ./build.sh -v

# 3. Write to USB
sudo dd if=./output/fai-luks.iso of=/dev/sdX bs=4M status=progress
```

On **macOS**, Docker is used automatically — no `sudo` needed:

```bash
./build.sh -v            # Defaults to amd64 (uses QEMU emulation on Apple Silicon)
./build.sh -v --arch arm64   # Build arm64 ISO instead
```

## Configuration

Copy `build.yaml.example` to `build.yaml` and customize:

### Core Settings

| Field | Required | Default | Description |
|---|---|---|---|
| `luks_passphrase` | Yes | | LUKS encryption passphrase (min 8 chars) |
| `admin_user` | Yes | | Linux username for the admin account |
| `admin_password` | Yes | | Password (plaintext or SHA-512 hash) |
| `ssh_key_github` | One of four | | GitHub username to fetch SSH keys |
| `ssh_key_url` | One of four | | URL to fetch SSH public key |
| `ssh_key_file` | One of four | | Path to local SSH public key file |
| `ssh_key_literal` | One of four | | Inline SSH public key |
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
| `post_install_script` | | | Path to custom post-install shell script |
| `output` | | `./output/fai-luks.iso` | ISO output path |

Exactly one `ssh_key_*` field is required.

### Per-Host Configuration

The `hosts` array maps MAC addresses to per-host settings. All hosts share the
same ISO — configuration is applied at install time based on MAC address.

```yaml
hosts:
  - hostname: server01
    mac: "0c:c4:7a:69:39:30"
    ip: "10.77.0.20/24"           # CIDR notation. Omit for DHCP.
    gateway: "10.77.0.1"          # Required when ip is set.
    interface: "enp94s0f0"        # Optional. Empty = auto-detect.
    dropbear: true                # Enable remote LUKS unlock for this host.
    dropbear_options: "-I 600 -j -k -p 22 -s"
  - hostname: server02
    mac: "aa:bb:cc:dd:ee:01"
    # No ip/dropbear = DHCP + local console LUKS unlock
```

| Per-Host Field | Required | Description |
|---|---|---|
| `hostname` | Yes | Target hostname |
| `mac` | Yes | MAC address (`XX:XX:XX:XX:XX:XX`) |
| `ip` | | Static IP in CIDR notation (e.g., `10.0.0.1/24`) |
| `gateway` | When `ip` set | Default gateway |
| `interface` | | Network interface name (auto-detected if empty) |
| `dropbear` | | `true` to enable remote LUKS unlock (requires `ip`) |
| `dropbear_options` | | Dropbear CLI options (overrides global default) |

### Dropbear (Remote LUKS Unlock)

The optional `dropbear` section sets global defaults for remote LUKS unlock.
Per-host `dropbear: true` enables it for individual hosts.

```yaml
dropbear:
  enabled: false                    # Global default
  options: "-I 600 -j -k -p 22 -s" # Dropbear CLI options
  ssh_key: ""                       # Separate key for dropbear. Empty = reuse ssh_key_*
```

When enabled, the initramfs starts a dropbear SSH server at boot with a static IP.
Connect and unlock remotely:

```bash
ssh root@10.77.0.20       # Connect to initramfs dropbear
cryptroot-unlock           # Enter the LUKS passphrase
```

## CLI Options

```
./build.sh [OPTIONS]
  -c, --config FILE    Path to build.yaml (default: ./build.yaml)
  -o, --output FILE    Override output ISO path
  -v, --verbose        Verbose output
  -h, --help           Show help and exit
  --arch ARCH          Target architecture: amd64 (default) or arm64
  --skip-setup         Skip fai-setup (reuse existing nfsroot)
  --skip-mirror        Skip fai-mirror (reuse existing mirror)
  --clean              Remove all build artifacts and cached data
  --dry-run            Validate config and show what would be built
```

## How It Works

1. **Clones** the official [faiproject/fai-config](https://github.com/faiproject/fai-config)
   at a pinned commit (see [UPGRADING.md](UPGRADING.md))
2. **Cherry-picks** useful upstream files (base classes, debconf, hooks)
3. **Layers** custom LUKS/server configs from `overlay/` on top
4. **Templates** in user-provided values from `build.yaml`
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

1. **Enter LUKS passphrase** — at the console, or via SSH if dropbear is enabled
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
- ~5GB disk space (more if cross-compiling amd64 on Apple Silicon)

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
