
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG OVS_VERSION=""
ARG OVN_VERSION=""

RUN apt-get update &&     apt-get install -y --no-install-recommends       ca-certificates iproute2 iputils-ping iptables       procps netcat-openbsd dumb-init bash jq tini       openvswitch-common openvswitch-switch ${OVS_VERSION:+openvswitch-switch=${OVS_VERSION}}       ovn-common ovn-host ovn-central ${OVN_VERSION:+ovn-central=${OVN_VERSION}}       tcpdump dnsutils vim less &&     rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/openvswitch /var/lib/ovn /var/log/openvswitch /var/log/ovn     /etc/openvswitch /var/run/openvswitch /var/run/ovn

ENV PATH="/usr/share/openvswitch/scripts:/usr/share/ovn/scripts:${PATH}"

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/checks.sh /scripts/checks.sh
RUN chmod +x /entrypoint.sh /scripts/checks.sh

ENTRYPOINT ["/usr/bin/dumb-init","--"]
CMD ["/bin/bash","/entrypoint.sh"]
