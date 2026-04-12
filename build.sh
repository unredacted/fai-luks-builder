#!/usr/bin/env bash
# build.sh — Build a self-contained FAI ISO for unattended Debian
#             installation with UEFI boot, LUKS full-disk encryption, and LVM.
#
# Usage: ./build.sh [OPTIONS]
#   -c, --config FILE    Path to build.yaml (default: ./build.yaml)
#   -o, --output FILE    Override output ISO path
#   -v, --verbose        Verbose output
#   -h, --help           Show help and exit
#   --skip-setup         Skip fai-setup (reuse existing nfsroot)
#   --skip-mirror        Skip fai-mirror (reuse existing mirror)
#   --clean              Remove all build artifacts and cached data, then exit
#   --dry-run            Validate config and show what would be built, then exit
#   --no-docker          Run natively even on macOS (used internally by Docker)
#
# Copyright (c) 2026 — Licensed under the GNU General Public License v3.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

UPSTREAM_REPO="https://github.com/faiproject/fai-config.git"
UPSTREAM_REF="16f2d77801f7802fdd96b479ae19b6bbd6de36d0"  # Pinned 2026-04-12. See UPGRADING.md to update.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="/var/tmp/fai-luks-builder"
MIRROR_DIR="/var/tmp/fai-mirror"
LOG_DIR="/var/log/fai-luks-builder"
FAI_CONFIG_TARGET="/srv/fai/config"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Defaults ─────────────────────────────────────────────────────────────────

CONFIG_FILE="./build.yaml"
OUTPUT_OVERRIDE=""
VERBOSE=0
SKIP_SETUP=0
SKIP_MIRROR=0
DRY_RUN=0
CLEAN=0
NO_DOCKER=0

# ─── Functions ────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: ./build.sh [OPTIONS]

Build a self-contained FAI ISO for unattended Debian installation
with UEFI boot, LUKS full-disk encryption, LVM, and SSH key injection.

Options:
  -c, --config FILE    Path to build.yaml (default: ./build.yaml)
  -o, --output FILE    Override output ISO path
  -v, --verbose        Verbose output
  -h, --help           Show help and exit
  --skip-setup         Skip fai-setup (reuse existing nfsroot)
  --skip-mirror        Skip fai-mirror (reuse existing mirror)
  --clean              Remove all build artifacts and cached data, then exit
  --dry-run            Validate config and show what would be built, then exit
  --no-docker          Run natively (used internally by Docker entrypoint)

Examples:
  ./build.sh -v                          # Build with verbose output
  ./build.sh -c my-config.yaml           # Use custom config file
  ./build.sh --dry-run                   # Validate config only
  ./build.sh --clean                     # Remove all build artifacts
EOF
    exit 0
}

log_step() {
    local step="$1" total="$2" msg="$3"
    echo -e "\n${BOLD}${BLUE}==> [Step ${step}/${total}] ${msg}${NC}"
}

log_info() {
    echo -e "${GREEN}    ✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}    ⚠${NC} $1"
}

log_error() {
    echo -e "${RED}    ✗${NC} $1" >&2
}

log_fatal() {
    echo -e "\n${RED}${BOLD}ERROR:${NC} $1" >&2
    exit 1
}

# Cleanup trap — only prints on failure
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ $DRY_RUN -eq 0 ] && [ $CLEAN -eq 0 ]; then
        echo -e "\n${RED}${BOLD}Build failed (exit code ${exit_code}).${NC}"
        echo -e "Check logs at: ${LOG_DIR}/"
    fi
}
trap cleanup EXIT

# ─── Argument Parsing ─────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_OVERRIDE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            --skip-setup)
                SKIP_SETUP=1
                shift
                ;;
            --skip-mirror)
                SKIP_MIRROR=1
                shift
                ;;
            --clean)
                CLEAN=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-docker)
                NO_DOCKER=1
                shift
                ;;
            *)
                log_fatal "Unknown option: $1\nRun './build.sh --help' for usage."
                ;;
        esac
    done
}

# ─── Clean ────────────────────────────────────────────────────────────────────

do_clean() {
    echo -e "${BOLD}Cleaning all build artifacts...${NC}"
    rm -rf "$WORKDIR"       && log_info "Removed $WORKDIR"
    rm -rf "$MIRROR_DIR"    && log_info "Removed $MIRROR_DIR"
    rm -rf "$FAI_CONFIG_TARGET" && log_info "Removed $FAI_CONFIG_TARGET"
    rm -rf /srv/fai/nfsroot && log_info "Removed /srv/fai/nfsroot"
    rm -rf "$LOG_DIR"       && log_info "Removed $LOG_DIR"
    echo -e "\n${GREEN}${BOLD}Cleaned all build artifacts.${NC}"
    exit 0
}

# ─── Platform Detection & Docker Routing ──────────────────────────────────────

detect_platform() {
    local platform
    platform="$(uname -s)"

    case "$platform" in
        Darwin)
            if [ $NO_DOCKER -eq 1 ]; then
                log_fatal "Cannot run FAI natively on macOS. Remove --no-docker."
            fi
            run_in_docker "$@"
            exit $?
            ;;
        Linux)
            if [ $NO_DOCKER -eq 0 ]; then
                # Check if running as root
                if [ "$(id -u)" -ne 0 ]; then
                    log_fatal "This script must be run as root on Linux.\nTry: sudo ./build.sh $*"
                fi
                # Check if Debian-based
                if [ ! -f /etc/debian_version ]; then
                    log_fatal "This script requires Debian or Ubuntu."
                fi
            fi
            ;;
        *)
            log_fatal "Unsupported platform: $platform. Only Linux and macOS (via Docker) are supported."
            ;;
    esac
}

run_in_docker() {
    echo -e "${BOLD}macOS detected — building via Docker...${NC}"

    # Verify Docker is available
    if ! command -v docker &>/dev/null; then
        log_fatal "Docker is required on macOS.\nInstall Docker Desktop: https://www.docker.com/products/docker-desktop/"
    fi
    if ! docker info &>/dev/null; then
        log_fatal "Docker daemon is not running. Start Docker Desktop and try again."
    fi

    # Resolve paths to absolute
    CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
    local output_dir
    output_dir="$(cd "$(dirname "${OUTPUT_OVERRIDE:-./output/fai.iso}")" && pwd)"
    mkdir -p "$output_dir"

    # Build the Docker image (only if Dockerfile changed)
    local dockerfile_hash
    dockerfile_hash="$(md5 -q "$REPO_ROOT/Dockerfile" 2>/dev/null || md5sum "$REPO_ROOT/Dockerfile" | cut -d' ' -f1)"
    echo -e "  Building Docker image (hash: ${dockerfile_hash:0:8})..."
    docker build -t fai-luks-builder "$REPO_ROOT"

    # Construct docker run arguments
    local -a docker_args=(
        --rm
        --privileged
        -v "${CONFIG_FILE}:/workspace/build.yaml:ro"
        -v "${output_dir}:/output"
    )

    # Read SSH key file path from config if present
    # Use yq if available, fall back to awk for macOS where yq may not be installed
    local ssh_key_file=""
    local post_script=""
    if command -v yq &>/dev/null; then
        ssh_key_file="$(yq -r '.ssh_key_file // empty' "$CONFIG_FILE" 2>/dev/null || true)"
        post_script="$(yq -r '.post_install_script // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    else
        ssh_key_file="$(awk -F': *' '/^ssh_key_file:/{gsub(/["'"'"']/, "", $2); print $2}' "$CONFIG_FILE")"
        post_script="$(awk -F': *' '/^post_install_script:/{gsub(/["'"'"']/, "", $2); print $2}' "$CONFIG_FILE")"
    fi
    if [ -n "$ssh_key_file" ]; then
        ssh_key_file="$(cd "$(dirname "$ssh_key_file")" && pwd)/$(basename "$ssh_key_file")"
        docker_args+=(-v "${ssh_key_file}:/workspace/ssh_key.pub:ro")
    fi
    if [ -n "$post_script" ]; then
        post_script="$(cd "$(dirname "$post_script")" && pwd)/$(basename "$post_script")"
        docker_args+=(-v "${post_script}:/workspace/post_install.sh:ro")
    fi

    # Passthrough CLI flags
    local -a passthrough=()
    [ $VERBOSE -eq 1 ] && passthrough+=(-v)
    [ $SKIP_SETUP -eq 1 ] && passthrough+=(--skip-setup)
    [ $SKIP_MIRROR -eq 1 ] && passthrough+=(--skip-mirror)
    [ $DRY_RUN -eq 1 ] && passthrough+=(--dry-run)

    local output_basename
    output_basename="$(basename "${OUTPUT_OVERRIDE:-fai-luks.iso}")"

    echo -e "  Starting container..."
    docker run "${docker_args[@]}" fai-luks-builder \
        --config /workspace/build.yaml \
        --output "/output/${output_basename}" \
        "${passthrough[@]}"
}

# ─── Dependency Installation ──────────────────────────────────────────────────

install_dependencies() {
    log_step 1 8 "Installing dependencies..."

    # Install FAI if not present
    if ! command -v fai-cd &>/dev/null; then
        log_info "Installing FAI quickstart..."
        wget -qO /etc/apt/trusted.gpg.d/fai-project.gpg \
            https://fai-project.org/download/2BF8D9FE074BCDE4.gpg
        echo "deb https://fai-project.org/download trixie koeln" \
            > /etc/apt/sources.list.d/fai.list
        apt-get update -qq
        apt-get install -y -qq fai-quickstart fai-doc > /dev/null
        log_info "FAI quickstart installed"
    else
        log_info "FAI already installed"
    fi

    # Install yq if not present
    if ! command -v yq &>/dev/null; then
        log_info "Installing yq..."
        local arch
        arch="$(dpkg --print-architecture)"
        wget -qO /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
        chmod +x /usr/local/bin/yq
        log_info "yq installed"
    else
        log_info "yq already installed"
    fi

    # Ensure other tools are available
    for tool in curl git openssl; do
        if ! command -v "$tool" &>/dev/null; then
            apt-get install -y -qq "$tool" > /dev/null
            log_info "Installed $tool"
        fi
    done
    log_info "All dependencies satisfied"
}

# ─── YAML Parsing & Validation ────────────────────────────────────────────────

parse_and_validate() {
    log_step 2 8 "Parsing and validating build.yaml..."

    if [ ! -f "$CONFIG_FILE" ]; then
        log_fatal "Config file not found: $CONFIG_FILE\nCopy build.yaml.example to build.yaml and customize it."
    fi

    # Read all values
    BUILD_LUKS_PASSPHRASE="$(yq -r '.luks_passphrase // empty' "$CONFIG_FILE")"
    BUILD_ADMIN_USER="$(yq -r '.admin_user // empty' "$CONFIG_FILE")"
    BUILD_ADMIN_PASSWORD="$(yq -r '.admin_password // empty' "$CONFIG_FILE")"
    BUILD_SSH_KEY_GITHUB="$(yq -r '.ssh_key_github // empty' "$CONFIG_FILE")"
    BUILD_SSH_KEY_URL="$(yq -r '.ssh_key_url // empty' "$CONFIG_FILE")"
    BUILD_SSH_KEY_FILE="$(yq -r '.ssh_key_file // empty' "$CONFIG_FILE")"
    BUILD_SSH_KEY_LITERAL="$(yq -r '.ssh_key_literal // empty' "$CONFIG_FILE")"
    BUILD_RELEASE="$(yq -r '.release // "trixie"' "$CONFIG_FILE")"
    BUILD_TIMEZONE="$(yq -r '.timezone // "UTC"' "$CONFIG_FILE")"
    BUILD_LOCALE="$(yq -r '.locale // "en_US.UTF-8"' "$CONFIG_FILE")"
    BUILD_KEYBOARD="$(yq -r '.keyboard // "us"' "$CONFIG_FILE")"
    BUILD_DISK_DEVICE="$(yq -r '.disk_device // "auto"' "$CONFIG_FILE")"
    BUILD_SWAP_SIZE="$(yq -r '.swap_size // "4"' "$CONFIG_FILE")"
    BUILD_EFI_SIZE="$(yq -r '.efi_size // "512M"' "$CONFIG_FILE")"
    BUILD_BOOT_SIZE="$(yq -r '.boot_size // "1G"' "$CONFIG_FILE")"
    BUILD_ROOT_SIZE="$(yq -r '.root_size // "4G-"' "$CONFIG_FILE")"
    BUILD_NETWORK="$(yq -r '.network // "dhcp"' "$CONFIG_FILE")"
    BUILD_EXTRA_PACKAGES="$(yq -r '.extra_packages // empty' "$CONFIG_FILE")"
    BUILD_DEFAULT_HOSTNAME="$(yq -r '.default_hostname // "debian-server"' "$CONFIG_FILE")"
    BUILD_OUTPUT="$(yq -r '.output // "./output/fai-luks.iso"' "$CONFIG_FILE")"
    BUILD_POST_INSTALL="$(yq -r '.post_install_script // empty' "$CONFIG_FILE")"

    # Override output if specified on CLI
    if [ -n "$OUTPUT_OVERRIDE" ]; then
        BUILD_OUTPUT="$OUTPUT_OVERRIDE"
    fi

    # Read hosts array
    BUILD_HOST_COUNT="$(yq -r '.hosts | length // 0' "$CONFIG_FILE")"

    # ── Validation ──
    local errors=()

    # Required fields
    [ -z "$BUILD_LUKS_PASSPHRASE" ] && errors+=("luks_passphrase: required")
    [ ${#BUILD_LUKS_PASSPHRASE} -lt 8 ] 2>/dev/null && errors+=("luks_passphrase: minimum 8 characters")

    # Release codename
    if ! [[ "$BUILD_RELEASE" =~ ^[a-z]+$ ]]; then
        errors+=("release: must be a Debian codename (e.g., bookworm, trixie, forky)")
    fi

    [ -z "$BUILD_ADMIN_USER" ] && errors+=("admin_user: required")
    if [ -n "$BUILD_ADMIN_USER" ] && ! [[ "$BUILD_ADMIN_USER" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        errors+=("admin_user: must be lowercase, start with letter, contain only a-z 0-9 _ -")
    fi

    [ -z "$BUILD_ADMIN_PASSWORD" ] && errors+=("admin_password: required")
    if [ -n "$BUILD_ADMIN_PASSWORD" ] && [[ "$BUILD_ADMIN_PASSWORD" != \$6\$* ]] && [[ "$BUILD_ADMIN_PASSWORD" != \$y\$* ]]; then
        [ ${#BUILD_ADMIN_PASSWORD} -lt 8 ] && errors+=("admin_password: minimum 8 characters")
    fi

    # SSH key: exactly one source
    local ssh_count=0
    [ -n "$BUILD_SSH_KEY_GITHUB" ] && ssh_count=$((ssh_count + 1))
    [ -n "$BUILD_SSH_KEY_URL" ] && ssh_count=$((ssh_count + 1))
    [ -n "$BUILD_SSH_KEY_FILE" ] && ssh_count=$((ssh_count + 1))
    [ -n "$BUILD_SSH_KEY_LITERAL" ] && ssh_count=$((ssh_count + 1))
    if [ $ssh_count -eq 0 ]; then
        errors+=("ssh_key_*: exactly one SSH key source is required (ssh_key_github, ssh_key_url, ssh_key_file, or ssh_key_literal)")
    elif [ $ssh_count -gt 1 ]; then
        errors+=("ssh_key_*: only one SSH key source may be specified (found $ssh_count)")
    fi

    # Disk device
    if [ -n "$BUILD_DISK_DEVICE" ] && [ "$BUILD_DISK_DEVICE" != "auto" ]; then
        if ! [[ "$BUILD_DISK_DEVICE" =~ ^[a-z0-9]+$ ]]; then
            errors+=("disk_device: must be 'auto' or a device name (e.g., sda, nvme0n1)")
        fi
    fi

    # Swap size
    if ! [[ "$BUILD_SWAP_SIZE" =~ ^[0-9]+$ ]] || [ "$BUILD_SWAP_SIZE" -lt 1 ]; then
        errors+=("swap_size: must be an integer >= 1")
    fi

    # Output
    if [[ "$BUILD_OUTPUT" != *.iso ]]; then
        errors+=("output: must end in .iso")
    fi

    # Locale pattern
    if ! [[ "$BUILD_LOCALE" =~ ^[a-z]{2}_[A-Z]{2}\.[A-Za-z0-9-]+$ ]]; then
        errors+=("locale: must match pattern like en_US.UTF-8")
    fi

    # Post-install script
    if [ -n "$BUILD_POST_INSTALL" ] && [ ! -r "$BUILD_POST_INSTALL" ]; then
        errors+=("post_install_script: file not found or not readable: $BUILD_POST_INSTALL")
    fi

    # Validate hosts array
    if [ "$BUILD_HOST_COUNT" -gt 0 ]; then
        local i
        for ((i = 0; i < BUILD_HOST_COUNT; i++)); do
            local h_hostname h_mac
            h_hostname="$(yq -r ".hosts[$i].hostname // empty" "$CONFIG_FILE")"
            h_mac="$(yq -r ".hosts[$i].mac // empty" "$CONFIG_FILE")"

            [ -z "$h_hostname" ] && errors+=("hosts[$i].hostname: required")
            if [ -n "$h_hostname" ] && ! [[ "$h_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
                errors+=("hosts[$i].hostname: invalid hostname '$h_hostname'")
            fi
            [ -z "$h_mac" ] && errors+=("hosts[$i].mac: required")
            if [ -n "$h_mac" ] && ! [[ "$h_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                errors+=("hosts[$i].mac: invalid MAC address '$h_mac'")
            fi
        done
    fi

    # Report all errors at once
    if [ ${#errors[@]} -gt 0 ]; then
        echo -e "\n${RED}${BOLD}Configuration errors:${NC}"
        for err in "${errors[@]}"; do
            log_error "$err"
        done
        exit 1
    fi

    log_info "Configuration validated"

    # ── Resolve SSH public key ──
    BUILD_SSH_KEY=""
    if [ -n "$BUILD_SSH_KEY_GITHUB" ]; then
        log_info "Fetching SSH key from GitHub user: $BUILD_SSH_KEY_GITHUB"
        BUILD_SSH_KEY="$(curl -fSs "https://github.com/${BUILD_SSH_KEY_GITHUB}.keys")" || \
            log_fatal "Failed to fetch SSH keys from GitHub for user: $BUILD_SSH_KEY_GITHUB"
    elif [ -n "$BUILD_SSH_KEY_URL" ]; then
        log_info "Fetching SSH key from URL: $BUILD_SSH_KEY_URL"
        BUILD_SSH_KEY="$(curl -fSs "$BUILD_SSH_KEY_URL")" || \
            log_fatal "Failed to fetch SSH key from URL: $BUILD_SSH_KEY_URL"
    elif [ -n "$BUILD_SSH_KEY_FILE" ]; then
        log_info "Reading SSH key from file: $BUILD_SSH_KEY_FILE"
        BUILD_SSH_KEY="$(cat "$BUILD_SSH_KEY_FILE")" || \
            log_fatal "Failed to read SSH key file: $BUILD_SSH_KEY_FILE"
    elif [ -n "$BUILD_SSH_KEY_LITERAL" ]; then
        BUILD_SSH_KEY="$BUILD_SSH_KEY_LITERAL"
    fi

    # Validate SSH key format
    if ! echo "$BUILD_SSH_KEY" | head -1 | grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-)'; then
        log_fatal "SSH key does not start with a valid algorithm prefix.\nGot: $(echo "$BUILD_SSH_KEY" | head -c 40)..."
    fi
    log_info "SSH public key resolved ($(echo "$BUILD_SSH_KEY" | wc -l | tr -d ' ') key(s))"

    # ── Hash admin password if not pre-hashed ──
    if [[ "$BUILD_ADMIN_PASSWORD" == \$6\$* ]] || [[ "$BUILD_ADMIN_PASSWORD" == \$y\$* ]]; then
        BUILD_ADMIN_PASSWORD_HASH="$BUILD_ADMIN_PASSWORD"
        log_info "Admin password: using pre-hashed value"
    else
        BUILD_ADMIN_PASSWORD_HASH="$(printf '%s' "$BUILD_ADMIN_PASSWORD" | openssl passwd -6 -stdin)"
        log_info "Admin password: hashed with SHA-512"
    fi

    # Derive uppercase release class name (e.g., trixie → TRIXIE)
    BUILD_RELEASE_CLASS="$(echo "$BUILD_RELEASE" | tr '[:lower:]' '[:upper:]')"

    log_info "All values resolved"
}

# ─── Templating Engine ────────────────────────────────────────────────────────

# Replace a placeholder in a file using awk (handles special characters safely)
template_replace() {
    local placeholder="$1"
    local value="$2"
    local file="$3"

    awk -v pat="$placeholder" -v rep="$value" '{
        idx = index($0, pat)
        while (idx > 0) {
            $0 = substr($0, 1, idx-1) rep substr($0, idx + length(pat))
            idx = index($0, pat)
        }
        print
    }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Replace a placeholder across all files in a directory
template_replace_all() {
    local placeholder="$1"
    local value="$2"
    local dir="$3"

    while IFS= read -r file; do
        if grep -qF "$placeholder" "$file" 2>/dev/null; then
            template_replace "$placeholder" "$value" "$file"
        fi
    done < <(find "$dir" -type f)
}

# ─── FAI System Config ───────────────────────────────────────────────────────

write_fai_config() {
    log_step 3 8 "Writing FAI system config..."

    mkdir -p /etc/fai

    cp "$REPO_ROOT/templates/fai.conf.tpl" /etc/fai/fai.conf
    log_info "Wrote /etc/fai/fai.conf"

    cp "$REPO_ROOT/templates/nfsroot.conf.tpl" /etc/fai/nfsroot.conf
    # Inject the release codename into nfsroot.conf (it's outside the config space)
    template_replace "TEMPLATED_RELEASE" "$BUILD_RELEASE" /etc/fai/nfsroot.conf
    log_info "Wrote /etc/fai/nfsroot.conf (release: $BUILD_RELEASE)"

    # Enable FAI repo in the nfsroot apt sources
    if [ -f /etc/fai/apt/sources.list ]; then
        sed -i 's/^#deb/deb/' /etc/fai/apt/sources.list
        log_info "Enabled FAI repo in nfsroot apt sources"
    fi

    cp "$REPO_ROOT/templates/grub.cfg.tpl" /etc/fai/grub.cfg
    log_info "Wrote /etc/fai/grub.cfg"
}

# ─── Build nfsroot ────────────────────────────────────────────────────────────

build_nfsroot() {
    log_step 4 8 "Building nfsroot..."

    if [ $SKIP_SETUP -eq 1 ]; then
        if [ -d /srv/fai/nfsroot/boot ]; then
            log_info "Skipping fai-setup (--skip-setup), reusing existing nfsroot"
            return
        else
            log_warn "--skip-setup specified but no nfsroot found, building anyway"
        fi
    fi

    mkdir -p "$LOG_DIR"

    # Use -e (expert) to skip NFS exports and log user creation — not needed for ISO builds
    log_info "Running fai-setup -ev (this takes several minutes)..."
    if [ $VERBOSE -eq 1 ]; then
        fai-setup -ev 2>&1 | tee "$LOG_DIR/fai-setup.log"
    else
        fai-setup -ev > "$LOG_DIR/fai-setup.log" 2>&1
    fi

    # Verify nfsroot was created
    if ! ls /srv/fai/nfsroot/boot/vmlinuz-* &>/dev/null; then
        log_fatal "fai-setup failed — no kernel found in nfsroot.\nCheck: $LOG_DIR/fai-setup.log"
    fi
    log_info "nfsroot built successfully"
}

# ─── Assemble Config Space ───────────────────────────────────────────────────

assemble_config_space() {
    log_step 5 8 "Assembling config space..."

    local config_dir="${WORKDIR}/config"

    # Clean working directory
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Clone upstream at the pinned commit
    log_info "Cloning upstream fai-config (ref: ${UPSTREAM_REF:0:12})..."
    local clone_args=(clone)
    # If ref looks like a branch/tag name, use --depth 1 for speed
    # If ref is a commit hash, we need a full clone then checkout
    if [[ "$UPSTREAM_REF" =~ ^[0-9a-f]{40}$ ]]; then
        if [ $VERBOSE -eq 1 ]; then
            git clone "$UPSTREAM_REPO" "${WORKDIR}/upstream" || \
                log_fatal "Failed to clone upstream fai-config"
            git -C "${WORKDIR}/upstream" checkout "$UPSTREAM_REF" || \
                log_fatal "Failed to checkout upstream ref: $UPSTREAM_REF"
        else
            git clone "$UPSTREAM_REPO" "${WORKDIR}/upstream" > /dev/null 2>&1 || \
                log_fatal "Failed to clone upstream fai-config"
            git -C "${WORKDIR}/upstream" checkout "$UPSTREAM_REF" > /dev/null 2>&1 || \
                log_fatal "Failed to checkout upstream ref: $UPSTREAM_REF"
        fi
    else
        if [ $VERBOSE -eq 1 ]; then
            git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "${WORKDIR}/upstream" || \
                log_fatal "Failed to clone upstream fai-config"
        else
            git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "${WORKDIR}/upstream" \
                > /dev/null 2>&1 || log_fatal "Failed to clone upstream fai-config"
        fi
    fi

    # Create assembled config space
    mkdir -p "$config_dir"/{class,debconf,disk_config,files,hooks,package_config,scripts/{FAIBASE,DEBIAN,GRUB_EFI,LAST}}

    # ── Cherry-pick from upstream ──
    log_info "Cherry-picking upstream files..."
    local upstream="${WORKDIR}/upstream"

    # Class files
    cp -a "$upstream/class/01-classes"       "$config_dir/class/"      2>/dev/null || true
    cp -a "$upstream/class/10-base-classes"  "$config_dir/class/"
    cp -a "$upstream/class/20-hwdetect.sh"   "$config_dir/class/"
    cp -a "$upstream/class/85-efi-classes"   "$config_dir/class/"
    cp -a "$upstream/class/FAIBASE.var"      "$config_dir/class/"
    cp -a "$upstream/class/DEBIAN.var"       "$config_dir/class/"

    # Debconf
    cp -a "$upstream/debconf/DEBIAN"         "$config_dir/debconf/"

    # Hooks
    cp -a "$upstream/hooks/instsoft.DEBIAN"    "$config_dir/hooks/"
    cp -a "$upstream/hooks/updatebase.DEBIAN"  "$config_dir/hooks/"
    cp -a "$upstream/hooks/savelog.LAST.sh"    "$config_dir/hooks/"      2>/dev/null || true

    # Package config
    cp -a "$upstream/package_config/DEBIAN"     "$config_dir/package_config/"
    cp -a "$upstream/package_config/DEBIAN.gpg" "$config_dir/package_config/" 2>/dev/null || true

    # Scripts
    cp -a "$upstream/scripts/FAIBASE/"*        "$config_dir/scripts/FAIBASE/"
    cp -a "$upstream/scripts/DEBIAN/"*         "$config_dir/scripts/DEBIAN/"
    cp -a "$upstream/scripts/GRUB_EFI/"*       "$config_dir/scripts/GRUB_EFI/"
    cp -a "$upstream/scripts/LAST/"*           "$config_dir/scripts/LAST/"

    # Files (template configs used by FAIBASE scripts — things like /etc/hosts, network config)
    if [ -d "$upstream/files" ]; then
        cp -a "$upstream/files/"* "$config_dir/files/" 2>/dev/null || true
    fi

    log_info "Upstream files cherry-picked"

    # ── Copy overlay on top ──
    log_info "Applying overlay..."
    cp -a "${REPO_ROOT}/overlay/"* "$config_dir/"
    log_info "Overlay applied"

    # ── Generate host map ──
    local host_map_content
    if [ "$BUILD_HOST_COUNT" -gt 0 ]; then
        log_info "Generating MAC-based hostname map ($BUILD_HOST_COUNT hosts)..."
        # shellcheck disable=SC2016 # Single quotes intentional — this is a code template, not executed here
        host_map_content='MAC=$(cat /sys/class/net/$(ip route show default 2>/dev/null | awk '"'"'/default/ {print $5}'"'"' | head -1)/address 2>/dev/null || echo "unknown")'$'\n'
        # shellcheck disable=SC2016
        host_map_content+='case "${MAC,,}" in'$'\n'
        local i
        for ((i = 0; i < BUILD_HOST_COUNT; i++)); do
            local h_hostname h_mac
            h_hostname="$(yq -r ".hosts[$i].hostname" "$CONFIG_FILE")"
            h_mac="$(yq -r ".hosts[$i].mac" "$CONFIG_FILE")"
            host_map_content+="    \"${h_mac,,}\") THIS_HOSTNAME=\"${h_hostname}\" ;;"$'\n'
        done
        host_map_content+="    *) THIS_HOSTNAME=\"${BUILD_DEFAULT_HOSTNAME}\" ;;"$'\n'
        host_map_content+='esac'
    else
        host_map_content="THIS_HOSTNAME=\"${BUILD_DEFAULT_HOSTNAME}\""
    fi

    # ── Generate extra packages (one per line) ──
    local extra_packages_lines=""
    if [ -n "$BUILD_EXTRA_PACKAGES" ]; then
        # Convert space-separated to newline-separated
        extra_packages_lines="$(echo "$BUILD_EXTRA_PACKAGES" | tr ' ' '\n' | grep -v '^$')"
    fi

    # ── Template replacements ──
    log_info "Running template replacements..."

    # Write LUKS passphrase to a file (avoids shell quoting issues in hook script)
    printf '%s' "$BUILD_LUKS_PASSPHRASE" > "$config_dir/.luks_passphrase"
    chmod 600 "$config_dir/.luks_passphrase"
    log_info "LUKS passphrase written to config space"

    template_replace_all "TEMPLATED_RELEASE_CLASS"         "$BUILD_RELEASE_CLASS"         "$config_dir"
    template_replace_all "TEMPLATED_RELEASE"               "$BUILD_RELEASE"               "$config_dir"
    template_replace_all "TEMPLATED_ADMIN_USER"            "$BUILD_ADMIN_USER"            "$config_dir"
    template_replace_all "TEMPLATED_ADMIN_PASSWORD_HASH"   "$BUILD_ADMIN_PASSWORD_HASH"   "$config_dir"
    template_replace_all "TEMPLATED_SSH_PUBLIC_KEY"         "$BUILD_SSH_KEY"               "$config_dir"
    template_replace_all "TEMPLATED_TIMEZONE"              "$BUILD_TIMEZONE"              "$config_dir"
    template_replace_all "TEMPLATED_LOCALE"                "$BUILD_LOCALE"                "$config_dir"
    template_replace_all "TEMPLATED_KEYBOARD"              "$BUILD_KEYBOARD"              "$config_dir"
    template_replace_all "TEMPLATED_DEFAULT_HOSTNAME"      "$BUILD_DEFAULT_HOSTNAME"      "$config_dir"
    template_replace_all "TEMPLATED_SWAP_SIZE"             "$BUILD_SWAP_SIZE"             "$config_dir"
    template_replace_all "TEMPLATED_EFI_SIZE"              "$BUILD_EFI_SIZE"              "$config_dir"
    template_replace_all "TEMPLATED_BOOT_SIZE"             "$BUILD_BOOT_SIZE"             "$config_dir"
    template_replace_all "TEMPLATED_ROOT_SIZE"             "$BUILD_ROOT_SIZE"             "$config_dir"

    # Multi-line replacements: host map and extra packages
    # For host map, replace the TEMPLATED_HOST_MAP line in the setup script
    local setup_script="$config_dir/scripts/CUSTOM_SETUP/10-setup"
    if [ -f "$setup_script" ]; then
        # Write host map to temp file, then use awk to replace the placeholder line
        local host_map_file="${WORKDIR}/host_map.tmp"
        echo "$host_map_content" > "$host_map_file"
        awk -v mapfile="$host_map_file" '
            /TEMPLATED_HOST_MAP/ {
                while ((getline line < mapfile) > 0) print line
                close(mapfile)
                next
            }
            { print }
        ' "$setup_script" > "${setup_script}.tmp" && mv "${setup_script}.tmp" "$setup_script"
    fi

    # For extra packages, replace the placeholder line
    local pkg_config="$config_dir/package_config/LUKS_SERVER"
    if [ -f "$pkg_config" ] && [ -n "$extra_packages_lines" ]; then
        local pkg_file="${WORKDIR}/extra_pkgs.tmp"
        echo "$extra_packages_lines" > "$pkg_file"
        awk -v pkgfile="$pkg_file" '
            /TEMPLATED_EXTRA_PACKAGES/ {
                while ((getline line < pkgfile) > 0) print line
                close(pkgfile)
                next
            }
            { print }
        ' "$pkg_config" > "${pkg_config}.tmp" && mv "${pkg_config}.tmp" "$pkg_config"
    elif [ -f "$pkg_config" ]; then
        # No extra packages — just remove the placeholder line
        sed -i '/TEMPLATED_EXTRA_PACKAGES/d' "$pkg_config"
    fi

    log_info "Template replacements complete"

    # ── Handle disk_device override ──
    if [ "$BUILD_DISK_DEVICE" != "auto" ]; then
        log_info "Overriding disk device: disk1 → $BUILD_DISK_DEVICE"
        local disk_conf="$config_dir/disk_config/LUKS_SERVER"
        sed -i "s/disk1/${BUILD_DISK_DEVICE}/g" "$disk_conf"
    fi

    # ── Post-install script ──
    if [ -n "$BUILD_POST_INSTALL" ]; then
        log_info "Including post-install script: $BUILD_POST_INSTALL"
        cp "$BUILD_POST_INSTALL" "$config_dir/scripts/CUSTOM_SETUP/99-custom"
        chmod +x "$config_dir/scripts/CUSTOM_SETUP/99-custom"
    fi

    # ── Set permissions ──
    find "$config_dir/scripts" -type f -exec chmod +x {} \;
    find "$config_dir/hooks" -type f -exec chmod +x {} \;
    find "$config_dir/class" -maxdepth 1 -type f -name '[0-9]*' -exec chmod +x {} \;
    log_info "Script permissions set"

    # ── Install assembled config into FAI location ──
    rm -rf "$FAI_CONFIG_TARGET"
    cp -a "$config_dir" "$FAI_CONFIG_TARGET"
    log_info "Config space installed to $FAI_CONFIG_TARGET"

    # Log the final file list for debugging
    if [ $VERBOSE -eq 1 ]; then
        echo -e "\n    Config space contents:"
        find "$FAI_CONFIG_TARGET" -type f | sort | while read -r f; do
            echo "      ${f#"$FAI_CONFIG_TARGET"/}"
        done
    fi
}

# ─── Build Package Mirror ────────────────────────────────────────────────────

build_mirror() {
    log_step 6 8 "Building package mirror..."

    if [ $SKIP_MIRROR -eq 1 ]; then
        if [ -d "$MIRROR_DIR/pool" ]; then
            log_info "Skipping fai-mirror (--skip-mirror), reusing existing mirror"
            return
        else
            log_warn "--skip-mirror specified but no mirror found, building anyway"
        fi
    fi

    mkdir -p "$LOG_DIR"

    # Remove old mirror
    rm -rf "$MIRROR_DIR"

    # Build the partial mirror
    # -b: skip nfsroot package list comparison (safer for ISO builds)
    # -v: verbose output
    log_info "Running fai-mirror (this takes several minutes)..."
    local mirror_exit=0
    if [ $VERBOSE -eq 1 ]; then
        fai-mirror -bv "$MIRROR_DIR" 2>&1 | tee "$LOG_DIR/fai-mirror.log" || mirror_exit=${PIPESTATUS[0]}
    else
        fai-mirror -bv "$MIRROR_DIR" > "$LOG_DIR/fai-mirror.log" 2>&1 || mirror_exit=$?
    fi

    if [ "$mirror_exit" -ne 0 ]; then
        log_warn "fai-mirror exited with code $mirror_exit, retrying with explicit class list..."
        fai-mirror -bv -cFAIBASE,DEBIAN,AMD64,GRUB_EFI,LUKS_SERVER,CUSTOM_SETUP,LAST "$MIRROR_DIR" > "$LOG_DIR/fai-mirror-retry.log" 2>&1 || \
            log_fatal "fai-mirror failed.\nCheck: $LOG_DIR/fai-mirror.log and $LOG_DIR/fai-mirror-retry.log"
    fi

    # Verify mirror contents
    if [ ! -d "$MIRROR_DIR/pool" ] || [ -z "$(find "$MIRROR_DIR/pool" -name '*.deb' 2>/dev/null | head -1)" ]; then
        log_fatal "Mirror appears empty — no .deb files found.\nCheck: $LOG_DIR/fai-mirror.log"
    fi

    local deb_count
    deb_count="$(find "$MIRROR_DIR/pool" -name '*.deb' | wc -l | tr -d ' ')"
    log_info "Mirror built: $deb_count packages"
}

# ─── Build ISO ────────────────────────────────────────────────────────────────

build_iso() {
    log_step 7 8 "Building ISO..."

    mkdir -p "$LOG_DIR"

    # Resolve output path
    local output_path
    output_path="$(cd "$(dirname "$BUILD_OUTPUT")" 2>/dev/null && pwd)/$(basename "$BUILD_OUTPUT")" || \
        output_path="$BUILD_OUTPUT"
    mkdir -p "$(dirname "$output_path")"

    # Remove existing ISO
    rm -f "$output_path"

    log_info "Running fai-cd..."
    if [ $VERBOSE -eq 1 ]; then
        fai-cd -m "$MIRROR_DIR" -g /etc/fai/grub.cfg "$output_path" 2>&1 | tee "$LOG_DIR/fai-cd.log"
    else
        fai-cd -m "$MIRROR_DIR" -g /etc/fai/grub.cfg "$output_path" > "$LOG_DIR/fai-cd.log" 2>&1
    fi

    # Verify ISO
    if [ ! -f "$output_path" ]; then
        log_fatal "fai-cd failed — no ISO produced.\nCheck: $LOG_DIR/fai-cd.log"
    fi

    local iso_size
    iso_size="$(du -h "$output_path" | cut -f1)"
    log_info "ISO created: $output_path ($iso_size)"

    # Generate SHA256
    local sha256_path="${output_path}.sha256"
    sha256sum "$output_path" > "$sha256_path"
    log_info "SHA256: $(cat "$sha256_path")"

    # Store for summary
    FINAL_ISO_PATH="$output_path"
    FINAL_ISO_SIZE="$iso_size"
    FINAL_ISO_SHA256="$(cut -d' ' -f1 "$sha256_path")"
}

# ─── Print Summary ───────────────────────────────────────────────────────────

print_summary() {
    log_step 8 8 "Build complete!"

    cat << EOF

${BOLD}═══════════════════════════════════════════════════════════════${NC}
${GREEN}${BOLD}  FAI ISO Build Summary${NC}
${BOLD}═══════════════════════════════════════════════════════════════${NC}

  ${BOLD}ISO:${NC}      $FINAL_ISO_PATH
  ${BOLD}Size:${NC}     $FINAL_ISO_SIZE
  ${BOLD}SHA256:${NC}   $FINAL_ISO_SHA256

  ${BOLD}Admin user:${NC}    $BUILD_ADMIN_USER
  ${BOLD}Hostname:${NC}      $BUILD_DEFAULT_HOSTNAME
  ${BOLD}LUKS:${NC}          Enabled (UEFI + GPT + LVM)
  ${BOLD}SSH:${NC}           Key-only authentication

${BOLD}───── Write to USB ─────${NC}

  ${BOLD}Linux:${NC}
    sudo dd if=${FINAL_ISO_PATH} of=/dev/sdX bs=4M status=progress

  ${BOLD}macOS:${NC}
    sudo dd if=${FINAL_ISO_PATH} of=/dev/rdiskN bs=4m

${BOLD}───── Post-Install Reminders ─────${NC}

  1. Change the LUKS passphrase on first boot:
     sudo cryptsetup luksChangeKey /dev/<partition>

  2. Change the admin password:
     passwd ${BUILD_ADMIN_USER}

EOF

    # Print hostname → MAC table if hosts were configured
    if [ "$BUILD_HOST_COUNT" -gt 0 ]; then
        echo -e "${BOLD}───── Host Map ─────${NC}\n"
        printf "  %-20s %s\n" "HOSTNAME" "MAC ADDRESS"
        printf "  %-20s %s\n" "────────" "───────────"
        local i
        for ((i = 0; i < BUILD_HOST_COUNT; i++)); do
            local h_hostname h_mac
            h_hostname="$(yq -r ".hosts[$i].hostname" "$CONFIG_FILE")"
            h_mac="$(yq -r ".hosts[$i].mac" "$CONFIG_FILE")"
            printf "  %-20s %s\n" "$h_hostname" "$h_mac"
        done
        printf "  %-20s %s\n" "$BUILD_DEFAULT_HOSTNAME" "(default / unmatched)"
        echo ""
    fi
}

# ─── Dry Run ──────────────────────────────────────────────────────────────────

do_dry_run() {
    echo -e "\n${BOLD}${BLUE}═══ Dry Run Summary ═══${NC}\n"

    echo -e "${BOLD}Resolved configuration:${NC}"
    echo "  release:           $BUILD_RELEASE"
    echo "  luks_passphrase:   ********"
    echo "  admin_user:        $BUILD_ADMIN_USER"
    echo "  admin_password:    ********"
    echo "  ssh_key:           $(echo "$BUILD_SSH_KEY" | head -1 | cut -c1-60)..."
    echo "  timezone:          $BUILD_TIMEZONE"
    echo "  locale:            $BUILD_LOCALE"
    echo "  keyboard:          $BUILD_KEYBOARD"
    echo "  disk_device:       $BUILD_DISK_DEVICE"
    echo "  efi_size:          $BUILD_EFI_SIZE"
    echo "  boot_size:         $BUILD_BOOT_SIZE"
    echo "  root_size:         $BUILD_ROOT_SIZE"
    echo "  swap_size:         ${BUILD_SWAP_SIZE}G"
    echo "  default_hostname:  $BUILD_DEFAULT_HOSTNAME"
    echo "  output:            $BUILD_OUTPUT"
    if [ -n "$BUILD_POST_INSTALL" ]; then
        echo "  post_install:      $BUILD_POST_INSTALL"
    fi
    if [ "$BUILD_HOST_COUNT" -gt 0 ]; then
        echo "  hosts:             $BUILD_HOST_COUNT entries"
    fi

    echo -e "\n${BOLD}Upstream files to cherry-pick:${NC}"
    echo "  class/01-classes, 10-base-classes, 20-hwdetect.sh, 85-efi-classes"
    echo "  class/FAIBASE.var, DEBIAN.var"
    echo "  debconf/DEBIAN"
    echo "  hooks/instsoft.DEBIAN, updatebase.DEBIAN, savelog.LAST.sh"
    echo "  package_config/DEBIAN, DEBIAN.gpg"
    echo "  scripts/FAIBASE/* (10-misc, 15-root-ssh-key, 20-removable_media)"
    echo "  scripts/DEBIAN/* (10-rootpw, 20-capabilities, 30-interface, 40-misc)"
    echo "  scripts/GRUB_EFI/* (UEFI bootloader installation)"
    echo "  scripts/LAST/* (final cleanup)"
    echo "  files/etc/ (all)"

    echo -e "\n${BOLD}Overlay files to apply:${NC}"
    find "${REPO_ROOT}/overlay" -type f | sort | while read -r f; do
        echo "  ${f#"${REPO_ROOT}"/overlay/}"
    done

    echo -e "\n${BOLD}Final class list:${NC}"
    echo "  DEFAULT LINUX AMD64 DHCPC FAIBASE DEBIAN ${BUILD_RELEASE_CLASS} GRUB_EFI LUKS_SERVER CUSTOM_SETUP LAST"

    echo -e "\n${GREEN}${BOLD}Dry run complete — config is valid.${NC}"
    exit 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    echo -e "\n${BOLD}fai-luks-builder${NC} — Debian LUKS ISO Builder\n"

    # Handle --clean early (before platform check)
    if [ $CLEAN -eq 1 ]; then
        do_clean
    fi

    # Platform detection and Docker routing (exits if macOS → Docker)
    detect_platform "$@"

    # Step 1: Install dependencies
    install_dependencies

    # Step 2: Parse and validate config
    parse_and_validate

    # Handle --dry-run
    if [ $DRY_RUN -eq 1 ]; then
        do_dry_run
    fi

    # Step 3: Write FAI system config
    write_fai_config

    # Step 4: Build nfsroot
    build_nfsroot

    # Step 5: Assemble config space
    assemble_config_space

    # Step 6: Build package mirror
    build_mirror

    # Step 7: Build ISO
    build_iso

    # Step 8: Print summary
    print_summary
}

main "$@"
