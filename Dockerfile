# syntax=docker/dockerfile:1

# Behind a TLS-inspecting proxy, pass its root CA with:
#   docker build --secret id=extra_ca,src=/path/to/ca.pem ...
# It is only used by the download stages and never reaches the final image.

# ---------- Stage 1: container images used in the lab, saved as tar files ----------
FROM --platform=$BUILDPLATFORM alpine:3.22 AS images
ARG TARGETARCH
RUN apk add --no-cache skopeo
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then cat /run/secrets/extra_ca >> /etc/ssl/certs/ca-certificates.crt; fi \
 && mkdir -p /images \
 && skopeo copy --override-os linux --override-arch ${TARGETARCH} \
      docker://docker.io/kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5 \
      docker-archive:/images/kind-node.tar:kindest/node:v1.37.0 \
 && skopeo copy --override-os linux --override-arch ${TARGETARCH} \
      docker://docker.io/library/python:3.12-slim \
      docker-archive:/images/python.tar:python:3.12-slim \
 && skopeo copy --override-os linux --override-arch ${TARGETARCH} \
      docker://docker.io/library/busybox:1.36 \
      docker-archive:/images/busybox.tar:busybox:1.36 \
 && skopeo copy --override-os linux --override-arch ${TARGETARCH} \
      docker://registry.k8s.io/metrics-server/metrics-server:v0.9.0 \
      docker-archive:/images/metrics-server.tar:registry.k8s.io/metrics-server/metrics-server:v0.9.0

# ---------- Stage 2: kind, kubectl and the metrics-server manifest ----------
# kubectl is taken from the same kind node image, so its version matches the cluster.
FROM docker.io/kindest/node@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5 AS kubebin

FROM --platform=$BUILDPLATFORM alpine:3.22 AS tools
ARG TARGETARCH
ARG KIND_VERSION=v0.33.0
ARG METRICS_SERVER_VERSION=v0.9.0
RUN apk add --no-cache curl
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then cat /run/secrets/extra_ca >> /etc/ssl/certs/ca-certificates.crt; fi
RUN curl -fsSL --retry 3 --max-time 300 -o /kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
 && echo "$(curl -fsSL --retry 3 --max-time 60 "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}.sha256sum" | cut -d' ' -f1)  /kind" | sha256sum -c - \
 && chmod +x /kind
# kind's kubelets use self-signed certificates, so metrics-server must skip that check.
RUN curl -fsSL --retry 3 --max-time 120 -o /metrics-server.yaml "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
 && sed -i 's/^\( *\)- --metric-resolution=15s/\1- --metric-resolution=15s\n\1- --kubelet-insecure-tls/' /metrics-server.yaml \
 && grep -q -- '--kubelet-insecure-tls' /metrics-server.yaml

# ---------- Stage 3: Python wheels for the Spotify app, so it builds offline ----------
FROM python:3.12-slim AS wheels
RUN --mount=type=secret,id=extra_ca,required=false \
    cat /etc/ssl/certs/ca-certificates.crt > /tmp/ca.pem \
 && if [ -s /run/secrets/extra_ca ]; then cat /run/secrets/extra_ca >> /tmp/ca.pem; fi \
 && pip download --no-cache-dir --cert /tmp/ca.pem -d /wheels flask gunicorn \
 && rm /tmp/ca.pem

# ---------- Final lab image ----------
FROM docker:29-dind
RUN apk add --no-cache bash bash-completion curl iproute2 iptables util-linux procps \
      bind-tools jq python3 less vim nano
COPY --from=tools /kind /usr/local/bin/
COPY --from=kubebin /usr/bin/kubectl /usr/local/bin/
COPY --from=images /images /opt/lab/images
COPY lab /lab
COPY --from=wheels /wheels /lab/spotify-api/wheels
COPY --from=tools /metrics-server.yaml /lab/k8s/addons/metrics-server.yaml
COPY entrypoint.sh /usr/local/bin/lab-entrypoint
COPY bashrc /root/.bashrc
RUN chmod +x /usr/local/bin/lab-entrypoint
# Use the local Docker socket only; no TLS port is needed inside the lab.
ENV DOCKER_TLS_CERTDIR=
WORKDIR /lab
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
