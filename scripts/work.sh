#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/work.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE" >&2
  exit 1
fi

IMAGE_REBUILT=0

load_config() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    export "$key=$value"
  done < "$CONFIG_FILE"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_git_repo() {
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

is_toolkit_git_checkout() {
  local root="${1:-$(toolkit_root)}"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

toolkit_root() {
  echo "$REPO_ROOT/$TOOLKIT_PATH"
}

toolkit_cmd() {
  local root
  root="$(toolkit_root)"
  (cd "$root" && bash "$@")
}

ensure_toolkit_line_endings() {
  local root
  root="$(toolkit_root)"
  [[ -f "$root/bin/up" ]] || return 0
  if ! grep -q $'\r' "$root/bin/up"; then
    return 0
  fi

  echo "Detected CRLF in toolkit scripts. Normalizing checkout to LF..."
  if ! is_toolkit_git_checkout "$root"; then
    echo "Toolkit checkout is invalid while CRLF scripts are present. Re-bootstrapping toolkit..."
    rm -rf "$root"
    ensure_toolkit_present
    root="$(toolkit_root)"
    [[ -f "$root/bin/up" ]] || die "Toolkit bootstrap failed; bin/up is missing."
    if ! grep -q $'\r' "$root/bin/up"; then
      return 0
    fi
  fi

  git -C "$root" config core.autocrlf false || die "Failed to set toolkit core.autocrlf=false."
  git -C "$root" config core.eol lf || die "Failed to set toolkit core.eol=lf."
  git -C "$root" reset --hard >/dev/null || die "Failed to normalize toolkit checkout to LF."
}

set_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    printf "\n%s=%s\n" "$key" "$value" >>"$file"
  fi
}

delete_config_key() {
  local file="$1"
  local key="$2"
  sed -i -E "/^${key}=.*/d" "$file"
}

set_work_config_value() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$CONFIG_FILE"; then
    sed -i -E "s#^${key}=.*#${key}=${value}#g" "$CONFIG_FILE"
  else
    printf "\n%s=%s\n" "$key" "$value" >>"$CONFIG_FILE"
  fi
}

ensure_prerequisites() {
  have_cmd docker || die "docker not found in PATH."
  have_cmd git || die "git not found in PATH."
  have_cmd bash || die "bash not found in PATH."
  docker info >/dev/null 2>&1 || die "docker daemon is not running."
}

target_image_ref() {
  echo "sharelatex/sharelatex:${OVERLEAF_IMAGE_TAG}"
}

base_image_ref() {
  echo "sharelatex/sharelatex:${BASE_OVERLEAF_IMAGE_TAG:-$OVERLEAF_IMAGE_TAG}"
}

cleanup_overleaf_images() {
  local target_image base_image keep_base auto_prune ref
  target_image="$(target_image_ref)"
  base_image="$(base_image_ref)"
  keep_base="${KEEP_BASE_OVERLEAF_IMAGE:-0}"
  auto_prune="${AUTO_PRUNE_SHARELATEX_IMAGES:-1}"

  [[ "$auto_prune" == "1" ]] || return 0

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ "$ref" == "$target_image" ]] && continue
    if [[ "$keep_base" == "1" && "$ref" == "$base_image" ]]; then
      continue
    fi
    docker rmi "$ref" >/dev/null 2>&1 || true
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' | awk '$1 ~ /^sharelatex\/sharelatex:/ {print $1}')
}

image_has_required_tex_baseline() {
  local image="$1"
  local check required_scheme check_files
  required_scheme="${TEXLIVE_REQUIRED_SCHEME:-}"
  check_files="${TEXLIVE_CHECK_FILES:-elsarticle.cls}"
  if [[ -n "$required_scheme" ]]; then
    if ! docker run --rm --entrypoint sh "$image" -lc "tlmgr info '$required_scheme' 2>/dev/null | grep -Eiq 'installed:[[:space:]]+yes'"; then
      return 1
    fi
  fi
  for check in $check_files; do
    if ! docker run --rm --entrypoint sh "$image" -lc "kpsewhich '$check' >/dev/null 2>&1"; then
      return 1
    fi
  done
  return 0
}

install_tex_packages_into_image() {
  local base_image="$1"
  local target_image="$2"
  local package_list="$3"
  local builder
  builder="latex-local-overleaf-build-$$"

  if ! docker image inspect "$base_image" >/dev/null 2>&1; then
    docker pull "$base_image" >/dev/null
  fi

  docker run -d --name "$builder" --entrypoint sh "$base_image" -lc "while true; do sleep 3600; done" >/dev/null
  if ! docker exec -e WORK_TEX_PACKAGES="$package_list" "$builder" bash -lc \
    "set -euo pipefail; year=\$(tlmgr --version | awk '/TeX Live/{print \$NF; exit}'); repo=\"https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/\${year}/tlnet-final\"; tlmgr option repository \"\$repo\" >/dev/null; if [[ -n \"\${WORK_TEX_PACKAGES:-}\" ]]; then tlmgr install \${WORK_TEX_PACKAGES} >/tmp/texlive-install.log 2>&1 || { tail -n 200 /tmp/texlive-install.log; exit 1; }; fi"; then
    docker exec "$builder" bash -lc "test -f /tmp/texlive-install.log && tail -n 200 /tmp/texlive-install.log || true" || true
    docker rm -f "$builder" >/dev/null 2>&1 || true
    die "Failed to install TeX packages into image."
  fi

  docker commit --change 'ENTRYPOINT ["/sbin/my_init"]' "$builder" "$target_image" >/dev/null
  docker rm -f "$builder" >/dev/null
}

resolve_packages_for_missing_file() {
  local image="$1"
  local missing_file="$2"
  docker run --rm --entrypoint bash -e WORK_MISSING_FILE="$missing_file" "$image" -lc \
    "set -euo pipefail; year=\$(tlmgr --version | awk '/TeX Live/{print \$NF; exit}'); repo=\"https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/\${year}/tlnet-final\"; tlmgr option repository \"\$repo\" >/dev/null; tlmgr search --global --file \"/\${WORK_MISSING_FILE}\" 2>/dev/null | awk -F: '/^[^[:space:]][^:]*:$/ {print \$1}'" \
    | tr -d '\r'
}

ensure_overleaf_image() {
  local target_image base_image check_files required_scheme
  target_image="$(target_image_ref)"
  base_image="$(base_image_ref)"
  check_files="${TEXLIVE_CHECK_FILES:-elsarticle.cls}"
  required_scheme="${TEXLIVE_REQUIRED_SCHEME:-}"

  if docker image inspect "$target_image" >/dev/null 2>&1; then
    if image_has_required_tex_baseline "$target_image"; then
      return 0
    fi
    echo "Image $target_image exists but is missing required TeX files. Repairing..."
    base_image="$target_image"
  fi

  echo "Building hardened Overleaf image: $target_image"
  echo "Base image: $base_image"
  echo "TeX packages: ${TEXLIVE_PACKAGES:-<none>}"
  echo "Required TeX scheme: ${required_scheme:-<none>}"
  echo "TeX check files: $check_files"

  install_tex_packages_into_image "$base_image" "$target_image" "${TEXLIVE_PACKAGES:-}"
  image_has_required_tex_baseline "$target_image" || die "Built image missing required TeX baseline (scheme/files)."
  IMAGE_REBUILT=1
  echo "Built image: $target_image"
}

ensure_toolkit_present() {
  local root
  root="$(toolkit_root)"
  if [[ -d "$root" ]]; then
    if is_toolkit_git_checkout "$root"; then
      git -C "$root" config core.autocrlf false
      git -C "$root" config core.eol lf
      [[ -f "$root/bin/up" ]] && return 0
      echo "Toolkit checkout found but bin/up is missing. Re-bootstrapping toolkit..."
      rm -rf "$root"
    elif [[ -f "$root/bin/up" ]]; then
      echo "Toolkit files found, but checkout is not a valid git worktree. Re-bootstrapping toolkit..."
      rm -rf "$root"
    elif [[ -z "$(ls -A "$root")" ]]; then
      rmdir "$root"
    else
      die "Toolkit path exists but is not a valid toolkit checkout: $root"
    fi
  fi

  echo "Toolkit not found at $TOOLKIT_PATH. Bootstrapping..."

  if is_git_repo; then
    if [[ -f "$REPO_ROOT/.gitmodules" ]] && git -C "$REPO_ROOT" config --file .gitmodules --get-regexp path | grep -q "$TOOLKIT_PATH"; then
      git -C "$REPO_ROOT" submodule update --init --recursive "$TOOLKIT_PATH"
    else
      git -C "$REPO_ROOT" submodule add "$TOOLKIT_REPO" "$TOOLKIT_PATH"
    fi
  else
    git clone "$TOOLKIT_REPO" "$root"
  fi

  git -C "$root" fetch --all --tags
  git -C "$root" checkout "$TOOLKIT_REF"
  git -C "$root" config core.autocrlf false
  git -C "$root" config core.eol lf
  [[ -f "$root/bin/up" ]] || die "Toolkit bootstrap failed; bin/up is missing."
}

ensure_toolkit_config() {
  local root rc_file override_file variables_file app_name
  root="$(toolkit_root)"
  rc_file="$root/config/overleaf.rc"
  override_file="$root/config/docker-compose.override.yml"
  variables_file="$root/config/variables.env"
  app_name="${OVERLEAF_APP_NAME:-Overleaf}"

  mkdir -p "$root/config"
  mkdir -p "$root/data/logs"

  if [[ ! -f "$rc_file" || ! -f "$variables_file" ]]; then
    toolkit_cmd bin/init
  fi

  if [[ ! -f "$variables_file" && -f "$root/lib/config-seed/variables.env" ]]; then
    cp "$root/lib/config-seed/variables.env" "$variables_file"
  fi

  set_config_value "$rc_file" "OVERLEAF_LISTEN_IP" "$OVERLEAF_HOST"
  set_config_value "$rc_file" "OVERLEAF_PORT" "$OVERLEAF_PORT"
  delete_config_key "$rc_file" "OVERLEAF_LOG_PATH"
  set_config_value "$rc_file" "SERVER_PRO" "false"
  set_config_value "$rc_file" "SIBLING_CONTAINERS_ENABLED" "false"
  set_config_value "$variables_file" "OVERLEAF_APP_NAME" "\"$app_name\""
  set_config_value "$variables_file" "OVERLEAF_NAV_TITLE" "\"$app_name\""

  cat >"$override_file" <<'EOF'
volumes:
  overleaf-data:
  mongo-data:
  redis-data:

services:
  sharelatex:
    volumes:
      - overleaf-data:/var/lib/overleaf

  mongo:
    volumes:
      - mongo-data:/data/db

  redis:
    volumes:
      - redis-data:/data
EOF

  printf "%s\n" "$OVERLEAF_IMAGE_TAG" >"$root/config/version"
}

wait_for_ui() {
  local url="$1"
  local retries=90
  local i
  for ((i = 1; i <= retries; i++)); do
    if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

open_browser() {
  local url="$1"
  [[ "${WORK_NO_OPEN:-0}" == "1" ]] && return 0
  if have_cmd xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 || true
  elif have_cmd open; then
    open "$url" >/dev/null 2>&1 || true
  fi
}

cmd_start() {
  local url
  url="http://${OVERLEAF_HOST}:${OVERLEAF_PORT}${OVERLEAF_OPEN_PATH}"
  ensure_prerequisites
  ensure_overleaf_image
  ensure_toolkit_present
  ensure_toolkit_line_endings
  ensure_toolkit_config
  if ! toolkit_cmd bin/up -d; then
    echo "Initial startup failed. Retrying with clean compose recreate..."
    toolkit_cmd bin/docker-compose down || true
    toolkit_cmd bin/up -d
  fi
  if [[ "$IMAGE_REBUILT" == "1" ]]; then
    toolkit_cmd bin/docker-compose up -d --force-recreate sharelatex
  fi
  if ! wait_for_ui "$url"; then
    echo "UI not ready on first attempt, retrying startup..."
    toolkit_cmd bin/up -d
    if ! wait_for_ui "$url"; then
      die "Overleaf UI did not become ready at $url"
    fi
  fi
  cleanup_overleaf_images
  echo "Overleaf is ready: $url"
  open_browser "$url"
}

cmd_stop() {
  ensure_toolkit_present
  ensure_toolkit_line_endings
  toolkit_cmd bin/stop
}

cmd_restart() {
  ensure_toolkit_present
  ensure_toolkit_line_endings
  toolkit_cmd bin/docker-compose restart
}

cmd_status() {
  local url
  url="http://${OVERLEAF_HOST}:${OVERLEAF_PORT}${OVERLEAF_OPEN_PATH}"
  ensure_toolkit_present
  ensure_toolkit_line_endings
  toolkit_cmd bin/docker-compose ps
  if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then
    echo ""
    echo "UI check: OK ($url)"
  else
    echo ""
    echo "UI check: FAILED ($url)"
    return 1
  fi
}

cmd_logs() {
  ensure_toolkit_present
  ensure_toolkit_line_endings
  if [[ $# -gt 0 ]]; then
    toolkit_cmd bin/logs "$@"
  else
    toolkit_cmd bin/logs -n 120 web clsi
  fi
}

cmd_doctor() {
  ensure_prerequisites
  ensure_toolkit_present
  ensure_toolkit_line_endings
  toolkit_cmd bin/doctor
}

cmd_self_check() {
  local root rc_file version_file
  root="$(toolkit_root)"
  rc_file="$root/config/overleaf.rc"
  version_file="$root/config/version"
  echo "Repository root: $REPO_ROOT"
  echo "Toolkit path: $TOOLKIT_PATH"
  echo "Toolkit repo: $TOOLKIT_REPO"
  echo "Toolkit pin: $TOOLKIT_REF"
  echo "Host: ${OVERLEAF_HOST}:${OVERLEAF_PORT}"
  echo "App name: ${OVERLEAF_APP_NAME:-Overleaf}"
  echo "Base image tag: ${BASE_OVERLEAF_IMAGE_TAG:-$OVERLEAF_IMAGE_TAG}"
  echo "Image tag: $OVERLEAF_IMAGE_TAG"
  echo "TeX packages: ${TEXLIVE_PACKAGES:-<none>}"
  echo "Required TeX scheme: ${TEXLIVE_REQUIRED_SCHEME:-<none>}"
  echo "TeX check files: ${TEXLIVE_CHECK_FILES:-elsarticle.cls}"
  echo "Auto prune extra sharelatex images: ${AUTO_PRUNE_SHARELATEX_IMAGES:-1}"
  echo "Keep base image tag: ${KEEP_BASE_OVERLEAF_IMAGE:-0}"
  echo ""
  have_cmd docker && echo "docker: OK" || echo "docker: MISSING"
  have_cmd git && echo "git: OK" || echo "git: MISSING"
  have_cmd bash && echo "bash: OK" || echo "bash: MISSING"
  if docker info >/dev/null 2>&1; then
    echo "docker daemon: OK"
  else
    echo "docker daemon: NOT RUNNING"
  fi
  if [[ -d "$root" ]]; then
    echo "toolkit dir: PRESENT"
  else
    echo "toolkit dir: MISSING"
  fi
  if [[ -f "$rc_file" ]]; then
    echo "toolkit config: PRESENT"
  else
    echo "toolkit config: MISSING"
  fi
  if [[ -f "$version_file" ]]; then
    echo "toolkit image version file: PRESENT ($(cat "$version_file"))"
  else
    echo "toolkit image version file: MISSING"
  fi
  if docker image inspect "$(target_image_ref)" >/dev/null 2>&1; then
    if image_has_required_tex_baseline "$(target_image_ref)"; then
      echo "hardened image: PRESENT and valid ($(target_image_ref))"
    else
      echo "hardened image: PRESENT but missing required TeX baseline (scheme/files)"
    fi
  else
    echo "hardened image: MISSING ($(target_image_ref))"
  fi
}

cmd_images_prune() {
  ensure_prerequisites
  cleanup_overleaf_images
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" | awk 'NR==1 || $1=="sharelatex/sharelatex" {print}'
}

cmd_tex_install() {
  local target_image package_list
  [[ $# -gt 0 ]] || die "Usage: work tex install <tlmgr-package...>"
  ensure_prerequisites
  ensure_overleaf_image
  target_image="$(target_image_ref)"
  package_list="$*"
  echo "Installing TeX packages into $target_image: $package_list"
  install_tex_packages_into_image "$target_image" "$target_image" "$package_list"
  ensure_toolkit_present
  ensure_toolkit_line_endings
  ensure_toolkit_config
  toolkit_cmd bin/docker-compose up -d --force-recreate sharelatex
  echo "Package install completed and sharelatex container recreated."
}

cmd_tex_install_missing() {
  local target_image missing pkg unique_packages
  local -a resolved_packages=()
  local -a unresolved=()
  [[ $# -gt 0 ]] || die "Usage: work tex install-missing <missing-file...>"
  ensure_prerequisites
  ensure_overleaf_image
  target_image="$(target_image_ref)"

  for missing in "$@"; do
    pkg="$(resolve_packages_for_missing_file "$target_image" "$missing" | tr '\n' ' ' | xargs || true)"
    if [[ -z "$pkg" ]]; then
      unresolved+=("$missing")
      continue
    fi
    echo "Resolved $missing -> $pkg"
    for p in $pkg; do
      resolved_packages+=("$p")
    done
  done

  if [[ ${#resolved_packages[@]} -eq 0 ]]; then
    if [[ ${#unresolved[@]} -gt 0 ]]; then
      echo "Could not resolve packages for: ${unresolved[*]}"
    fi
    die "No installable package was resolved from missing files."
  fi

  unique_packages="$(printf '%s\n' "${resolved_packages[@]}" | awk 'NF { if (!seen[$0]++) print $0 }' | xargs)"
  cmd_tex_install $unique_packages

  if [[ ${#unresolved[@]} -gt 0 ]]; then
    echo "Unresolved missing files: ${unresolved[*]}"
    echo "Provide package names manually via: work tex install <package...>"
  fi
}

cmd_toolkit_update() {
  local new_ref="${1:-}"
  local root
  root="$(toolkit_root)"
  [[ -n "$new_ref" ]] || die "Usage: work toolkit update <ref>"
  ensure_prerequisites
  ensure_toolkit_present
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Toolkit is not a valid git checkout."
  git -C "$root" config core.autocrlf false
  git -C "$root" config core.eol lf
  git -C "$root" reset --hard HEAD >/dev/null
  git -C "$root" fetch --all --tags --quiet
  git -C "$root" checkout --quiet "$new_ref"
  set_work_config_value "TOOLKIT_REF" "$new_ref"
  echo "Updated toolkit to ref: $new_ref"
  echo "Pinned TOOLKIT_REF in work.config"
}

usage() {
  cat <<'EOF'
Usage:
  work start
  work stop
  work restart
  work status
  work logs [args...]
  work doctor
  work self-check
  work toolkit update <ref>
  work tex install <tlmgr-package...>
  work tex install-missing <missing-file...>
  work images prune
EOF
}

load_config

command="${1:-start}"
shift || true

case "$command" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  status) cmd_status "$@" ;;
  logs) cmd_logs "$@" ;;
  doctor) cmd_doctor "$@" ;;
  self-check) cmd_self_check "$@" ;;
  toolkit)
    subcommand="${1:-}"
    shift || true
    case "$subcommand" in
      update) cmd_toolkit_update "$@" ;;
      *) die "Usage: work toolkit update <ref>" ;;
    esac
    ;;
  tex)
    subcommand="${1:-}"
    shift || true
    case "$subcommand" in
      install) cmd_tex_install "$@" ;;
      install-missing) cmd_tex_install_missing "$@" ;;
      *) die "Usage: work tex install <tlmgr-package...> | work tex install-missing <missing-file...>" ;;
    esac
    ;;
  images)
    subcommand="${1:-}"
    shift || true
    case "$subcommand" in
      prune) cmd_images_prune "$@" ;;
      *) die "Usage: work images prune" ;;
    esac
    ;;
  help|-h|--help) usage ;;
  *) die "Unknown command: $command" ;;
esac
