#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd -P)"
package_root="${TAUTWEEKLY_PACKAGE_ROOT:-$script_root}"
package_kind="${TAUTWEEKLY_PACKAGE_KIND:-}"
release_api="${TAUTWEEKLY_RELEASE_API_URL:-https://api.github.com/repos/sparkmoxie/TautWeekly/releases/latest}"
release_download_root="${TAUTWEEKLY_RELEASE_DOWNLOAD_ROOT:-https://github.com/sparkmoxie/TautWeekly/releases/download}"

case "$package_kind" in
  nas-docker)
    package_name="TautWeekly-nas-docker"
    runtime_updater="container-update.sh"
    update_strategy="container-package"
    ;;
  mac-docker)
    package_name="TautWeekly-mac-docker"
    runtime_updater="mac-update.sh"
    update_strategy="container-package"
    ;;
  linux)
    package_name="TautWeekly-linux"
    runtime_updater="/usr/local/bin/tautweekly"
    update_strategy="native-linux"
    ;;
  freebsd-podman)
    package_name="TautWeekly-freebsd-podman"
    runtime_updater="/usr/local/sbin/tautweekly"
    update_strategy="native-freebsd"
    ;;
  *)
    echo "Unsupported TAUTWEEKLY_PACKAGE_KIND: $package_kind" >&2
    exit 64
    ;;
esac
archive_name="$package_name.tar.gz"

current_package_version() {
  local value=""
  if [[ -r "$package_root/RELEASE-METADATA.txt" ]]; then
    value="$(sed -n 's/^Repository version:[[:space:]]*v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$package_root/RELEASE-METADATA.txt" | head -n 1)"
  fi
  printf '%s' "${value:-unknown}"
}

version_greater_than() {
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"$1"
  IFS=. read -r right_major right_minor right_patch <<<"$2"
  (( 10#$left_major > 10#$right_major )) && return 0
  (( 10#$left_major < 10#$right_major )) && return 1
  (( 10#$left_minor > 10#$right_minor )) && return 0
  (( 10#$left_minor < 10#$right_minor )) && return 1
  (( 10#$left_patch > 10#$right_patch ))
}

download_file() {
  local url="$1" destination="$2" name="${3:-}"
  if [[ -n "${TAUTWEEKLY_RELEASE_ASSET_DIR:-}" && -n "$name" ]]; then
    cp -p "$TAUTWEEKLY_RELEASE_ASSET_DIR/$name" "$destination"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$destination"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget --https-only --quiet -O "$destination" "$url"
    return
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch --quiet --output "$destination" "$url"
    return
  fi
  echo "A TLS-capable curl, wget, or fetch command is required for package updates." >&2
  exit 69
}

latest_release_version() {
  local response latest temp
  if [[ -n "${TAUTWEEKLY_LATEST_RELEASE_VERSION:-}" ]]; then
    latest="${TAUTWEEKLY_LATEST_RELEASE_VERSION#v}"
  else
    temp="$(mktemp "${TMPDIR:-/tmp}/tautweekly-release-api.XXXXXX")"
    download_file "$release_api" "$temp"
    response="$(cat "$temp")"
    rm -f "$temp"
    latest="$(printf '%s' "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "GitHub did not return a valid stable release version." >&2
    exit 65
  fi
  printf '%s' "$latest"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print tolower($1)}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print tolower($1)}'
    return
  fi
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$path" | tr '[:upper:]' '[:lower:]'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //' | tr '[:upper:]' '[:lower:]'
    return
  fi
  echo "A SHA-256 utility (sha256sum, shasum, sha256, or openssl) is required to verify release files." >&2
  exit 69
}

safe_release_path() {
  local path="$1" component
  local -a components
  [[ -n "$path" && "$path" != /* && ! "$path" =~ ^[A-Za-z]: ]] || return 1
  [[ "$path" != *$'\t'* && "$path" != *$'\r'* && "$path" != *\\* && "$path" != *:* ]] || return 1
  IFS=/ read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
  done
}

protected_runtime_path() {
  case "$1" in
    .env|data|data/*|tautweekly-data-backup-*.tar.gz|tautweekly-private-data-*.tar.gz) return 0 ;;
    *) return 1 ;;
  esac
}

verify_release_manifest() {
  local root="$1" installed="${2:-false}" line expected relative actual
  [[ -r "$root/RELEASE-FILES.txt" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^([0-9a-f]{64})[[:space:]]{2}(.+)$ ]]; then
      return 1
    fi
    expected="${BASH_REMATCH[1]}"
    relative="${BASH_REMATCH[2]}"
    safe_release_path "$relative" || return 1
    if protected_runtime_path "$relative"; then
      [[ "$installed" == true ]] && continue
      [[ -f "$root/$relative" ]] || return 1
    fi
    [[ -f "$root/$relative" && ! -L "$root/$relative" ]] || return 1
    actual="$(sha256_file "$root/$relative")"
    [[ "$actual" == "$expected" ]] || return 1
  done <"$root/RELEASE-FILES.txt"
}

verify_archive_listing() {
  local archive="$1" entry detail type
  while IFS= read -r entry; do
    entry="${entry#./}"
    [[ -z "$entry" ]] && continue
    entry="${entry%/}"
    safe_release_path "$entry" || {
      echo "The release archive contains an unsafe path: $entry" >&2
      return 1
    }
  done < <(tar -tzf "$archive")
  while IFS= read -r detail; do
    type="${detail:0:1}"
    [[ "$type" == - || "$type" == d ]] || {
      echo "The release archive contains a link or unsupported entry type." >&2
      return 1
    }
  done < <(tar -tvzf "$archive")
}

stage_release() {
  local version="$1" work_root="$2" sums archive expected actual candidate_version
  sums="$work_root/SHA256SUMS.txt"
  archive="$work_root/$archive_name"
  download_file "$release_download_root/v$version/SHA256SUMS.txt" "$sums" SHA256SUMS.txt
  download_file "$release_download_root/v$version/$archive_name" "$archive" "$archive_name"
  expected="$(awk -v name="$archive_name" '$2 == name {print tolower($1)}' "$sums")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "SHA256SUMS.txt has no unique valid entry for $archive_name." >&2
    exit 65
  }
  [[ "$(awk -v name="$archive_name" '$2 == name {count++} END {print count+0}' "$sums")" == 1 ]] || {
    echo "SHA256SUMS.txt contains duplicate entries for $archive_name." >&2
    exit 65
  }
  actual="$(sha256_file "$archive")"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 verification failed for $archive_name." >&2
    exit 65
  }
  verify_archive_listing "$archive"
  tar -xzf "$archive" -C "$work_root"
  candidate_root="$work_root/$package_name"
  [[ -d "$candidate_root" && -x "$candidate_root/package-update.sh" ]] || {
    echo "The verified release archive has an incomplete package updater." >&2
    exit 66
  }
  verify_release_manifest "$candidate_root" false || {
    echo "The internal release-file manifest failed verification." >&2
    exit 65
  }
  candidate_version="$(sed -n 's/^Repository version:[[:space:]]*v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$candidate_root/RELEASE-METADATA.txt" | head -n 1)"
  [[ "$candidate_version" == "$version" ]] || {
    echo "The archive identifies package version ${candidate_version:-unknown}, expected $version." >&2
    exit 65
  }
  printf '%s' "$candidate_root"
}

sync_candidate() {
  local candidate_root="$1" target_root="$2" work_root="$3"
  local backup_root="$work_root/package-backup" record="$work_root/package-backup/restore.tsv"
  local line relative destination backup_destination
  mkdir -p "$backup_root/files"
  : >"$record"
  if [[ -r "$target_root/RELEASE-FILES.txt" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[0-9a-f]{64}[[:space:]]{2}(.+)$ ]] || continue
      relative="${BASH_REMATCH[1]}"
      safe_release_path "$relative" || continue
      protected_runtime_path "$relative" && continue
      if awk -v path="$relative" 'length($0) >= 67 && substr($0, 67) == path { found=1 } END { exit found ? 0 : 1 }' \
          "$candidate_root/RELEASE-FILES.txt"; then
        continue
      fi
      destination="$target_root/$relative"
      [[ -e "$destination" || -L "$destination" ]] || continue
      [[ -f "$destination" && ! -L "$destination" ]] || {
        echo "Refusing to remove a non-regular retired package path: $relative" >&2
        return 1
      }
      backup_destination="$backup_root/files/$relative"
      mkdir -p "$(dirname "$backup_destination")"
      cp -p "$destination" "$backup_destination"
      printf 'E\t%s\n' "$relative" >>"$record"
      rm -f "$destination"
    done <"$target_root/RELEASE-FILES.txt"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[0-9a-f]{64}[[:space:]]{2}(.+)$ ]] || return 1
    relative="${BASH_REMATCH[1]}"
    safe_release_path "$relative" || return 1
    protected_runtime_path "$relative" && continue
    destination="$target_root/$relative"
    backup_destination="$backup_root/files/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
      [[ -f "$destination" && ! -L "$destination" ]] || {
        echo "Refusing to replace a non-regular package path: $relative" >&2
        return 1
      }
      mkdir -p "$(dirname "$backup_destination")"
      cp -p "$destination" "$backup_destination"
      printf 'E\t%s\n' "$relative" >>"$record"
    else
      printf 'N\t%s\n' "$relative" >>"$record"
    fi
    mkdir -p "$(dirname "$destination")"
    cp -p "$candidate_root/$relative" "$destination"
  done <"$candidate_root/RELEASE-FILES.txt"

  if [[ -e "$target_root/RELEASE-FILES.txt" ]]; then
    cp -p "$target_root/RELEASE-FILES.txt" "$backup_root/RELEASE-FILES.txt"
    printf 'E\tRELEASE-FILES.txt\n' >>"$record"
  else
    printf 'N\tRELEASE-FILES.txt\n' >>"$record"
  fi
  cp -p "$candidate_root/RELEASE-FILES.txt" "$target_root/RELEASE-FILES.txt"
  printf '%s' "$backup_root"
}

restore_backup() {
  local backup_root="$1" target_root="$2" state relative source destination
  [[ -r "$backup_root/restore.tsv" ]] || return 0
  while IFS=$'\t' read -r state relative; do
    safe_release_path "$relative" || return 1
    destination="$target_root/$relative"
    if [[ "$state" == E ]]; then
      source="$backup_root/files/$relative"
      [[ "$relative" != RELEASE-FILES.txt ]] || source="$backup_root/RELEASE-FILES.txt"
      mkdir -p "$(dirname "$destination")"
      cp -p "$source" "$destination"
    elif [[ "$state" == N ]]; then
      rm -f "$destination"
    else
      return 1
    fi
  done <"$backup_root/restore.tsv"
}

run_runtime_updater() {
  local mode="$1"
  shift
  case "$update_strategy" in
    container-package) exec "$package_root/$runtime_updater" "$mode" "$@" ;;
    native-freebsd)
      [[ "$mode" == check ]] && exec "$runtime_updater" check-image "$@"
      exec "$runtime_updater" update-image "$@"
      ;;
    native-linux)
      echo "Native Linux package $latest is already installed; no service files were changed."
      ;;
  esac
}

check_update() {
  local current latest package_state
  current="$(current_package_version)"
  if [[ "$current" == unknown ]]; then
    echo "Installed host package: development or legacy package (release metadata unavailable)"
    echo "Automatic host-package refresh requires an official release archive."
    [[ "$update_strategy" != container-package && "$package_kind" != freebsd-podman ]] || run_runtime_updater check
    return
  fi
  latest="$(latest_release_version)"
  package_state="versioned"
  if [[ "$update_strategy" == container-package ]]; then
    package_state="verified"
    verify_release_manifest "$package_root" true || package_state="repair-required"
  fi
  echo "Installed host package: $current ($package_state)"
  echo "Latest stable package: $latest"
  if [[ "$package_state" == repair-required ]]; then
    echo "The next update will repair release-owned host files without replacing .env or data/."
  elif [[ "$current" == "$latest" ]]; then
    echo "The host package is up to date."
  elif version_greater_than "$current" "$latest"; then
    echo "The host package is newer than the latest stable release."
  else
    echo "A host-package update is available: $current -> $latest"
  fi
  [[ "$update_strategy" != container-package && "$package_kind" != freebsd-podman ]] || run_runtime_updater check
}

apply_update() {
  local current latest needs_package=false work_root candidate_root
  current="$(current_package_version)"
  if [[ "$current" == unknown ]]; then
    echo "Automatic host-package refresh is unavailable in a development or legacy package." >&2
    echo "Use a verified stable release archive, or run $runtime_updater directly for an image-only development update." >&2
    exit 65
  fi
  latest="$(latest_release_version)"
  if [[ "$current" == "$latest" ]]; then
    if [[ "$update_strategy" == container-package ]]; then
      verify_release_manifest "$package_root" true || needs_package=true
    fi
  elif version_greater_than "$current" "$latest"; then
    echo "Installed host package $current is newer than stable $latest; no downgrade was applied."
    run_runtime_updater apply
  else
    needs_package=true
  fi
  if [[ "$needs_package" != true ]]; then
    run_runtime_updater apply
  fi

  work_root="$(mktemp -d "${TMPDIR:-/tmp}/tautweekly-package-update.XXXXXX")"
  trap 'rm -rf "$work_root"' EXIT
  candidate_root="$(stage_release "$latest" "$work_root")"
  echo "Verified stable $package_name package version $latest."
  export TAUTWEEKLY_PACKAGE_KIND="$package_kind"
  export TAUTWEEKLY_PACKAGE_ROOT="$package_root"
  case "$update_strategy" in
    container-package) exec "$candidate_root/package-update.sh" install-candidate "$package_root" "$work_root" ;;
    native-linux)
      export TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT="$work_root"
      exec "$candidate_root/install-linux.sh" --upgrade
      ;;
    native-freebsd)
      export TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT="$work_root"
      exec "$candidate_root/install-freebsd.sh" --upgrade-and-update
      ;;
  esac
}

install_candidate() {
  local target_root="$1" work_root="$2" candidate_root backup_root
  candidate_root="$script_root"
  package_root="$(cd "$target_root" && pwd -P)"
  verify_release_manifest "$candidate_root" false || {
    echo "The staged release-file manifest failed before installation." >&2
    exit 65
  }
  backup_root="$(sync_candidate "$candidate_root" "$package_root" "$work_root")" || {
    restore_backup "$work_root/package-backup" "$package_root" || true
    echo "The host package could not be updated; previous files were restored." >&2
    exit 70
  }
  echo "Updated release-owned host files; .env and data/ were preserved."
  exec "$package_root/$runtime_updater" apply \
    --package-backup "$backup_root" \
    --package-work-root "$work_root"
}

case "${1:-check}" in
  check) check_update ;;
  apply) apply_update ;;
  install-candidate)
    [[ $# -eq 3 ]] || { echo "install-candidate requires target and work roots." >&2; exit 64; }
    install_candidate "$2" "$3"
    ;;
  restore-backup)
    [[ $# -eq 3 ]] || { echo "restore-backup requires backup and target roots." >&2; exit 64; }
    restore_backup "$2" "$3"
    ;;
  *) echo "Usage: package-update.sh check|apply" >&2; exit 64 ;;
esac
