# Use a recent OVN image that includes ovsdb-tool with --cluster-local-addr support
FROM openvswitch/ovn:25.03.1

ARG DEBIAN_FRONTEND=noninteractive

# Ensure OVS userspace is available (if base image doesn't already include it)
# We try Debian/Ubuntu; if unavailable, you can comment this and build OVS from source.
RUN apt-get update || true && apt-get install -y --no-install-recommends       openvswitch-switch openvswitch-common iproute2 iputils-ping iptables       procps netcat-openbsd dumb-init bash jq tcpdump dnsutils vim less     && rm -rf /var/lib/apt/lists/* || true

# Create required dirs
RUN mkdir -p /var/lib/openvswitch /var/lib/ovn /var/log/openvswitch /var/log/ovn     /etc/openvswitch /var/run/openvswitch /var/run/ovn

ENV PATH="/usr/share/openvswitch/scripts:/usr/share/ovn/scripts:${PATH}"

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/checks.sh /scripts/checks.sh
RUN chmod +x /entrypoint.sh /scripts/checks.sh

ENTRYPOINT ["/usr/bin/dumb-init","--"]
CMD ["/bin/bash","/entrypoint.sh"]
