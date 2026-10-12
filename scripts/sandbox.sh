#!/usr/bin/env bash
# scripts/sandbox.sh — detached Podman control for sparringhttp bench servers.
#
# Usage:
#   sandbox.sh start <kabelweb|fiber|aspnet|axum|all>   # detached container(s), equal limits
#   sandbox.sh stop  <kabelweb|fiber|aspnet|axum|all>
#   sandbox.sh build <kabelweb|fiber|aspnet|axum|all>   # rebuild binaries + bench image
#   sandbox.sh rebuild <kabelweb|fiber|aspnet|axum|all> # stop + build + start
#   sandbox.sh status                   # harness-owned containers only
#   sandbox.sh clean                    # stop+rm all sparringhttp_* containers
#
# Limits (equal spec, all frameworks): 2 CPUs, 512 MiB mem, no extra swap,
# 512 pids, nofile 4096:4096, loopback-only publish.
#
# Safety: only touches containers named sparringhttp_*. The user's
# pre-existing containers are never stopped or modified.
set -euo pipefail

NAME_PREFIX=sparringhttp_
PORT_HOST_KW=29590
PORT_HOST_FIBER=29591
PORT_HOST_ASPNET=29592
PORT_HOST_AXUM=29593
CONT_PORT=8080

CPUS=2
MEMORY=512m
PIDS=512
NOFILE=4096
IMAGE=docker.io/library/alpine:3.22

PROJECT=/home/ginwa/sparringhttp
IMAGE=localhost/sparringhttp-bench:latest
KW_CMD=/srv/kabelweb-bench
FIBER_CMD=/srv/fiber-bench
ASPNET_CMD=/srv/aspnet-bench
AXUM_CMD=/srv/axum-bench

# Fiber sizing must match the container quota: GOMAXPROCS=2 (cpu quota is
# NOT pinning — nproc inside still reports 16 host CPUs).
FIBER_ENV="GOMAXPROCS=2,GODEBUG=madvdontneed=1"
# Axum pins its Tokio worker pool to 2 threads in code (main.rs) for the same
# reason. ASP.NET Core is cgroup-aware since .NET 7 (ThreadPool/GC read
# cpu.max), so no pinning env is needed; invariant globalization is compiled
# in (no ICU needed in the bench image).

cid_of() { # framework -> container name
  case "$1" in
    kabelweb|fiber|aspnet|axum) echo "${NAME_PREFIX}$1" ;;
    *) echo "unknown framework: $1 (use kabelweb|fiber|aspnet|axum|all)" >&2; return 1 ;;
  esac
}

host_port_of() {
  case "$1" in
    kabelweb) echo "$PORT_HOST_KW" ;;
    fiber)    echo "$PORT_HOST_FIBER" ;;
    aspnet)   echo "$PORT_HOST_ASPNET" ;;
    axum)     echo "$PORT_HOST_AXUM" ;;
  esac
}

server_cmd_of() {
  case "$1" in
    kabelweb) echo "$KW_CMD" ;;
    fiber)    echo "$FIBER_CMD" ;;
    aspnet)   echo "$ASPNET_CMD" ;;
    axum)     echo "$AXUM_CMD" ;;
  esac
}

# Build the image first (see Containerfile):
#   mkdir -p /tmp/sparringhttp_img
#   cp bench/kabelweb/zig-out/bin/kabelweb-bench bin/fiber-bench \
#      bin/aspnet-bench bin/axum-bench /tmp/sparringhttp_img/
#   podman build -t localhost/sparringhttp-bench:latest -f scripts/Containerfile /tmp/sparringhttp_img

cmd_start() {
  local fw="$1" cname hport cmd
  cname=$(cid_of "$fw")
  hport=$(host_port_of "$fw")

  if podman container exists "$cname"; then
    echo "$cname already exists (status: $(podman inspect -f '{{.State.Status}}' "$cname"))"
    echo "run 'sandbox.sh stop $fw' first if you want a fresh start"
    exit 1
  fi

  if ! podman image exists "$IMAGE"; then
    echo "missing image $IMAGE — build it first:" >&2
    echo "  mkdir -p /tmp/sparringhttp_img" >&2
    echo "  cp bench/kabelweb/zig-out/bin/kabelweb-bench bin/fiber-bench bin/aspnet-bench bin/axum-bench /tmp/sparringhttp_img/" >&2
    echo "  podman build -t $IMAGE -f scripts/Containerfile /tmp/sparringhttp_img" >&2
    exit 1
  fi

  local -a env=()
  if [[ "$fw" == fiber ]]; then
    env=(-e "$FIBER_ENV")
  fi

  podman run -d \
    --name "$cname" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --memory-swap="$MEMORY" \
    --pids-limit="$PIDS" \
    --ulimit nofile="$NOFILE:$NOFILE" \
    -p "127.0.0.1:${hport}:29590" \
    "${env[@]}" \
    "$IMAGE" "$(server_cmd_of "$fw")"

  # Wait for readiness on the published loopback port (TCP connect).
  local deadline=$((SECONDS + 20)) ok=0
  while (( SECONDS < deadline )); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$hport") 2>/dev/null; then
      exec 3>&- 3<&- || true
      echo "$cname up on 127.0.0.1:$hport (pid $(podman inspect -f '{{.State.Pid}}' "$cname"))"
      return 0
    fi
    sleep 0.3
  done
  echo "$cname did not become ready in 20s; logs:" >&2
  podman logs "$cname" >&2 || true
  podman rm -f "$cname" >/dev/null 2>&1 || true
  return 1
}

cmd_stop() {
  local cname
  cname=$(cid_of "$1")
  if podman container exists "$cname"; then
    podman rm -f "$cname" >/dev/null
    echo "$cname stopped and removed"
  else
    echo "$cname not present (nothing to do)"
  fi
}

cmd_status() {
  echo "harness-owned containers (${NAME_PREFIX}*):"
  podman ps -a --filter "name=${NAME_PREFIX}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

cmd_start_all() {
  local fail=0 fw
  for fw in kabelweb fiber aspnet axum; do
    if podman container exists "${NAME_PREFIX}${fw}"; then
      echo "${NAME_PREFIX}${fw} already exists (status: $(podman inspect -f '{{.State.Status}}' "${NAME_PREFIX}${fw}")) — skipping"
      continue
    fi
    cmd_start "$fw" || fail=1
  done
  return $fail
}

cmd_stop_all() {
  for fw in kabelweb fiber aspnet axum; do
    cmd_stop "$fw"
  done
}

build_binary() { # fw -> rebuild bin/ artifact for one framework
  case "$1" in
    kabelweb)
      echo "[build] kabelweb (zig ReleaseFast)"
      (cd "$PROJECT/bench/kabelweb" && zig build -Doptimize=ReleaseFast)
      ;;
    fiber)
      echo "[build] fiber (go)"
      (cd "$PROJECT" && GOFLAGS=-mod=mod go build -trimpath -o bin/fiber-bench ./bench/fiber)
      ;;
    aspnet)
      echo "[build] aspnet (dotnet publish)"
      (cd "$PROJECT" && dotnet publish bench/aspnet/aspnet-bench.csproj -c Release -o bin/aspnet-publish && cp bin/aspnet-publish/aspnet-bench bin/aspnet-bench)
      ;;
    axum)
      echo "[build] axum (cargo release)"
      (cd "$PROJECT" && cargo build --release --manifest-path bench/axum/Cargo.toml && cp bench/axum/target/release/axum-bench bin/axum-bench)
      ;;
    *) echo "unknown framework: $1 (use kabelweb|fiber|aspnet|axum|all)" >&2; return 1 ;;
  esac
}

build_image() {
  echo "[build] bench image $IMAGE"
  mkdir -p /tmp/sparringhttp_img
  cp "$PROJECT/bench/kabelweb/zig-out/bin/kabelweb-bench" \
     "$PROJECT/bin/fiber-bench" \
     "$PROJECT/bin/aspnet-bench" \
     "$PROJECT/bin/axum-bench" /tmp/sparringhttp_img/
  # Microsoft.Data.Sqlite bundles its native engine as libe_sqlite3.so next
  # to the single-file binary; the binary probes its own dir (/srv/) at
  # runtime, so ship it alongside (see Containerfile COPY).
  cp "$PROJECT/bin/aspnet-publish/libe_sqlite3.so" /tmp/sparringhttp_img/ 2>/dev/null || true
  podman build -t "$IMAGE" -f "$PROJECT/scripts/Containerfile" /tmp/sparringhttp_img
}

cmd_build() { # fw|all -> rebuild binaries + image
  local target="${1:-all}"
  case "$target" in
    all) for fw in kabelweb fiber aspnet axum; do build_binary "$fw" || return 1; done ;;
    kabelweb|fiber|aspnet|axum) build_binary "$target" || return 1 ;;
    *) echo "unknown target: $target (use kabelweb|fiber|aspnet|axum|all)" >&2; return 1 ;;
  esac
  build_image
}

cmd_rebuild() { # fw|all -> stop + build + start
  local target="${1:-all}"
  case "$target" in
    all)
      cmd_stop_all
      cmd_build all || return 1
      cmd_start_all
      ;;
    kabelweb|fiber|aspnet|axum)
      cmd_stop "$target"
      cmd_build "$target" || return 1
      cmd_start "$target"
      ;;
    *) echo "unknown target: $target (use kabelweb|fiber|aspnet|axum|all)" >&2; return 1 ;;
  esac
}

cmd_clean() {
  local ids
  ids=$(podman ps -aq --filter "name=${NAME_PREFIX}" || true)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    podman rm -f $ids >/dev/null
    echo "removed harness containers"
  else
    echo "no harness containers present"
  fi
}

case "${1:-}" in
  start)
    shift
    case "${1:-}" in
      all) cmd_start_all ;;
      kabelweb|fiber|aspnet|axum) cmd_start "$1" ;;
      *) sed -n '2,12p' "$0"; exit 1 ;;
    esac
    ;;
  stop)
    shift
    case "${1:-}" in
      all) cmd_stop_all ;;
      kabelweb|fiber|aspnet|axum) cmd_stop "$1" ;;
      *) sed -n '2,12p' "$0"; exit 1 ;;
    esac
    ;;
  build)
    shift
    case "${1:-all}" in
      all) cmd_build all ;;
      kabelweb|fiber|aspnet|axum) cmd_build "$1" ;;
      *) sed -n '2,12p' "$0"; exit 1 ;;
    esac
    ;;
  rebuild)
    shift
    case "${1:-all}" in
      all) cmd_rebuild all ;;
      kabelweb|fiber|aspnet|axum) cmd_rebuild "$1" ;;
      *) sed -n '2,12p' "$0"; exit 1 ;;
    esac
    ;;
  status) cmd_status ;;
  clean)  cmd_clean ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
