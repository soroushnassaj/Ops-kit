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
      0|q|Q) echo "Bye."; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
    echo
    read -r -p "Press Enter to return to the menu... " _
  done
}

main
