#!/usr/bin/env bash
set -euo pipefail

image="${1:?Usage: test-container-image.sh IMAGE [BUILD_CONTEXT] [RUNTIME_PROFILE: server|desktop|unraid]}"
build_context="${2:-}"
runtime_profile="${3:-server}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container_name="tautweekly-smoke-$RANDOM-$$"
funnel_container="tautweekly-funnel-$RANDOM-$$"
named_container="tautweekly-volume-$RANDOM-$$"
named_volume="tautweekly-volume-$RANDOM-$$"
data_root="$(mktemp -d)"
funnel_data_root="$(mktemp -d)"
funnel_state_root="$(mktemp -d)"
generated_context=""
container_started=false
funnel_container_started=false
named_container_started=false
named_volume_created=false

remove_runtime_temp_dir() {
  local path="$1"
  local owner_uid owner_gid
  [[ -d "$path" ]] || return 0
  if rm -rf "$path" 2>/dev/null; then
    return 0
  fi
  owner_uid="$(id -u)"
  owner_gid="$(id -g)"
  docker run --rm \
    --network none \
    --read-only \
    --user 0:0 \
    --entrypoint /bin/sh \
    -e "CLEANUP_UID=$owner_uid" \
    -e "CLEANUP_GID=$owner_gid" \
    -v "$path:/cleanup" \
    "$image" \
    -c 'find /cleanup -mindepth 1 -delete && chown "$CLEANUP_UID:$CLEANUP_GID" /cleanup' \
    >/dev/null 2>&1 || true
  rm -rf "$path"
}

cleanup() {
  if [[ "$container_started" == true ]]; then
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  if [[ "$funnel_container_started" == true ]]; then
    docker rm -f "$funnel_container" >/dev/null 2>&1 || true
  fi
  if [[ "$named_container_started" == true ]]; then
    docker rm -f "$named_container" >/dev/null 2>&1 || true
  fi
  if [[ "$named_volume_created" == true ]]; then
    docker volume rm -f "$named_volume" >/dev/null 2>&1 || true
  fi
  remove_runtime_temp_dir "$data_root"
  remove_runtime_temp_dir "$funnel_data_root"
  remove_runtime_temp_dir "$funnel_state_root"
  if [[ -n "$generated_context" ]]; then
    rm -rf "$generated_context"
  fi
}
trap cleanup EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  if [[ "$container_started" == true ]]; then
    docker inspect "$container_name" >&2 || true
    docker logs "$container_name" >&2 || true
  fi
  if [[ "$funnel_container_started" == true ]]; then
    docker inspect "$funnel_container" >&2 || true
    docker logs "$funnel_container" >&2 || true
  fi
  exit 1
}

manager_password='TautWeekly-CI-Only-2026!'
manager_cookie_path='/tmp/tautweekly-ci.cookies'

pair_manager() {
  local target="$1"
  local token="$2"
  printf '{"token":"%s","password":"%s"}' "$token" "$manager_password" |
    docker exec -i "$target" curl -fsS \
      -c "$manager_cookie_path" \
      -H 'Content-Type: application/json' \
      --data-binary @- \
      http://127.0.0.1:8080/api/v1/auth/pair \
      >/dev/null || fail "$runtime_profile Manager rejected first-run pairing."
}

login_manager() {
  local target="$1"
  printf '{"password":"%s"}' "$manager_password" |
    docker exec -i "$target" curl -fsS \
      -c "$manager_cookie_path" \
      -H 'Content-Type: application/json' \
      --data-binary @- \
      http://127.0.0.1:8080/api/v1/auth/login \
      >/dev/null || fail "$runtime_profile Manager credentials did not survive the container lifecycle."
}

manager_capabilities() {
  docker exec "$1" curl -fsS \
    -b "$manager_cookie_path" \
    http://127.0.0.1:8080/api/v1/capabilities
}

case "$runtime_profile" in
  server)
    active_runtime_profile=server
    manager_runtime_profile=nas
    package_kind=container-compose
    ;;
  desktop)
    active_runtime_profile=desktop
    manager_runtime_profile=mac
    package_kind=container-desktop
    ;;
  unraid)
    active_runtime_profile=unraid
    manager_runtime_profile=nas
    package_kind=unraid
    ;;
  nas)
    active_runtime_profile=server
    manager_runtime_profile=nas
    package_kind=nas-docker
    ;;
  mac)
    active_runtime_profile=desktop
    manager_runtime_profile=mac
    package_kind=mac-docker
    ;;
  mac-registry)
    active_runtime_profile=desktop
    manager_runtime_profile=mac
    package_kind=mac-docker-registry
    ;;
  *) fail "Unsupported runtime profile: $runtime_profile" ;;
esac

if [[ -n "$build_context" ]]; then
  if [[ "$runtime_profile" == mac && ! -d "$build_context/manager" ]]; then
    command -v go >/dev/null 2>&1 || fail 'Go is required to stage the Mac Manager build context.'
    case "$(uname -m)" in
      x86_64|amd64) manager_arch=amd64 ;;
      aarch64|arm64) manager_arch=arm64 ;;
      *) fail 'Mac image smoke staging requires a supported 64-bit host architecture.' ;;
    esac
    generated_context="$(mktemp -d)"
    cp -a "$build_context/." "$generated_context/"
    mkdir -p "$generated_context/manager"
    (
      cd "$repo_root/manager"
      CGO_ENABLED=0 GOOS=linux GOARCH="$manager_arch" go build -trimpath -buildvcs=false -ldflags '-s -w -X main.version=ci' -o "$generated_context/manager/tautweekly-manager-linux-$manager_arch" ./cmd/tautweekly-manager
    )
    build_context="$generated_context"
  fi
  docker build --build-arg BUILD_VERSION=ci --tag "$image" "$build_context"
fi

host_uid="$(id -u)"
host_gid="$(id -g)"
if [[ "$host_uid" -eq 0 ]]; then host_uid=1000; fi
if [[ "$host_gid" -eq 0 ]]; then host_gid=1000; fi

security_args=(
  --read-only
  --tmpfs '/tmp:rw,noexec,nosuid,size=256m,mode=1777'
  --tmpfs '/run:rw,noexec,nosuid,size=16m,mode=0755'
  --security-opt no-new-privileges:true
  --cap-drop ALL
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add SETGID
  --cap-add SETUID
)
runtime_env_args=(
  -e "PUID=$host_uid"
  -e "PGID=$host_gid"
  -e "TAUTWEEKLY_RUNTIME_PROFILE=$active_runtime_profile"
  -e 'UMASK=077'
  -e 'TZ=Etc/UTC'
  -e "TAUTWEEKLY_PACKAGE_KIND=$package_kind"
  -e 'TAUTWEEKLY_PACKAGE_VERSION=ci'
  -e 'TAUTWEEKLY_HOST_ADAPTER_API=4'
  -e 'TAUTWEEKLY_FUNNEL_ADAPTER=disabled'
)

image_version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image")"
[[ "$image_version" == ci ]] || fail "Image version label is $image_version instead of ci."
if [[ "$package_kind" == container-desktop || "$package_kind" == container-compose || "$package_kind" == unraid ]]; then
  image_runtime_profiles="$(docker image inspect --format '{{ index .Config.Labels "io.tautweekly.runtime-profiles" }}' "$image")"
  [[ "$image_runtime_profiles" == desktop,server,unraid ]] || fail "Unified image runtime profile label is $image_runtime_profiles."
  image_repository="$(docker image inspect --format '{{ index .Config.Labels "io.tautweekly.image-repository" }}' "$image")"
  [[ "$image_repository" == ghcr.io/sparkmoxie/tautweekly ]] || fail "Unified image repository label is $image_repository."
fi

# Existing installations may have healthy customized stock assets and no marker.
mkdir -p "$data_root/assets" "$data_root/output/assets"
printf '%s' 'old customized stock' >"$data_root/assets/movies.gif"
printf '%s' 'old customized PNG' >"$data_root/assets/watched.png"
printf '%s' 'custom-only sentinel' >"$data_root/assets/custom-only.gif"
printf '%s' 'unrelated output' >"$data_root/output/keep.txt"

docker run --detach \
  --name "$container_name" \
  "${security_args[@]}" \
  "${runtime_env_args[@]}" \
  -v "$data_root:/data" \
  "$image" >/dev/null
container_started=true

healthy=false
for _ in {1..100}; do
  running="$(docker inspect --format '{{.State.Running}}' "$container_name")"
  [[ "$running" == true ]] || fail 'Container exited during startup.'
  if docker exec "$container_name" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 0.2
done
[[ "$healthy" == true ]] || fail 'Container never passed its production healthcheck.'

docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh pwsh -NoLogo -NoProfile -NonInteractive -Command \
  'if ($PSVersionTable.PSVersion -lt [Version]"7.2") { exit 1 }' || fail 'PowerShell 7.2+ is unavailable in the runtime image.'
docker exec "$container_name" test -s /data/.tautweekly-asset-bundle || fail 'Asset migration marker is missing.'
for name in movies.gif watched.png; do
  docker exec "$container_name" cmp "/opt/tautweekly/assets-default/$name" "/data/assets/$name" || fail "Stock asset was not refreshed: $name"
  docker exec "$container_name" cmp "/data/assets/$name" "/data/output/assets/$name" || fail "Preview asset was not refreshed: $name"
done
[[ "$(docker exec "$container_name" cat /data/assets/custom-only.gif)" == 'custom-only sentinel' ]] || fail 'Custom-only asset was overwritten.'
[[ "$(docker exec "$container_name" cat /data/output/keep.txt)" == 'unrelated output' ]] || fail 'Unrelated output was changed.'

docker exec "$container_name" test -s /data/config.example.json || fail 'Persistent config example was not initialized.'
if [[ "$manager_runtime_profile" == mac ]]; then
  docker exec "$container_name" test ! -e /data/output/index.html || fail 'Mac first run created a stale static output index instead of using Manager.'
fi
docker exec "$container_name" test -s /data/output/product-branding/favicon.ico || fail 'Preview favicon was not initialized.'
docker exec "$container_name" test -s /data/output/product-branding/tautweekly-app-icon-128.png || fail 'Preview product icon was not initialized.'
docker exec "$container_name" test -s /data/service-heartbeat.json || fail 'Service supervisor heartbeat was not initialized.'
if [[ "$manager_runtime_profile" == nas || "$manager_runtime_profile" == mac ]]; then
  docker exec "$container_name" test -x /opt/tautweekly/bin/tautweekly-manager || fail "$runtime_profile Manager binary is unavailable."
  setup_json="$(docker exec "$container_name" curl -fsS http://127.0.0.1:8080/api/v1/setup)"
  grep -Fq '"authenticationRequired":true' <<<"$setup_json" || fail "$runtime_profile Manager authentication is not mandatory."
  grep -Fq "\"runtimeMode\":\"$manager_runtime_profile\"" <<<"$setup_json" || fail "$runtime_profile Manager did not report its Manager runtime mode."
  bootstrap_token="$(docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager)"
  [[ "$bootstrap_token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || fail 'Explicit bootstrap command did not return a one-time token.'
  if docker logs "$container_name" 2>&1 | grep -Fq "$bootstrap_token"; then
    fail 'The one-time Manager bootstrap token was exposed in container logs.'
  fi
  pair_manager "$container_name" "$bootstrap_token"
  capabilities_json="$(manager_capabilities "$container_name")" || fail "$runtime_profile Manager capabilities were unavailable after pairing."
  grep -Fq "\"runtimeMode\":\"$manager_runtime_profile\"" <<<"$capabilities_json" || fail "$runtime_profile protected capabilities did not report the runtime profile."
  grep -Fq "\"packageKind\":\"$package_kind\"" <<<"$capabilities_json" || fail "$runtime_profile Manager did not report package kind $package_kind."
  grep -Fq "\"runtimeProfile\":\"$active_runtime_profile\"" <<<"$capabilities_json" || fail "$runtime_profile Manager did not report active profile $active_runtime_profile."
  if [[ "$active_runtime_profile" == desktop ]]; then
    expected_path_style="container-volume"
    [[ "$package_kind" == mac-docker ]] && expected_path_style="mac-bind-mount"
    grep -Fq "\"pathStyle\":\"$expected_path_style\"" <<<"$capabilities_json" || fail "Desktop Manager did not report $expected_path_style path semantics."
    grep -Fq '"networkScope":"host-loopback"' <<<"$capabilities_json" || fail 'Desktop Manager did not report loopback-first network semantics.'
  fi
  setup_json="$(docker exec "$container_name" curl -fsS http://127.0.0.1:8080/api/v1/setup)"
  grep -Fq '"paired":true' <<<"$setup_json" || fail "$runtime_profile Manager did not persist first-run pairing."
fi

# A normal docker exec bypasses entrypoint.sh and therefore begins as root.
# run-mode.sh must still drop to PUID/PGID before it creates any data.
[[ "$(docker exec "$container_name" id -u)" == "0" ]] || fail 'Ownership regression precondition did not start docker exec as root.'

# Older direct helper invocations could leave root-owned configuration or logs
# in /data. The shared privilege launcher must repair those entries without
# following a symlink outside the dedicated data filesystem.
docker exec "$container_name" sh -c 'mkdir -p /data/logs /tmp/tautweekly-ownership-target && touch /data/logs/legacy-root.log /tmp/tautweekly-ownership-target/private && ln -sfn /tmp/tautweekly-ownership-target/private /data/legacy-root-link'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /data/logs/legacy-root.log)" == '0:0' ]] || fail 'Legacy ownership regression precondition was not root-owned.'
[[ "$(docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh id -u)" == "$host_uid" ]] || fail 'Shared exec launcher did not drop to the configured UID.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /data/logs/legacy-root.log)" == "$host_uid:$host_gid" ]] || fail 'Shared exec launcher did not repair a legacy root-owned log.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /tmp/tautweekly-ownership-target/private)" == '0:0' ]] || fail 'Shared exec launcher followed a symlink outside /data.'

ownership_probe='/data/exec-ownership-probe'
docker exec "$container_name" rm -rf "$ownership_probe"
docker exec \
  -e "TAUTWEEKLY_DATA_DIR=$ownership_probe" \
  -e "TAUTWEEKLY_CONFIG=$ownership_probe/missing-config.json" \
  "$container_name" /opt/tautweekly/bin/run-mode.sh InvalidOwnershipProbe \
  >/dev/null 2>&1 || true
docker exec "$container_name" test -f "$ownership_probe/.tautweekly-operation.lock" || fail 'Root-started run-mode did not create the ownership probe lock.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' "$ownership_probe")" == "$host_uid:$host_gid" ]] || fail 'Root-started run-mode created its data directory with the wrong owner.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' "$ownership_probe/.tautweekly-operation.lock")" == "$host_uid:$host_gid" ]] || fail 'Root-started run-mode created its operation lock with the wrong owner.'

set +e
root_output="$(docker run --rm -e PUID=0 -e PGID="$host_gid" "$image" 2>&1)"
root_status=$?
set -e
[[ "$root_status" -eq 64 ]] || fail "Root-identity rejection exited $root_status instead of 64."
grep -Fq 'PUID/PGID 0 is refused' <<<"$root_output" || fail 'Root-identity rejection was not actionable.'

# A normal restart must not reapply an unchanged bundle over a later edit.
docker exec "$container_name" sh -c 'printf "%s" "post-update edit" > /data/assets/movies.gif'
docker restart "$container_name" >/dev/null
healthy=false
for _ in {1..100}; do
  if docker exec "$container_name" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 0.2
done
[[ "$healthy" == true ]] || fail 'Container did not recover after the same-bundle restart.'
[[ "$(docker exec "$container_name" cat /data/assets/movies.gif)" == 'post-update edit' ]] || fail 'Same-bundle restart replaced a custom edit.'
docker exec "$container_name" cmp /data/assets/movies.gif /data/output/assets/movies.gif || fail 'Restart did not refresh the preview mirror.'
if [[ "$manager_runtime_profile" == nas || "$manager_runtime_profile" == mac ]]; then
  login_manager "$container_name"
  capabilities_json="$(manager_capabilities "$container_name")" || fail "$runtime_profile Manager capabilities were unavailable after restart."
  grep -Fq "\"packageKind\":\"$package_kind\"" <<<"$capabilities_json" || fail "$runtime_profile package identity did not survive restart."
fi

# A service recreation against the same bind mount must preserve Manager
# credentials and host-owned private data for every supported profile.
docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh sh -c \
  'printf "%s" "bind-recreate-persistence" > /data/container-recreate-sentinel'
docker rm -f "$container_name" >/dev/null
container_started=false
docker run --detach \
  --name "$container_name" \
  "${security_args[@]}" \
  "${runtime_env_args[@]}" \
  -v "$data_root:/data" \
  "$image" >/dev/null
container_started=true
healthy=false
for _ in {1..100}; do
  if docker exec "$container_name" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 0.2
done
[[ "$healthy" == true ]] || fail "$runtime_profile container did not recover after bind-mount recreation."
[[ "$(docker exec "$container_name" cat /data/container-recreate-sentinel)" == bind-recreate-persistence ]] || fail 'Bind-mounted state did not survive service recreation.'
if [[ "$manager_runtime_profile" == nas || "$manager_runtime_profile" == mac ]]; then
  login_manager "$container_name"
  capabilities_json="$(manager_capabilities "$container_name")" || fail "$runtime_profile Manager capabilities were unavailable after bind-mount recreation."
  grep -Fq "\"runtimeProfile\":\"$active_runtime_profile\"" <<<"$capabilities_json" || fail "$runtime_profile profile identity did not survive bind-mount recreation."
  recreated_setup="$(docker exec "$container_name" curl -fsS http://127.0.0.1:8080/api/v1/setup)"
  grep -Fq '"paired":true' <<<"$recreated_setup" || fail "$runtime_profile Manager pairing did not survive bind-mount recreation."
fi

if [[ "$active_runtime_profile" == desktop ]]; then
  docker volume create "$named_volume" >/dev/null
  named_volume_created=true
  docker run --detach \
    --name "$named_container" \
    "${security_args[@]}" \
    "${runtime_env_args[@]}" \
    -v "$named_volume:/data" \
    "$image" >/dev/null
  named_container_started=true
  named_healthy=false
  for _ in {1..100}; do
    if docker exec "$named_container" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
      named_healthy=true
      break
    fi
    sleep 0.2
  done
  [[ "$named_healthy" == true ]] || fail 'Desktop profile did not become healthy with a named /data volume.'
  named_bootstrap_token="$(docker exec "$named_container" /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager)"
  pair_manager "$named_container" "$named_bootstrap_token"
  docker exec "$named_container" /opt/tautweekly/bin/run-as-user.sh sh -c \
    'printf "%s" "registry-recreate-persistence" > /data/registry-recreate-sentinel'
  [[ "$(docker exec "$named_container" stat -c '%u:%g' /data/registry-recreate-sentinel)" == "$host_uid:$host_gid" ]] || fail 'Named-volume state was not owned by the configured identity.'
  docker rm -f "$named_container" >/dev/null
  named_container_started=false
  docker run --detach \
    --name "$named_container" \
    "${security_args[@]}" \
    "${runtime_env_args[@]}" \
    -v "$named_volume:/data" \
    "$image" >/dev/null
  named_container_started=true
  named_healthy=false
  for _ in {1..100}; do
    if docker exec "$named_container" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
      named_healthy=true
      break
    fi
    sleep 0.2
  done
  [[ "$named_healthy" == true ]] || fail 'Desktop profile did not recover after named-volume recreation.'
  [[ "$(docker exec "$named_container" cat /data/registry-recreate-sentinel)" == registry-recreate-persistence ]] || fail 'Named-volume state did not survive service recreation.'
  login_manager "$named_container"
  named_capabilities="$(manager_capabilities "$named_container")" || fail 'Desktop capabilities were unavailable after named-volume recreation.'
  grep -Fq "\"packageKind\":\"$package_kind\"" <<<"$named_capabilities" || fail 'Desktop package identity did not survive named-volume recreation.'
  named_setup="$(docker exec "$named_container" curl -fsS http://127.0.0.1:8080/api/v1/setup)"
  grep -Fq '"paired":true' <<<"$named_setup" || fail 'Manager credentials did not survive named-volume recreation.'
  if docker exec "$named_container" /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager >/dev/null 2>&1; then
    fail 'A paired Manager unexpectedly exposed a new bootstrap token after named-volume recreation.'
  fi
fi

# Exercise the integrated official userspace Funnel runtime without network
# access, authentication, a real route, host networking, a TUN device, or any
# published port. This validates the exact socket boundary and refusal paths
# while keeping all provider state synthetic and disposable.
if [[ "$runtime_profile" == server || "$runtime_profile" == mac-registry ]]; then
  docker run --detach \
    --name "$funnel_container" \
    --network none \
    "${security_args[@]}" \
    "${runtime_env_args[@]}" \
    -e 'TAUTWEEKLY_FUNNEL_ADAPTER=enabled' \
    -v "$funnel_data_root:/data" \
    -v "$funnel_state_root:/var/lib/tautweekly-tailscale" \
    "$image" >/dev/null
  funnel_container_started=true

  funnel_healthy=false
  for _ in {1..150}; do
    running="$(docker inspect --format '{{.State.Running}}' "$funnel_container")"
    [[ "$running" == true ]] || fail 'Unauthenticated Funnel adapter container exited during startup.'
    if docker exec "$funnel_container" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
      funnel_healthy=true
      break
    fi
    sleep 0.2
  done
  [[ "$funnel_healthy" == true ]] || fail 'Unauthenticated Funnel adapter never became healthy.'

  [[ "$(docker exec "$funnel_container" stat -c '%u:%g:%a' /run/tautweekly-remote-access)" == '0:0:711' ]] ||
    fail 'Funnel adapter directory is not root-owned execute-only traversal.'
  [[ "$(docker exec "$funnel_container" stat -c '%u:%a' /run/tautweekly-remote-access/adapter.sock)" == "$host_uid:600" ]] ||
    fail 'Funnel adapter socket is not restricted to the Manager UID.'
  docker exec "$funnel_container" /opt/tautweekly/bin/run-as-user.sh test -S /run/tautweekly-remote-access/adapter.sock ||
    fail 'The non-root Manager identity cannot reach its fixed adapter socket.'
  docker exec "$funnel_container" test ! -e /var/run/docker.sock || fail 'Funnel adapter unexpectedly received the Docker socket.'
  docker exec "$funnel_container" test ! -e /dev/net/tun || fail 'Funnel adapter unexpectedly received a TUN device.'

  funnel_bootstrap="$(docker exec "$funnel_container" /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager)"
  pair_manager "$funnel_container" "$funnel_bootstrap"
  funnel_session="$(docker exec "$funnel_container" curl -fsS -b "$manager_cookie_path" http://127.0.0.1:8080/api/v1/auth/session)"
  funnel_csrf="$(printf '%s' "$funnel_session" | python3 -c 'import json,sys; print(json.load(sys.stdin)["csrfToken"])')"
  [[ -n "$funnel_csrf" ]] || fail 'Funnel adapter test could not obtain its synthetic CSRF token.'

  malformed_status="$(printf '%s' '{"operation":"enable","hostname":"attacker.invalid","port":443}' | docker exec -i "$funnel_container" curl -sS -o /tmp/funnel-response.json -w '%{http_code}' -b "$manager_cookie_path" -H "X-CSRF-Token: $funnel_csrf" -H 'Content-Type: application/json' --data-binary @- -X PUT http://127.0.0.1:8080/api/v1/remote-access/tailscale)"
  [[ "$malformed_status" == 400 ]] || fail 'Funnel browser API accepted a hostname or port.'
  grep -Fq '"code":"invalid-request"' < <(docker exec "$funnel_container" cat /tmp/funnel-response.json) ||
    fail 'Malformed Funnel browser input did not fail with the typed request boundary.'

  unsigned_status="$(printf '%s' '{"operation":"enable"}' | docker exec -i "$funnel_container" curl -sS -o /tmp/funnel-response.json -w '%{http_code}' -b "$manager_cookie_path" -H "X-CSRF-Token: $funnel_csrf" -H 'Content-Type: application/json' --data-binary @- -X PUT http://127.0.0.1:8080/api/v1/remote-access/tailscale)"
  [[ "$unsigned_status" == 409 ]] || fail 'Unauthenticated official Tailscale runtime did not refuse Funnel enablement.'
  grep -Fq '"code":"tailscale-sign-in-required"' < <(docker exec "$funnel_container" cat /tmp/funnel-response.json) ||
    fail 'Unauthenticated Funnel enablement was not sanitized as sign-in-required.'
  docker exec "$funnel_container" test ! -e /data/manager/container-funnel.json ||
    fail 'Failed Funnel enablement persisted a public route state.'

  set +e
  argument_output="$(docker exec "$funnel_container" /opt/tautweekly/bin/tautweekly-funnel login unexpected-argument 2>&1)"
  argument_status=$?
  set -e
  [[ "$argument_status" -eq 64 ]] || fail 'Interactive login accepted a browser-controlled or administrator-supplied CLI argument.'
  grep -Fq 'login accepts no host, port, key, token, or CLI arguments' <<<"$argument_output" || fail 'Interactive login argument refusal was not explicit.'

  docker stop --time 30 "$funnel_container" >/dev/null || fail 'Container did not complete verified no-route Funnel shutdown.'
  [[ "$(docker inspect --format '{{.State.ExitCode}}' "$funnel_container")" == 0 ]] || fail 'Verified Funnel shutdown did not exit cleanly.'
  docker rm "$funnel_container" >/dev/null
  funnel_container_started=false

  set +e
  refused_output="$(docker run --rm --network none "${security_args[@]}" "${runtime_env_args[@]}" -e 'TAUTWEEKLY_FUNNEL_ADAPTER=enabled' -e 'TS_AUTHKEY=synthetic-refused-value' -v "$funnel_data_root:/data" -v "$funnel_state_root:/var/lib/tautweekly-tailscale" "$image" 2>&1)"
  refused_status=$?
  set -e
  [[ "$refused_status" -eq 64 ]] || fail "Synthetic auth-key refusal exited $refused_status instead of 64."
  grep -Fq 'TS_AUTHKEY is refused' <<<"$refused_output" || fail 'Synthetic auth-key refusal was not explicit.'
fi

printf '[PASS] Container boot, health, runtime, Funnel isolation, persistence, and refusal checks (%s): %s\n' "$runtime_profile" "$image"
