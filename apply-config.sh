#!/bin/sh
# Full all-in-one config for ZTE E8820V2 on OpenWrt 23.05 (5GHz-only):
# 5 VLANs + firewall + DHCP + a stable 5GHz AP at VHT40 (VHT80 OOMs the 64MB
# board's DMA -> mt76 restart loop). Detached with an 8-min auto-rollback.
exec >/tmp/apply-2305.log 2>&1
set -x

cp -a /etc/config /etc/config.pre-vlan

cat > /tmp/rollback.sh <<'RB'
#!/bin/sh
sleep 480
[ -f /tmp/vlan.ok ] && { logger -t vlanroll "confirmed"; exit 0; }
logger -t vlanroll "reverting"
rm -rf /etc/config; cp -a /etc/config.pre-vlan /etc/config; sync; reboot
RB
chmod +x /tmp/rollback.sh
setsid /tmp/rollback.sh >/dev/null 2>&1 &

WKEY='@Hammadar4549'
CC='ID'

# ================= NETWORK (DSA bridge VLANs) =================
uci -q delete network.lan
uci set network.@device[0].vlan_filtering='1'

# Port layout: LAN1+LAN2 = trunks (all VLANs tagged); LAN3 = Servers access
# (untagged 40); LAN4 = Trusted access (untagged 10).
uci -q delete network.v1;  uci set network.v1=bridge-vlan;  uci set network.v1.device='br-lan';  uci set network.v1.vlan='1'
uci add_list network.v1.ports='lan1:t'; uci add_list network.v1.ports='lan2:t'
uci -q delete network.v10; uci set network.v10=bridge-vlan; uci set network.v10.device='br-lan'; uci set network.v10.vlan='10'
uci add_list network.v10.ports='lan4:u*'; uci add_list network.v10.ports='lan1:t'; uci add_list network.v10.ports='lan2:t'
uci -q delete network.v20; uci set network.v20=bridge-vlan; uci set network.v20.device='br-lan'; uci set network.v20.vlan='20'
uci add_list network.v20.ports='lan1:t'; uci add_list network.v20.ports='lan2:t'
uci -q delete network.v30; uci set network.v30=bridge-vlan; uci set network.v30.device='br-lan'; uci set network.v30.vlan='30'
uci add_list network.v30.ports='lan1:t'; uci add_list network.v30.ports='lan2:t'
uci -q delete network.v40; uci set network.v40=bridge-vlan; uci set network.v40.device='br-lan'; uci set network.v40.vlan='40'
uci add_list network.v40.ports='lan3:u*'; uci add_list network.v40.ports='lan1:t'; uci add_list network.v40.ports='lan2:t'

uci set network.mgmt=interface;    uci set network.mgmt.device='br-lan.1';    uci set network.mgmt.proto='static';    uci set network.mgmt.ipaddr='10.0.1.1';    uci set network.mgmt.netmask='255.255.255.0'
uci set network.trusted=interface; uci set network.trusted.device='br-lan.10'; uci set network.trusted.proto='static'; uci set network.trusted.ipaddr='10.0.10.1'; uci set network.trusted.netmask='255.255.255.0'
uci set network.iot=interface;     uci set network.iot.device='br-lan.20';    uci set network.iot.proto='static';     uci set network.iot.ipaddr='10.0.20.1';    uci set network.iot.netmask='255.255.255.0'
uci set network.guest=interface;   uci set network.guest.device='br-lan.30';  uci set network.guest.proto='static';   uci set network.guest.ipaddr='10.0.30.1';  uci set network.guest.netmask='255.255.255.0'
uci set network.servers=interface; uci set network.servers.device='br-lan.40'; uci set network.servers.proto='static'; uci set network.servers.ipaddr='10.0.40.1'; uci set network.servers.netmask='255.255.255.0'

# ================= DHCP =================
uci -q delete dhcp.lan
for z in mgmt trusted iot guest servers; do
  uci set dhcp.$z=dhcp; uci set dhcp.$z.interface="$z"; uci set dhcp.$z.start='100'; uci set dhcp.$z.leasetime='12h'
done
uci set dhcp.mgmt.limit='50'; uci set dhcp.trusted.limit='100'; uci set dhcp.iot.limit='100'; uci set dhcp.guest.limit='100'; uci set dhcp.servers.limit='50'

# ================= FIREWALL =================
i=15; while [ $i -ge 0 ]; do
  s=$(uci -q get firewall.@forwarding[$i].src); d=$(uci -q get firewall.@forwarding[$i].dest)
  { [ "$s" = "lan" ] || [ "$d" = "lan" ]; } && uci -q delete firewall.@forwarding[$i]; i=$((i-1))
done
i=15; while [ $i -ge 0 ]; do
  n=$(uci -q get firewall.@zone[$i].name); [ "$n" = "lan" ] && uci -q delete firewall.@zone[$i]; i=$((i-1))
done
for z in trusted mgmt; do
  uci set firewall.$z=zone; uci set firewall.$z.name="$z"; uci set firewall.$z.input='ACCEPT'; uci set firewall.$z.output='ACCEPT'; uci set firewall.$z.forward='REJECT'; uci add_list firewall.$z.network="$z"
done
for z in iot guest servers; do
  uci set firewall.$z=zone; uci set firewall.$z.name="$z"; uci set firewall.$z.input='REJECT'; uci set firewall.$z.output='ACCEPT'; uci set firewall.$z.forward='REJECT'; uci add_list firewall.$z.network="$z"
done
addfwd(){ n="fwd_$1_$2"; uci set firewall.$n=forwarding; uci set firewall.$n.src="$1"; uci set firewall.$n.dest="$2"; }
addfwd trusted wan; addfwd trusted iot; addfwd trusted servers; addfwd trusted mgmt
addfwd mgmt wan; addfwd mgmt trusted; addfwd mgmt iot; addfwd mgmt servers
addfwd guest wan; addfwd servers wan; addfwd iot wan
for z in iot guest servers; do
  uci set firewall.dhcp_$z=rule; uci set firewall.dhcp_$z.name="Allow-DHCP-$z"; uci set firewall.dhcp_$z.src="$z"; uci set firewall.dhcp_$z.proto='udp'; uci set firewall.dhcp_$z.dest_port='67'; uci set firewall.dhcp_$z.target='ACCEPT'
  uci set firewall.dns_$z=rule;  uci set firewall.dns_$z.name="Allow-DNS-$z";  uci set firewall.dns_$z.src="$z";  uci set firewall.dns_$z.proto='tcp udp'; uci set firewall.dns_$z.dest_port='53'; uci set firewall.dns_$z.target='ACCEPT'
done

# ================= WIRELESS (5GHz-only, VHT40 for stability) =================
# reconcile the 5GHz radio to its current PHY (path shifts between boots)
for p in /sys/class/ieee80211/phy*; do
  [ "$(basename "$(readlink -f "$p/device/driver" 2>/dev/null)")" = mt76x2e ] || continue
  path=$(readlink -f "$p/device" | sed 's|/sys/devices/platform/||')
  uci set wireless.radio0.path="$path"
done
uci set wireless.radio0.type='mac80211'
uci set wireless.radio0.band='5g'
uci set wireless.radio0.channel='36'
uci set wireless.radio0.htmode='VHT40'
uci set wireless.radio0.country="$CC"
uci set wireless.radio0.disabled='0'
uci -q delete wireless.default_radio0
uci -q delete wireless.ap5
uci set wireless.wlan_trusted=wifi-iface
uci set wireless.wlan_trusted.device='radio0'
uci set wireless.wlan_trusted.mode='ap'
uci set wireless.wlan_trusted.network='trusted'
uci set wireless.wlan_trusted.ssid='Alfarel-Home'
uci set wireless.wlan_trusted.encryption='psk2'
uci set wireless.wlan_trusted.key="$WKEY"
# Guest AP -> Guest VLAN, client-isolated (2 BSS is the practical max on 64MB)
uci set wireless.wlan_guest=wifi-iface
uci set wireless.wlan_guest.device='radio0'
uci set wireless.wlan_guest.mode='ap'
uci set wireless.wlan_guest.network='guest'
uci set wireless.wlan_guest.ssid='Alfarel-Home-Guest'
uci set wireless.wlan_guest.encryption='psk2'
uci set wireless.wlan_guest.key="$WKEY"
uci set wireless.wlan_guest.isolate='1'

uci commit

# ================= APPLY =================
/etc/init.d/network restart
sleep 5
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
wifi reload
logger -t vlanroll "apply-2305 complete"
echo APPLY_DONE
