# Upgrading the Upstream FAI Config

This project depends on [faiproject/fai-config](https://github.com/faiproject/fai-config),
the official FAI example configuration. It is pinned to a specific commit in `build.sh`
to ensure reproducible builds.

## Current Pin

The pinned commit is defined at the top of `build.sh`:

```bash
UPSTREAM_REF="16f2d77801f7802fdd96b479ae19b6bbd6de36d0"  # Pinned 2026-04-12
```

## How to Update

1. **Check what changed upstream:**

   ```bash
   git clone https://github.com/faiproject/fai-config.git /tmp/fai-config-check
   cd /tmp/fai-config-check
   git log --oneline 16f2d77801f7802fdd96b479ae19b6bbd6de36d0..HEAD
   ```

   Review the changes, paying attention to files we cherry-pick (listed below).

2. **Review diffs in cherry-picked files:**

   ```bash
   git diff 16f2d77801f7802fdd96b479ae19b6bbd6de36d0..HEAD -- \
     class/01-classes class/10-base-classes class/20-hwdetect.sh class/85-efi-classes \
     class/FAIBASE.var class/DEBIAN.var \
     debconf/DEBIAN \
     hooks/instsoft.DEBIAN hooks/updatebase.DEBIAN hooks/savelog.LAST.sh \
     package_config/DEBIAN package_config/DEBIAN.gpg \
     scripts/FAIBASE/ scripts/DEBIAN/ scripts/GRUB_EFI/ scripts/LAST/ \
     files/
   ```

   Look for:
   - New variables our overlay should override
   - Changed script behavior that conflicts with our LUKS_SERVER or CUSTOM_SETUP scripts
   - New files that cherry-picked scripts now depend on
   - Removed files we still reference

3. **Update the pin:**

   Edit `build.sh` and replace the `UPSTREAM_REF` value with the new commit hash:

   ```bash
   UPSTREAM_REF="<new-commit-hash>"  # Pinned <date>. See UPGRADING.md to update.
   ```

4. **Test the update:**

   ```bash
   # Validate config still parses
   sudo ./build.sh --dry-run

   # Full build
   sudo ./build.sh -v

   # Boot test in QEMU
   qemu-system-x86_64 -m 4096 \
     -bios /usr/share/OVMF/OVMF_CODE.fd \
     -drive file=test-disk.qcow2,format=qcow2 \
     -cdrom output/fai-luks.iso -boot d
   ```

5. **Commit the change** with a message noting what upstream changes prompted the update.

## Files We Cherry-Pick from Upstream

These are copied into the assembled config space at build time. Our overlay files
are then applied on top, so anything in `overlay/` takes precedence.

```
class/01-classes              # Class argument parsing
class/10-base-classes         # Architecture and network class detection
class/20-hwdetect.sh          # Hardware detection
class/85-efi-classes           # EFI class detection
class/FAIBASE.var             # Base variables (overridden by LUKS_SERVER.var)
class/DEBIAN.var              # Debian variables (release, kernel, modules)
debconf/DEBIAN                # Base debconf preseeds
hooks/instsoft.DEBIAN         # APT config, locale install, dracut compression
hooks/updatebase.DEBIAN       # APT proxy, dpkg unsafe-io
hooks/savelog.LAST.sh         # Post-install error scanner
package_config/DEBIAN         # Base packages (openssh, sudo, kernel, grub, etc.)
package_config/DEBIAN.gpg     # Package signing key
scripts/FAIBASE/*             # Base system setup (timezone, hosts, tmp, dotfiles)
scripts/DEBIAN/*              # Root password, capabilities, network, hostname
scripts/GRUB_EFI/*            # UEFI GRUB bootloader installation
scripts/LAST/*                # Final cleanup and validation
files/etc/*                   # Template config files used by FAIBASE scripts
```

## Known Upstream Variables We Override

In `overlay/class/LUKS_SERVER.var`:

| Variable | Upstream default | Our override | Why |
|---|---|---|---|
| `ROOTPW` | Weak MD5 hash (password "fai") | `'!'` (locked) | Security: root locked, use admin+sudo |
| `USERPW` | Weak MD5 hash (password "fai") | `'!'` (locked) | Security: prevent weak default password |
| `username` | `demo` | Templated admin user | Our admin user, not demo |
| `TIMEZONE` | `Europe/Berlin` | Templated from YAML | User-configurable |
| `HOSTNAME` | (none) | Templated from YAML | User-configurable |
| `MAXPACKAGES` | `800` | `99999` | Faster installs |
