#!/bin/sh
# Bootstrap the project's pinned Go in a private cache without changing the
# user's installed Go or shell configuration. No preinstalled Go is required.
set -eu

go_version=go1.27.3
go_archive_name=go1.27.3.darwin-arm64.tar.gz
go_archive_sha256=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2
go_archive_url=https://go.dev/dl/go1.27.3.darwin-arm64.tar.gz

if [ "$(/usr/bin/uname -sm)" != 'Darwin arm64' ]; then
  echo 'Mokusei native development requires Apple Silicon macOS.' >&2
  exit 1
fi

go_cache_base=${MOKUSEI_GO_CACHE:-"${HOME}/Library/Caches/Mokusei/toolchains"}
go_install_root=${go_cache_base}/${go_version}-darwin-arm64
go_lock=${go_cache_base}/.${go_version}.lock
go_stage=
go_owns_lock=0

valid_install() {
  [ -x "${go_install_root}/bin/go" ] &&
    [ -f "${go_install_root}/.mokusei-archive-sha256" ] &&
    [ "$(cat "${go_install_root}/.mokusei-archive-sha256")" = "$go_archive_sha256" ] &&
    [ "$(/usr/bin/head -n 1 "${go_install_root}/VERSION")" = "$go_version" ]
}
cleanup() {
  if [ -n "$go_stage" ]; then /bin/rm -rf "$go_stage"; fi
  if [ "$go_owns_lock" = 1 ]; then /bin/rm -rf "$go_lock"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if ! valid_install; then
  /bin/mkdir -p "$go_cache_base"
  go_attempt=0
  while :; do
    if /bin/mkdir "$go_lock" 2>/dev/null; then
      go_owns_lock=1
      printf '%s\n' "$$" > "$go_lock/pid"
      break
    fi
    # A completed concurrent bootstrap can be used without waiting for its
    # caller. Never break a live bootstrap's lock based on elapsed time.
    if valid_install; then break; fi
    go_lock_pid=
    if [ -f "$go_lock/pid" ]; then go_lock_pid=$(cat "$go_lock/pid"); fi
    case "$go_lock_pid" in
      ''|*[!0-9]*) ;;
      *) if ! kill -0 "$go_lock_pid" 2>/dev/null; then
           echo "A previous pinned Go bootstrap exited; inspect and remove its stale lock: $go_lock" >&2
           exit 1
         fi ;;
    esac
    go_attempt=$((go_attempt + 1))
    if [ "$go_attempt" -ge 120 ]; then
      echo "Pinned Go bootstrap is still locked: $go_lock. Inspect the bootstrap process before removing a stale lock." >&2
      exit 1
    fi
    /bin/sleep 1
  done
  if ! valid_install; then
    go_stage=$(/usr/bin/mktemp -d "${go_cache_base}/.go-stage.XXXXXX")
    go_archive=${go_cache_base}/${go_archive_name}
    go_valid_archive=0
    if [ -f "$go_archive" ]; then
      go_actual=$(/usr/bin/shasum -a 256 "$go_archive")
      if [ "${go_actual%% *}" = "$go_archive_sha256" ]; then go_valid_archive=1; fi
    fi
    if [ "$go_valid_archive" != 1 ]; then
      echo "Downloading pinned ${go_version} for Mokusei..." >&2
      /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --output "$go_stage/archive.tar.gz" "$go_archive_url"
      go_actual=$(/usr/bin/shasum -a 256 "$go_stage/archive.tar.gz")
      if [ "${go_actual%% *}" != "$go_archive_sha256" ]; then
        echo 'Pinned Go archive checksum mismatch; no toolchain was installed.' >&2
        exit 1
      fi
      /bin/mv "$go_stage/archive.tar.gz" "$go_archive"
    fi
    /usr/bin/tar -xzf "$go_archive" -C "$go_stage"
    if [ "$(/usr/bin/head -n 1 "$go_stage/go/VERSION")" != "$go_version" ] ||
       [ "$(/usr/bin/env -u GOROOT GOTOOLCHAIN=local "$go_stage/go/bin/go" version)" != "go version $go_version darwin/arm64" ]; then
      echo 'Pinned archive did not contain the expected Go toolchain.' >&2
      exit 1
    fi
    printf '%s\n' "$go_archive_sha256" > "$go_stage/go/.mokusei-archive-sha256"
    if [ -e "$go_install_root" ]; then
      /bin/mv "$go_install_root" "${go_install_root}.previous.$$"
    fi
    /bin/mv "$go_stage/go" "$go_install_root"
  fi
fi

# All child build commands resolve this same compiler, including go run tools.
# GOTOOLCHAIN=local prevents an unrelated shell setting from selecting an older
# or automatically downloaded toolchain. GOROOT must belong to this compiler.
PATH="${go_install_root}/bin:${PATH}"
MOKUSEI_GO="${go_install_root}/bin/go"
GOTOOLCHAIN=local
unset GOROOT
export PATH MOKUSEI_GO GOTOOLCHAIN
cleanup
trap - EXIT INT TERM HUP
exec "${go_install_root}/bin/go" "$@"
