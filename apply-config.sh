#!/bin/sh
# Minimal clean config for ZTE E8820V2 (64MB): flat LAN 172.30.10.0/24 (all
# ports, no VLANs) + isolated, rate-limited guest. 2x 5GHz AP at VHT40.
# Run on a factory-fresh unit. 20-min auto-rollback.
exec >/tmp/clean.log 2>&1
set -x
cp -a /etc/config /etc/config.pre-clean

cat > /tmp/rbclean.sh <<'RB'
#!/bin/sh
sleep 1200
[ -f /tmp/clean.ok ] && { logger -t cleanroll ok; exit 0; }
logger -t cleanroll revert
rm -rf /etc/config; cp -a /etc/config.pre-clean /etc/config; sync; reboot
RB
chmod +x /tmp/rbclean.sh
start-stop-daemon -S -b -x /bin/sh -- /tmp/rbclean.sh

# ensure 5GHz (mt76x2) PHY is present (flaky cold-boot); rebind controller if missing
have5g=""
for p in /sys/class/ieee80211/phy*; do
  [ "$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")" = mt76x2e ] && have5g=1
done
if [ -z "$have5g" ]; then
  echo 1e140000.pcie > /sys/bus/platform/drivers/mt7621-pci/unbind 2>/dev/null; sleep 1
  echo 1e140000.pcie > /sys/bus/platform/drivers/mt7621-pci/bind 2>/dev/null; sleep 5
  for d in 0000:01:00.0 0000:02:00.0; do [ -e /sys/bus/pci/devices/$d ] && echo 1 > /sys/bus/pci/devices/$d/remove 2>/dev/null; done
  sleep 1
fi

# ---- password + no IPv6 (save RAM) ----
printf '%s\n%s\n' '@Hammadar4549' '@Hammadar4549' | passwd root
uci -q delete network.wan6
/etc/init.d/odhcpd disable 2>/dev/null

# ---- NETWORK: flat LAN (all ports) + wifi-only guest bridge ----
uci set network.lan.ipaddr='172.30.10.1'
uci set network.lan.netmask='255.255.255.0'
uci -q delete network.lan.ip6assign
uci set network.brguest=device
uci set network.brguest.name='br-guest'
uci set network.brguest.type='bridge'
uci set network.guest=interface
uci set network.guest.device='br-guest'
uci set network.guest.proto='static'
uci set network.guest.ipaddr='172.30.20.1'
uci set network.guest.netmask='255.255.255.0'
uci commit network

# ---- DHCP ----
uci set dhcp.lan.start='100'; uci set dhcp.lan.limit='150'; uci set dhcp.lan.leasetime='12h'
uci -q delete dhcp.lan.dhcpv6; uci -q delete dhcp.lan.ra
uci set dhcp.guest=dhcp; uci set dhcp.guest.interface='guest'; uci set dhcp.guest.start='100'; uci set dhcp.guest.limit='100'; uci set dhcp.guest.leasetime='4h'
uci commit dhcp

# ---- FIREWALL: keep default lan+wan; add isolated guest zone ----
uci set firewall.guest=zone
uci set firewall.guest.name='guest'
uci set firewall.guest.input='REJECT'
uci set firewall.guest.output='ACCEPT'
uci set firewall.guest.forward='REJECT'
uci add_list firewall.guest.network='guest'
uci set firewall.guestwan=forwarding
uci set firewall.guestwan.src='guest'
uci set firewall.guestwan.dest='wan'
uci set firewall.gdhcp=rule; uci set firewall.gdhcp.name='Guest-DHCP'; uci set firewall.gdhcp.src='guest'; uci set firewall.gdhcp.proto='udp'; uci set firewall.gdhcp.dest_port='67'; uci set firewall.gdhcp.target='ACCEPT'
uci set firewall.gdns=rule;  uci set firewall.gdns.name='Guest-DNS';   uci set firewall.gdns.src='guest';  uci set firewall.gdns.proto='tcp udp'; uci set firewall.gdns.dest_port='53'; uci set firewall.gdns.target='ACCEPT'
uci commit firewall

# ---- WIRELESS: 5GHz-only VHT40, 2 APs ----
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.channel='36'
uci set wireless.radio0.htmode='VHT40'
uci set wireless.radio0.country='ID'
for p in /sys/class/ieee80211/phy*; do
  [ "$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")" = mt76x2e ] && uci set wireless.radio0.path="$(readlink -f "$p/device" | sed 's|/sys/devices/platform/||')"
done
uci -q delete wireless.default_radio0
uci set wireless.wmain=wifi-iface
uci set wireless.wmain.device='radio0'; uci set wireless.wmain.mode='ap'; uci set wireless.wmain.network='lan'
uci set wireless.wmain.ssid='Alfarel-Wifi'; uci set wireless.wmain.encryption='psk2'; uci set wireless.wmain.key='@Hammadar4549'
uci set wireless.wguest=wifi-iface
uci set wireless.wguest.device='radio0'; uci set wireless.wguest.mode='ap'; uci set wireless.wguest.network='guest'
uci set wireless.wguest.ssid='Alfarel-Wifi-Guest'; uci set wireless.wguest.encryption='none'; uci set wireless.wguest.isolate='1'
uci commit wireless

# ---- rc.local: 5GHz cold-boot recovery for future boots ----
cat > /etc/rc.local <<'RCL'
#!/bin/sh
( i=0; while [ $i -lt 20 ] && [ ! -d /sys/bus/platform/drivers/mt7621-pci/1e140000.pcie ]; do sleep 1; i=$((i+1)); done
  sleep 3
  have5g=""; for p in /sys/class/ieee80211/phy*; do [ "$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")" = mt76x2e ] && have5g=1; done
  if [ -z "$have5g" ]; then
    echo 1e140000.pcie > /sys/bus/platform/drivers/mt7621-pci/unbind 2>/dev/null; sleep 1
    echo 1e140000.pcie > /sys/bus/platform/drivers/mt7621-pci/bind 2>/dev/null; sleep 5
    for d in 0000:01:00.0 0000:02:00.0; do [ -e /sys/bus/pci/devices/$d ] && echo 1 > /sys/bus/pci/devices/$d/remove 2>/dev/null; done
  fi
  for p in /sys/class/ieee80211/phy*; do
    [ "$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")" = mt76x2e ] || continue
    uci set wireless.radio0.path="$(readlink -f "$p/device" | sed 's|/sys/devices/platform/||')"
  done
  uci -q commit wireless
  wifi up radio0 2>/dev/null
) &
exit 0
RCL
chmod +x /etc/rc.local

# ---- guest 5Mbps cap (nftables policer on br-guest; no shaping packages) ----
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/20-guest-qos.nft <<'QOS'
chain guest_qos {
    type filter hook forward priority 1; policy accept;
    oifname "br-guest" limit rate over 610 kbytes/second burst 128 kbytes drop comment "!fw4: guest 5Mbps down"
    iifname "br-guest" limit rate over 610 kbytes/second burst 128 kbytes drop comment "!fw4: guest 5Mbps up"
}
QOS

# ---- apply ----
uci commit
/etc/init.d/network restart
sleep 5
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
wifi reload
logger -t cleanroll "clean config applied"
echo CLEAN_DONE
