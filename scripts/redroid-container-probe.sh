#!/usr/bin/env bash
set -euo pipefail

out="${1:-diagnostics}"
container="redroid"
mkdir -p "$out"

for attempt in $(seq 1 24); do
  running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
  boot_completed=""
  if [[ "$running" == "true" ]]; then
    boot_completed="$(
      timeout --kill-after=2s 5s docker exec "$container" \
        /system/bin/getprop sys.boot_completed 2>>"$out/container-getprop-errors.txt" \
        | tr -d '\r' || true
    )"
  fi
  printf 'attempt=%s running=%s boot_completed=%q\n' \
    "$attempt" "$running" "$boot_completed" \
    | tee -a "$out/container-boot-progress.txt"
  if [[ "$boot_completed" == "1" ]]; then
    docker exec "$container" /system/bin/getprop > "$out/container-getprop.txt"
    exit 0
  fi
  if [[ "$running" != "true" ]]; then
    break
  fi
  sleep 2
done

docker ps -a --no-trunc > "$out/docker-ps-preflight.txt" 2>&1 || true
docker inspect "$container" > "$out/redroid-inspect-preflight.json" 2>&1 || true
docker logs --timestamps "$container" > "$out/redroid-preflight.log" 2>&1 || true
timeout --kill-after=2s 10s docker exec "$container" /system/bin/ps -A \
  > "$out/container-ps.txt" 2>&1 || true
echo "Android inside Redroid did not complete boot" >&2
exit 2
