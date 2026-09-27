# Testsystem mit systemd für den Integrationstest (siehe .github/workflows/ci.yml)
ARG IMAGE=debian:12
FROM ${IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server iproute2 python3 ca-certificates curl \
 && rm -f /etc/machine-id && touch /etc/machine-id \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
