#!/bin/bash
# Starts Docker inside the lab container, loads the bundled images, then keeps running.
set -u
LOG=/var/log/lab-setup.log
rm -f /tmp/lab-ready /tmp/lab-failed

# Fixed address ranges so container IPs are the same on every laptop.
dind dockerd --host=unix:///var/run/docker.sock \
  --bip=10.200.0.1/24 \
  --default-address-pool base=10.201.0.0/16,size=24 \
  >/var/log/dockerd.log 2>&1 &
dockerd_pid=$!
trap 'kill -TERM "$dockerd_pid" 2>/dev/null; wait "$dockerd_pid"; exit 0' TERM INT

for _ in $(seq 1 90); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker did not start. See /var/log/dockerd.log" | tee -a "$LOG"
  touch /tmp/lab-failed
else
  ok=1
  for tar in /opt/lab/images/*.tar; do
    echo "Loading $tar" >>"$LOG"
    docker load -i "$tar" >>"$LOG" 2>&1 || ok=0
  done
  if [ "$ok" = 1 ]; then
    echo "Lab ready" >>"$LOG"
    touch /tmp/lab-ready
  else
    echo "Some images failed to load" >>"$LOG"
    touch /tmp/lab-failed
  fi
fi

wait "$dockerd_pid"
