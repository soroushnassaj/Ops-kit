#!/usr/bin/env bash

set -uo pipefail

CONFIG_FILE="$HOME/.ops-kit.conf"
REPO_FULL=""
PROJECT_DIR=""

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required when not running as root."
fi

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
  return 0
}

save_config() {
  {
    printf 'REPO_FULL=%q\n' "$REPO_FULL"
    printf 'PROJECT_DIR=%q\n' "$PROJECT_DIR"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

ask() {
  local prompt="$1" __var="$2" def="${3:-}" reply
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " reply
    reply="${reply:-$def}"
  else
    read -r -p "$prompt: " reply
  fi
  printf -v "$__var" '%s' "$reply"
}

confirm() {
  local r
  read -r -p "$1 [y/N]: " r
  [[ "$r" =~ ^[Yy]$ ]]
}

dk() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    $SUDO docker "$@"
  fi
}

normalize_repo() {
  local r="$1"
  r="${r#https://github.com/}"
  r="${r#http://github.com/}"
  r="${r#git@github.com:}"
  r="${r%.git}"
  r="${r%/}"
  echo "$r"
}

ensure_repo_info() {
  load_config
  if [[ -z "$REPO_FULL" ]]; then
    local input
    ask "GitHub repo (USERNAME/REPO or full URL)" input
    REPO_FULL="$(normalize_repo "$input")"
  fi
  if [[ ! "$REPO_FULL" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    REPO_FULL=""
    die "Invalid repo format. Use USERNAME/REPO (for example: soroushnassaj/puffRoom)."
  fi
  if [[ -z "$PROJECT_DIR" ]]; then
    ask "Where should the project live" PROJECT_DIR "$PWD/${REPO_FULL##*/}"
  fi
  PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"
  PROJECT_DIR="$(realpath -m "$PROJECT_DIR")"
  save_config
}

require_project_dir() {
  ensure_repo_info
  [[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR (run step 3 first)."
}

step_system() {
  command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu (apt) only."
  info "Updating system packages..."
  $SUDO apt-get update
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  info "Installing git and curl..."
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl
  ok "System is up to date. $(git --version)"
}

step_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker found: $(docker --version)"
  else
    info "Docker not found. Installing via the official script..."
    command -v curl >/dev/null 2>&1 || $SUDO apt-get install -y curl
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    $SUDO sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    $SUDO systemctl enable --now docker 2>/dev/null || true
    ok "Docker installed: $(docker --version)"
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose found: $(docker compose version)"
  else
    info "Docker Compose plugin not found. Installing..."
    $SUDO apt-get install -y docker-compose-plugin
    docker compose version >/dev/null 2>&1 || die "Could not install the Docker Compose plugin."
    ok "Docker Compose installed: $(docker compose version)"
  fi

  if [[ $EUID -ne 0 ]]; then
    local me
    me="$(id -un)"
    if [[ " $(id -nG "$me") " != *" docker "* ]]; then
      $SUDO usermod -aG docker "$me"
      warn "Added '$me' to the 'docker' group. Log out and back in to use docker without sudo."
      warn "(Until then, this script uses sudo for docker automatically.)"
    fi
  fi
}

ssh_ok() {
  local out
  out="$(ssh -o BatchMode=yes -T "$1" 2>&1 || true)"
  grep -q "successfully authenticated" <<<"$out"
}

register_deploy_key() {
  local repo="$1" pubfile="$2" token="${GITHUB_TOKEN:-}" pub resp http
  if [[ -z "$token" ]]; then
    read -r -s -p "GitHub token (input hidden): " token
    echo
  fi
  [[ -n "$token" ]] || die "Empty token."

  pub="$(cut -d' ' -f1,2 "$pubfile")"
  resp="$(mktemp)"
  info "Registering the deploy key on GitHub (read-only)..."
  http="$(curl -s -o "$resp" -w '%{http_code}' \
    -X POST "https://api.github.com/repos/${repo}/keys" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "{\"title\":\"server-$(hostname)\",\"key\":\"${pub}\",\"read_only\":true}")"

  case "$http" in
    201) ok "Deploy key added (read-only)." ;;
    422) warn "GitHub says the key may already exist. Continuing."
         cat "$resp"; echo ;;
    401) rm -f "$resp"; die "Invalid token (401)." ;;
    403) cat "$resp"; rm -f "$resp"
         die "Token lacks permission (403). It needs 'Administration: Read and write' on this repo (or the classic 'repo' scope)." ;;
    404) rm -f "$resp"
         die "Repo not found (404). Check the repo name and that the token has access to it." ;;
    *)   cat "$resp"; rm -f "$resp"; die "Unexpected response from GitHub: HTTP $http" ;;
  esac
  rm -f "$resp"
}

step_repo() {
  ensure_repo_info
  command -v git >/dev/null 2>&1 || die "git is not installed. Run step 1 first."

  local repo_name="${REPO_FULL##*/}"
  local host_alias="github-${repo_name}"
  local key="$HOME/.ssh/deploy_${repo_name}"
  local cfg="$HOME/.ssh/config"

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$cfg"; chmod 600 "$cfg"

  if [[ -f "$key" ]]; then
    info "SSH key already exists: $key"
  else
    info "Generating ed25519 key..."
    ssh-keygen -t ed25519 -C "deploy-${repo_name}@$(hostname)" -f "$key" -N "" -q
  fi
  chmod 600 "$key"

  if grep -q "^Host ${host_alias}\$" "$cfg"; then
    info "SSH config entry '${host_alias}' already exists."
  else
    info "Adding SSH config entry '${host_alias}'..."
    cat >> "$cfg" <<EOF

Host ${host_alias}
  HostName github.com
  User git
  IdentityFile ${key}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  fi

  if ssh_ok "$host_alias"; then
    ok "SSH access to the repo already works."
  else
    if confirm "Register the deploy key automatically with a GitHub token?"; then
      command -v curl >/dev/null 2>&1 || die "curl is required. Run step 1 first."
      register_deploy_key "$REPO_FULL" "${key}.pub"
    else
      echo
      echo "Add this public key to GitHub (leave 'Allow write access' UNCHECKED):"
      echo "  https://github.com/${REPO_FULL}/settings/keys/new"
      echo
      cat "${key}.pub"
      echo
      read -r -p "Press Enter after you have added the key... "
    fi
    sleep 2
    ssh_ok "$host_alias" || die "SSH authentication failed. Check that the key was added to ${REPO_FULL}."
    ok "SSH authentication works."
  fi

  if [[ -d "$PROJECT_DIR/.git" ]]; then
    info "Repo already cloned at $PROJECT_DIR. Pulling latest changes..."
    git -C "$PROJECT_DIR" pull
  else
    info "Cloning into $PROJECT_DIR ..."
    mkdir -p "$(dirname "$PROJECT_DIR")"
    git clone "git@${host_alias}:${REPO_FULL}.git" "$PROJECT_DIR"
  fi
  ok "Repository is ready at $PROJECT_DIR"
}

read_multiline() {
  ENV_CONTENT=""
  local line
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    ENV_CONTENT+="$line"$'\n'
  done
}

resolve_target_dir() {
  local rel="$1" base
  rel="${rel#./}"; rel="${rel#/}"; rel="${rel%/}"
  base="$(basename "$PROJECT_DIR")"

  if [[ -z "$rel" || "$rel" == "." ]]; then
    echo "$PROJECT_DIR"; return 0
  fi
  [[ "$rel" == *..* ]] && return 1

  if [[ ! -d "$PROJECT_DIR/$rel" ]]; then
    if [[ "$rel" == "$base" ]]; then
      echo "$PROJECT_DIR"; return 0
    elif [[ "$rel" == "$base/"* ]]; then
      rel="${rel#"$base"/}"
    fi
  fi
  echo "$PROJECT_DIR/$rel"
}

step_env() {
  require_project_dir

  local count i fname rel target_dir target_file
  ask "How many .env files do you have" count
  [[ "$count" =~ ^[0-9]+$ ]] || die "Please enter a number."

  for ((i = 1; i <= count; i++)); do
    echo
    info "=== .env file $i of $count ==="
    echo "Paste the content below. Finish with a line containing only EOF (or press Ctrl+D)."
    read_multiline
    if [[ -z "$ENV_CONTENT" ]]; then
      warn "Empty content. Skipping this file."
      continue
    fi

    ask "File name" fname ".env"
    ask "Directory from the project root (e.g. frontend or backend/api, '.' for root)" rel "."

    if ! target_dir="$(resolve_target_dir "$rel")"; then
      warn "Invalid path '$rel'. Skipping this file."
      continue
    fi

    if [[ ! -d "$target_dir" ]]; then
      if confirm "Directory '$target_dir' does not exist. Create it?"; then
        mkdir -p "$target_dir"
      else
        warn "Skipped."
        continue
      fi
    fi

    target_file="$target_dir/$fname"
    if [[ -f "$target_file" ]]; then
      cp "$target_file" "${target_file}.bak.$(date +%s)"
      warn "Existing file backed up."
    fi
    printf '%s' "$ENV_CONTENT" > "$target_file"
    chmod 600 "$target_file"
    ok "Saved: $target_file"
  done
}

has_compose_file() {
  local f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [[ -f "$PROJECT_DIR/$f" ]] && return 0
  done
  return 1
}

step_build() {
  require_project_dir
  warn_low_memory
  has_compose_file || die "No compose file found in $PROJECT_DIR."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run step 2 first."
  cd "$PROJECT_DIR"
  info "Building images..."
  dk compose build
  ok "Build finished."
}

step_up() {
  require_project_dir
  has_compose_file || die "No compose file found in $PROJECT_DIR."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run step 2 first."
  cd "$PROJECT_DIR"
  info "Starting containers..."
  dk compose up -d
  echo
  dk compose ps
  ok "Containers are up."
}

swap_total_kb() { awk '/^SwapTotal:/ {print $2}' /proc/meminfo; }
mem_total_kb()  { awk '/^MemTotal:/ {print $2}' /proc/meminfo; }

warn_low_memory() {
  if [[ "$(swap_total_kb)" -eq 0 && "$(mem_total_kb)" -lt 1500000 ]]; then
    warn "Low memory (< 1.5 GB RAM) and no swap. The build may time out or get killed."
    warn "Run menu option 9 (Check / fix swap) first."
  fi
  return 0
}

step_swap() {
  local swapfile="/swapfile" size num unit need_mb avail_mb total_kb oom active

  info "Memory and swap status:"
  free -h
  echo
  swapon --show 2>/dev/null || true
  echo

  info "Recent out-of-memory kills (kernel log):"
  oom="$($SUDO dmesg 2>/dev/null | grep -i -E 'out of memory|killed process' | tail -5 || true)"
  if [[ -n "$oom" ]]; then
    warn "Found OOM kills (processes were killed because memory ran out):"
    echo "$oom"
  else
    ok "None found."
  fi
  echo

  total_kb="$(swap_total_kb)"
  if [[ "$total_kb" -gt 0 ]]; then
    ok "Swap is active: $((total_kb / 1024)) MiB."
    active="$(swapon --show=NAME --noheadings 2>/dev/null || true)"
    if grep -qx "$swapfile" <<<"$active" && ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
      warn "$swapfile is active but missing from /etc/fstab, so it would be lost after a reboot."
      if confirm "Add it to /etc/fstab now?"; then
        echo "$swapfile none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null
        ok "Added to /etc/fstab."
      fi
    fi
    return 0
  fi

  warn "No active swap. Builds on low-memory servers may time out or get killed."
  if ! confirm "Create a swap file now?"; then
    return 0
  fi

  ask "Swap size (e.g. 512M, 1G, 2G, 4G)" size "2G"
  [[ "$size" =~ ^([0-9]+)([MmGg])$ ]] || die "Invalid size. Use a number followed by M or G, for example 2G."
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]^^}"
  if [[ "$unit" == "G" ]]; then need_mb=$((num * 1024)); else need_mb=$num; fi
  [[ "$need_mb" -ge 128 ]] || die "Size too small (minimum 128M)."
  size="${num}${unit}"

  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if [[ "$avail_mb" -lt $((need_mb + 512)) ]]; then
    die "Not enough free disk space (${avail_mb} MiB free; need ${need_mb} MiB plus ~512 MiB headroom)."
  fi

  if [[ -e "$swapfile" ]]; then
    info "$swapfile already exists. Trying to activate it..."
    if $SUDO swapon "$swapfile" 2>/dev/null; then
      ok "Activated the existing $swapfile (size unchanged)."
    else
      warn "The existing $swapfile could not be activated. Recreating it..."
      $SUDO rm -f "$swapfile"
    fi
  fi

  if [[ "$(swap_total_kb)" -eq 0 ]]; then
    info "Creating a ${size} swap file at $swapfile ..."
    if ! $SUDO fallocate -l "$size" "$swapfile" 2>/dev/null; then
      warn "fallocate failed on this filesystem; falling back to dd (slower)..."
      $SUDO dd if=/dev/zero of="$swapfile" bs=1M count="$need_mb" status=progress
    fi
    $SUDO chmod 600 "$swapfile"
    $SUDO mkswap "$swapfile" >/dev/null
    $SUDO swapon "$swapfile"
  fi

  if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    echo "$swapfile none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null
    info "Added $swapfile to /etc/fstab (persists after reboot)."
  fi

  echo
  [[ "$(swap_total_kb)" -gt 0 ]] || die "Swap is still not active. Check the output above."
  free -h
  ok "Swap is active and persistent."
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

need_openssl() {
  command -v openssl >/dev/null 2>&1 && return 0
  $SUDO apt-get install -y openssl
}

ensure_certbot() {
  command -v certbot >/dev/null 2>&1 && return 0
  info "Installing certbot..."
  $SUDO apt-get update
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
}

ssl_get() {
  local domain extra email public_ip resolved listen
  local args=()

  ask "Domain name (must already point to this server, e.g. example.com)" domain
  valid_domain "$domain" || die "Invalid domain name. A certificate cannot be issued for a bare IP address."
  ask "Extra domain such as www.$domain (leave empty for none)" extra
  if [[ -n "$extra" ]]; then
    valid_domain "$extra" || die "Invalid extra domain name."
  fi
  ask "Email for expiry notices" email
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid email address."

  command -v curl >/dev/null 2>&1 || $SUDO apt-get install -y curl
  public_ip="$(curl -4 -fsS -m 10 https://api.ipify.org 2>/dev/null || true)"
  resolved="$(getent ahostsv4 "$domain" | awk 'NR==1 {print $1}' || true)"
  if [[ -z "$resolved" ]]; then
    die "$domain does not resolve to any IP yet. Create the DNS A record first and wait for it to propagate."
  fi
  if [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
    warn "$domain points to $resolved but this server's public IP is $public_ip."
    confirm "Continue anyway?" || die "Aborted."
  fi

  listen="$($SUDO ss -ltn 2>/dev/null || true)"
  if grep -qE ':80[[:space:]]' <<<"$listen"; then
    die "Port 80 is already in use. Stop whatever is using it (for example a container publishing port 80) and try again."
  fi

  ensure_certbot
  args=(certonly --standalone --non-interactive --agree-tos --no-eff-email -m "$email" -d "$domain")
  if [[ -n "$extra" ]]; then
    args+=(-d "$extra")
  fi

  info "Requesting the certificate (port 80 must be reachable from the internet)..."
  $SUDO certbot "${args[@]}"

  ok "Certificate issued."
  echo "  Certificate: /etc/letsencrypt/live/$domain/fullchain.pem"
  echo "  Private key: /etc/letsencrypt/live/$domain/privkey.pem"
  echo "  Automatic renewal is handled by the certbot systemd timer."
  echo
  if confirm "Test automatic renewal now (dry run)?"; then
    $SUDO certbot renew --dry-run
  fi
}

ssl_import() {
  local domain method src_cert src_key host rcert rkey tmp dest c k
  ask "Domain name this certificate belongs to (used as the folder name)" domain
  valid_domain "$domain" || die "Invalid domain name."
  need_openssl

  dest="/etc/ssl/ops-kit/$domain"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "  1) Files already on this server"
  echo "  2) Download from another server over SSH (scp)"
  echo "  3) Paste the PEM text"
  ask "Choose a method" method "1"

  case "$method" in
    1)
      ask "Path to the certificate (fullchain) file" src_cert
      ask "Path to the private key file" src_key
      src_cert="${src_cert/#\~/$HOME}"
      src_key="${src_key/#\~/$HOME}"
      $SUDO test -f "$src_cert" || die "File not found: $src_cert"
      $SUDO test -f "$src_key" || die "File not found: $src_key"
      $SUDO cp -L "$src_cert" "$tmp/fullchain.pem"
      $SUDO cp -L "$src_key" "$tmp/privkey.pem"
      $SUDO chown -R "$(id -u):$(id -g)" "$tmp"
      ;;
    2)
      warn "The SSH user must be able to read both files on the old server (use root, or copy them somewhere readable first)."
      ask "SSH login of the old server (for example root@1.2.3.4)" host
      [[ "$host" =~ ^[A-Za-z0-9._@-]+$ ]] || die "Invalid SSH login."
      ask "Certificate path on the old server" rcert "/etc/letsencrypt/live/$domain/fullchain.pem"
      ask "Private key path on the old server" rkey "/etc/letsencrypt/live/$domain/privkey.pem"
      [[ "$rcert" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid certificate path."
      [[ "$rkey" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid key path."
      scp -o StrictHostKeyChecking=accept-new "$host:$rcert" "$tmp/fullchain.pem"
      scp -o StrictHostKeyChecking=accept-new "$host:$rkey" "$tmp/privkey.pem"
      ;;
    3)
      echo "Paste the certificate (fullchain PEM). Finish with a line containing only EOF."
      read_multiline
      printf '%s' "$ENV_CONTENT" > "$tmp/fullchain.pem"
      echo "Paste the private key. Finish with a line containing only EOF."
      read_multiline
      printf '%s' "$ENV_CONTENT" > "$tmp/privkey.pem"
      ;;
    *)
      die "Invalid method."
      ;;
  esac

  openssl x509 -in "$tmp/fullchain.pem" -noout >/dev/null 2>&1 || die "The certificate is not a valid PEM certificate."
  openssl pkey -in "$tmp/privkey.pem" -passin pass: -noout >/dev/null 2>&1 || die "The private key is invalid or password-protected."
  c="$(openssl x509 -in "$tmp/fullchain.pem" -noout -pubkey | openssl sha256)"
  k="$(openssl pkey -in "$tmp/privkey.pem" -passin pass: -pubout | openssl sha256)"
  [[ "$c" == "$k" ]] || die "The private key does not match the certificate."
  if ! openssl x509 -in "$tmp/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
    warn "This certificate has already expired."
  fi

  $SUDO mkdir -p "$dest"
  $SUDO install -m 644 -o root -g root "$tmp/fullchain.pem" "$dest/fullchain.pem"
  $SUDO install -m 600 -o root -g root "$tmp/privkey.pem" "$dest/privkey.pem"

  ok "Certificate imported and verified (key matches)."
  openssl x509 -in "$dest/fullchain.pem" -noout -subject -enddate 2>/dev/null || $SUDO openssl x509 -in "$dest/fullchain.pem" -noout -subject -enddate
  echo "  Certificate: $dest/fullchain.pem"
  echo "  Private key: $dest/privkey.pem"
  warn "Imported certificates are not renewed automatically. Renew it where it was issued, or issue a new one here with option 1."
}

ssl_pack() {
  local domain src tmp out
  ask "Domain name of the certificate to pack" domain
  valid_domain "$domain" || die "Invalid domain name."

  if $SUDO test -f "/etc/letsencrypt/live/$domain/fullchain.pem"; then
    src="/etc/letsencrypt/live/$domain"
  elif $SUDO test -f "/etc/ssl/ops-kit/$domain/fullchain.pem"; then
    src="/etc/ssl/ops-kit/$domain"
  else
    die "No certificate for $domain found on this server."
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  out="$HOME/ssl-${domain}-$(date +%Y%m%d).tar.gz"
  $SUDO cp -L "$src/fullchain.pem" "$src/privkey.pem" "$tmp/"
  $SUDO chown -R "$(id -u):$(id -g)" "$tmp"
  tar -czf "$out" -C "$tmp" fullchain.pem privkey.pem
  chmod 600 "$out"

  ok "Created $out"
  echo "Copy it to the new server with:"
  echo "  scp $out USER@NEW_SERVER_IP:~/"
  echo "Then unpack it there and run option 2 (method 1) of this menu entry."
  warn "The archive contains the private key. Delete it after the transfer."
}

ssl_list() {
  local dirs d found=0
  need_openssl
  dirs="$($SUDO sh -c 'ls -d /etc/letsencrypt/live/*/ /etc/ssl/ops-kit/*/ 2>/dev/null' || true)"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    d="${d%/}"
    if $SUDO test -f "$d/fullchain.pem"; then
      found=1
      echo "$d"
      $SUDO openssl x509 -in "$d/fullchain.pem" -noout -subject -enddate | sed 's/^/    /'
    fi
  done <<<"$dirs"
  if [[ "$found" -eq 0 ]]; then
    info "No certificates found."
  fi
}

step_ssl() {
  local choice
  echo "  1) Get a free certificate (Let's Encrypt, needs a domain)"
  echo "  2) Import an existing certificate (files, scp, or paste)"
  echo "  3) Pack a certificate to move it to another server"
  echo "  4) Show installed certificates and expiry dates"
  echo "  0) Back"
  ask "Choose" choice
  case "$choice" in
    1) ssl_get ;;
    2) ssl_import ;;
    3) ssl_pack ;;
    4) ssl_list ;;
    0|"") return 0 ;;
    *) die "Invalid choice." ;;
  esac
}

step_all() {
  info ">>> Step 1/6: system update & git"
  step_system
  info ">>> Step 2/6: Docker"
  step_docker
  info ">>> Step 3/6: repository"
  step_repo
  info ">>> Step 4/6: .env files"
  step_env
  info ">>> Step 5/6: docker compose build"
  step_build
  info ">>> Step 6/6: docker compose up -d"
  step_up
  ok "All steps completed."
}

run_action() {
  ( set -e; "$@" )
  local rc=$?
  echo
  if [[ $rc -eq 0 ]]; then
    ok "Finished."
  else
    warn "Step failed (exit code $rc)."
  fi
}

show_menu() {
  load_config
  echo
  echo "=========================================="
  echo "  ops-kit - server & project setup"
  echo "=========================================="
  if [[ -n "$REPO_FULL" ]]; then
    echo "  Repo:    $REPO_FULL"
    echo "  Project: $PROJECT_DIR"
    echo "------------------------------------------"
  fi
  echo "  1) Update system & install git"
  echo "  2) Check / install Docker"
  echo "  3) Connect to GitHub repo & clone"
  echo "  4) Set up .env files"
  echo "  5) Docker compose build"
  echo "  6) Docker compose up -d"
  echo "  7) Run ALL steps (1-6)"
  echo "  8) Change repo / project path"
  echo "  9) Check / fix swap (low-memory servers)"
  echo " 10) SSL certificate (get / import / move)"
  echo "  0) Exit"
  echo "=========================================="
}

main() {
  local choice
  while true; do
    show_menu
    read -r -p "Select an option: " choice
    echo
    case "$choice" in
      1) run_action step_system ;;
      2) run_action step_docker ;;
      3) run_action step_repo ;;
      4) run_action step_env ;;
      5) run_action step_build ;;
      6) run_action step_up ;;
      7) run_action step_all ;;
      8) rm -f "$CONFIG_FILE"; REPO_FULL=""; PROJECT_DIR=""; run_action ensure_repo_info ;;
      9) run_action step_swap ;;
      10) run_action step_ssl ;;
      0|q|Q) echo "Bye."; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
    echo
    read -r -p "Press Enter to return to the menu... " _
  done
}

main
