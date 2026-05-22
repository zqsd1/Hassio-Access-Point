#!/usr/bin/with-contenv bashio

# Isolated Wi-Fi AP for Matter devices (HA OS addon, host network, Alpine).

AP_V6_ADDR="fd99:99::1"
AP_V6_PREFIX="fd99:99::/64"
RUN_HOSTAPD="/run/hostapd.conf"
RUN_DNSMASQ="/run/dnsmasq.conf"
RUN_NFT="/run/nftables.conf"

term_handler() {
	logger "Stopping Hass.io Access Point" 0
	killall hostapd 2>/dev/null || true
	killall dnsmasq 2>/dev/null || true
	nft delete table inet hassio_ap 2>/dev/null || true
	ip addr flush dev "$INTERFACE" 2>/dev/null || true
	ip -6 addr flush dev "$INTERFACE" 2>/dev/null || true
	if command -v nmcli >/dev/null 2>&1; then
		nmcli dev set "$INTERFACE" managed yes 2>/dev/null || true
	fi
	exit 0
}

logger() {
	msg=$1
	level=$2
	if [ "${DEBUG:-0}" -ge "$level" ]; then
		echo "$msg"
	fi
}

netmask_to_cidr() {
	local mask=$1
	local cidr=0 x
	IFS=. read -r _ a b c d <<< "$mask"
	for x in $a $b $c $d; do
		case $x in
			255) cidr=$((cidr + 8)) ;;
			254) cidr=$((cidr + 7)) ;;
			252) cidr=$((cidr + 6)) ;;
			248) cidr=$((cidr + 5)) ;;
			240) cidr=$((cidr + 4)) ;;
			224) cidr=$((cidr + 3)) ;;
			192) cidr=$((cidr + 2)) ;;
			128) cidr=$((cidr + 1)) ;;
			0) ;;
			*) bashio::exit.nok "Unsupported netmask: $mask" ;;
		esac
	done
	echo "$cidr"
}

ipv4_network() {
	# Network address for nftables (common home masks; avoids hex in bash)
	local ip=$1 prefix=$2
	local a b c d
	IFS=. read -r a b c d <<< "$ip"
	case "$prefix" in
		8)  printf '%s.0.0.0\n' "$a" ;;
		16) printf '%s.%s.0.0\n' "$a" "$b" ;;
		24) printf '%s.%s.%s.0\n' "$a" "$b" "$c" ;;
		*) bashio::exit.nok "Unsupported prefix /${prefix} for nftables (use /8, /16, or /24)" ;;
	esac
}

# host_network: true => these apply on the HA host, not a container-only stack
sysctl_set() {
	local key=$1 value=$2
	local proc_path="/proc/sys/${key//.//}"

	if [ -w "$proc_path" ] 2>/dev/null || [ -w "/proc/sys" ] 2>/dev/null; then
		if echo "$value" >"$proc_path" 2>/dev/null; then
			logger "Set ${key}=${value}" 1
			return 0
		fi
	fi
	if sysctl -qw "${key}=${value}" 2>/dev/null; then
		logger "Set ${key}=${value}" 1
		return 0
	fi
	logger "Warning: could not set ${key}=${value} (may need host tweak or extra caps)" 0
	return 1
}

apply_sysctl() {
	# Isolation: no L3 forwarding off the AP interface
	sysctl_set "net.ipv4.conf.${INTERFACE}.forwarding" 0 || true
	sysctl_set "net.ipv6.conf.${INTERFACE}.forwarding" 0 || true

	# Matter / IPv6 RA (see matter-server docs)
	# sysctl_set "net.ipv6.conf.${INTERFACE}.accept_ra" 1 || true
	# sysctl_set "net.ipv6.conf.${INTERFACE}.accept_ra_rt_info_max_plen" 64 || true
}

setup_interface() {
	logger "# Preparing interface $INTERFACE" 1

	# rfkill is not usable from the addon container; use NetworkManager on the host
	nmcli radio wifi on 2>/dev/null || true
	nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
	nmcli dev set "$INTERFACE" managed no 2>/dev/null || true

	ip link set "$INTERFACE" down 2>/dev/null || true
	ip addr flush dev "$INTERFACE" 2>/dev/null || true
	ip -6 addr flush dev "$INTERFACE" 2>/dev/null || true
	ip link set "$INTERFACE" up

	ip addr add "${ADDRESS}/${CIDR}" dev "$INTERFACE" broadcast "$BROADCAST"
	ip -6 addr add "${AP_V6_ADDR}/64" dev "$INTERFACE"

	apply_sysctl
}

write_hostapd_config() {
	cp /hostapd.conf "$RUN_HOSTAPD"
	sed -i \
		-e "s/^interface=.*/interface=${INTERFACE}/" \
		-e "s/^ssid=.*/ssid=${SSID}/" \
		-e "s/^wpa_passphrase=.*/wpa_passphrase=${WPA_PASSPHRASE}/" \
		-e "s/^channel=.*/channel=${CHANNEL}/" \
		-e "s/^ignore_broadcast_ssid=.*/ignore_broadcast_ssid=${HIDE_SSID}/" \
		"$RUN_HOSTAPD"

	if [ -n "${HT_CAPAB:-}" ]; then
		if grep -q '^ht_capab=' "$RUN_HOSTAPD"; then
			sed -i "s|^ht_capab=.*|ht_capab=${HT_CAPAB}|" "$RUN_HOSTAPD"
		else
			echo "ht_capab=${HT_CAPAB}" >> "$RUN_HOSTAPD"
		fi
	fi

	if [ ${#HOSTAPD_CONFIG_OVERRIDE[@]} -ge 1 ]; then
		for override in "${HOSTAPD_CONFIG_OVERRIDE[@]}"; do
			echo "$override" >> "$RUN_HOSTAPD"
		done
	fi
}

write_dnsmasq_config() {
	cp /dnsmasq.conf "$RUN_DNSMASQ"
	sed -i \
		-e "s/^interface=.*/interface=${INTERFACE}/" \
		-e "s|^dhcp-range=192.*|dhcp-range=${DHCP_START_ADDR},${DHCP_END_ADDR},${NETMASK},12h|" \
		-e "s|^dhcp-option=option:router,.*|dhcp-option=option:router,${ADDRESS}|" \
		-e "s|^dhcp-option=option:dns-server,.*|dhcp-option=option:dns-server,${ADDRESS}|" \
		-e "s|^ra-param=.*|ra-param=${INTERFACE},high,0,7200|" \
		-e "s|^dhcp-range=fd99:99::.*|dhcp-range=::2,::ff,constructor:${INTERFACE},ra-stateless,slaac,64,12h|" \
		"$RUN_DNSMASQ"

	if ! bashio::config.true "dhcp"; then
		sed -i '/^dhcp-range=192/d' "$RUN_DNSMASQ"
		sed -i '/^dhcp-option=option:router/d' "$RUN_DNSMASQ"
	fi

	if [ ${#CLIENT_DNS_OVERRIDE[@]} -ge 1 ]; then
		sed -i '/^dhcp-option=option:dns-server/d' "$RUN_DNSMASQ"
		dns_opt="dhcp-option=option:dns-server"
		for dns in "${CLIENT_DNS_OVERRIDE[@]}"; do
			dns_opt+=",${dns}"
		done
		echo "$dns_opt" >> "$RUN_DNSMASQ"
	fi

	if [ ${#DNSMASQ_CONFIG_OVERRIDE[@]} -ge 1 ]; then
		for override in "${DNSMASQ_CONFIG_OVERRIDE[@]}"; do
			echo "$override" >> "$RUN_DNSMASQ"
		done
	fi
}

write_nftables_config() {
	local ap_v4_net
	ap_v4_net="$(ipv4_network "$ADDRESS" "$CIDR")/${CIDR}"

	cp /nftables.conf "$RUN_NFT"
	sed -i \
		-e "s/define AP_IFACE = wlan0/define AP_IFACE = ${INTERFACE}/" \
		-e "s|define AP_V4_NET = 192.168.99.0/24|define AP_V4_NET = ${ap_v4_net}|" \
		"$RUN_NFT"
}

load_nftables() {
	nft delete table inet hassio_ap 2>/dev/null || true
	nft -f "$RUN_NFT"
}

SSID=$(bashio::config "ssid")
WPA_PASSPHRASE=$(bashio::config "wpa_passphrase")
CHANNEL=$(bashio::config "channel")
ADDRESS=$(bashio::config "address")
NETMASK=$(bashio::config "netmask")
BROADCAST=$(bashio::config "broadcast")
INTERFACE=$(bashio::config "interface")
HIDE_SSID=$(bashio::config.false "hide_ssid"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr")
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr")
DEBUG=$(bashio::config "debug")
HT_CAPAB=$(bashio::config "ht_capab" '[HT40][SHORT-GI-20][DSSS_CCK-40]')
HOSTAPD_CONFIG_OVERRIDE=($(bashio::config "hostapd_config_override"))
DNSMASQ_CONFIG_OVERRIDE=($(bashio::config "dnsmasq_config_override"))
CLIENT_DNS_OVERRIDE=($(bashio::config "client_dns_override"))

required_vars=(ssid wpa_passphrase channel address netmask broadcast interface)
for required_var in "${required_vars[@]}"; do
	bashio::config.require "$required_var" "An AP cannot be created without this information"
done

if [ ${#WPA_PASSPHRASE} -lt 8 ]; then
	bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

CIDR=$(netmask_to_cidr "$NETMASK")

echo "Starting Hass.io Access Point (isolated Matter AP)"
trap 'term_handler' SIGTERM

setup_interface
write_hostapd_config
write_dnsmasq_config
write_nftables_config
load_nftables

logger "## Starting dnsmasq (DNS, mDNS-friendly local zones, IPv6 RA)" 1
dnsmasq -C "$RUN_DNSMASQ" -k &
DNSMASQ_PID=$!

logger "## Starting hostapd" 1
if [ "$DEBUG" -gt 1 ]; then
	exec hostapd -d "$RUN_HOSTAPD"
else
	exec hostapd "$RUN_HOSTAPD"
fi
