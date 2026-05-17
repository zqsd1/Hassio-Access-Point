#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

bashio::log.level "$(bashio::config 'log_level')"

# Enforces required env variables
required_vars=(ssid wpa_passphrase channel address)
for required_var in "${required_vars[@]}"; do
    bashio::config.require "$required_var" "An AP cannot be created without this information"
done

WPA_PASSPHRASE="$(bashio::config 'wpa_passphrase')"

if (( ${#WPA_PASSPHRASE} < 8 )); then
    bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

debug_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        bashio::log.error "File not found: $file"
        return
    fi

    bashio::log.debug "===== $file ====="

    while IFS= read -r line; do
        bashio::log.debug "$line"
    done < "$file"
}

CLEANED_UP=false
# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
    if $CLEANED_UP; then
        return
    fi
    CLEANED_UP=true
	bashio::log.warning "Stopping Hass.io Access Point"
    bashio::log.warning "cleanup"

    killall hostapd 2>/dev/null || true
    killall dnsmasq 2>/dev/null || true

	nmcli connection delete hassio-access-point 2>/dev/null || true

    # nft delete table inet matter 2>/dev/null || true

	exit 0
}

dry_run(){
    bashio::log.info  "start dry run, make sure to enable debug logs"
    config_dnsmasq
    debug_file /dnsmasq.conf
    config_hostapd
    debug_file /hostapd.conf
    config_nft
    debug_file /nftables.conf
    exit 0

}

# cidr2mask(){
#     local prefix=$1
#     local shift=$(( 32 - prefix ))
#     local bits
#     # start with 32 bits to 1, shift left to match the /24 , trim extra bits with mask so it stay 32bits
#     bits=$(( 0xffffffff << shift & 0xffffffff ))

#     printf "%d.%d.%d.%d\n" \
#         $(( (bits >> 24) & 0xff )) \
#         $(( (bits >> 16) & 0xff )) \
#         $(( (bits >> 8)  & 0xff )) \
#         $(( bits & 0xff ))
# }



SSID=$(bashio::config "ssid")
WPA_PASSPHRASE=$(bashio::config "wpa_passphrase")
CHANNEL=$(bashio::config "channel")
ADDRESS=$(bashio::config "address")
PREFIX=$(bashio::config "subnet_prefix")

INTERFACE=$(bashio::config "interface")
HIDE_SSID=$(bashio::config.false "hide_ssid"; echo $?)
DHCP=$(bashio::config.false "dhcp"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr" )
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr" )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )
ALLOW_MAC_ADDRESSES=$(bashio::config 'allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'deny_mac_addresses' )
DEBUG=$(bashio::config 'log_level' )
HT_CAPAB=$(bashio::config 'ht_capab' '[HT40][SHORT-GI-20][DSSS_CCK-40]')
HOSTAPD_CONFIG_OVERRIDE=$(bashio::config 'hostapd_config_override' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'client_dns_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )
# Get the Default Route interface
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5 }')
IP_CIDR="${ADDRESS}/${PREFIX}"
# NETMASK=cidr2mask "${PREFIX}"


config_nm(){
    # nmcli device set "${INTERFACE}" managed no
    # ip link set "${INTERFACE}" down
    # ip addr flush dev "${INTERFACE}"
    # iw dev "${INTERFACE}" set type managed
    # ip link set "${INTERFACE}" up
    # ip addr add "${IP_CIDR}" dev "${INTERFACE}"

    # bashio::log.debug "state before create"
    # nmcli device status
    # nmcli device wifi list
    # nmcli device show "$INTERFACE"
    # iw dev "$INTERFACE" info

    # bashio::log.info "create nmcli connection"
    nmcli connection add \
        type wifi \
        ifname "${INTERFACE}" \
        con-name hassio-access-point \
        autoconnect no \
        ssid "${SSID}"

    bashio::log.info "modify nmcli connection"

    bashio::log.info "set access point mode"
    nmcli connection modify hassio-access-point \
        802-11-wireless.mode ap \
        802-11-wireless.band bg \
        802-11-wireless.channel "$CHANNEL"

    bashio::log.info "set access point security"
    nmcli connection modify hassio-access-point \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$WPA_PASSPHRASE" \
        wifi-sec.proto rsn \
        wifi-sec.group ccmp \
        wifi-sec.pairwise ccmp

    bashio::log.info "set access point network config"
    nmcli connection modify hassio-access-point \
        ipv4.method manual \
        ipv4.addresses "${IP_CIDR}" \
        ipv4.never-default yes \
        ipv6.method disabled

    # nmcli connection modify hassio-access-point 802-11-wireless-security.pmf 1
    nmcli connection modify hassio-access-point \
        802-11-wireless.powersave 2

    bashio::log.info "up nmcli connection"
    iw reg set FR
    nmcli connection up hassio-access-point
}

config_dnsmasq(){
    {
cat <<EOF
interface=$INTERFACE
no-resolv
bind-interfaces
bogus-priv
domain-needed

dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,24h
#dhcp-option=3,$ADDRESS #gateway
dhcp-option=6,$ADDRESS #dns server
dhcp-option=42,$ADDRESS #ntp server
EOF
    } > /dnsmasq.conf
}
config_hostapd(){
        {
cat <<EOF
interface=$INTERFACE
ssid=$SSID
wpa_passphrase=$WPA_PASSPHRASE
channel=$CHANNEL
ignore_broadcast_ssid=$HIDE_SSID
hw_mode=g

driver=nl80211

ieee80211n=1
wmm_enabled=1

auth_algs=1

wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ieee80211d=1
country_code=FR

logger_stdout=-1
logger_stdout_level=2
EOF
    } > /hostapd.conf
}

config_nft(){
    {
        cat <<EOF
#!/usr/sbin/nft -f

table inet matter {
    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }

    chain input {
        type filter hook input priority 0;
        policy accept;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}

EOF

    }> /nftables.conf
}

echo "Starting Hass.io Access Point Addon"
# Setup signal handlers
trap 'term_handler' SIGTERM
trap 'term_handler' EXIT

if bashio::config.true 'dry_run';then
    dry_run
fi

# Setup interface
bashio::log.info "set nmcli connection interface"
config_nm

bashio::log.info "config dnsmasq"
config_dnsmasq
debug_file /dnsmasq.conf

bashio::log.info "config hostpad"
config_hostapd
debug_file /hostapd.conf

bashio::log.info "config nftables"
config_nft
debug_file /nftables.conf

bashio::log.info "remove maybe old nftable rule"
nft delete table inet matter 2>/dev/null || true
bashio::log.info "active nft rules"
# nft -f /nftables.conf

# Start dnsmasq if DHCP is enabled in config
if bashio::config.true "dhcp"; then
    bashio::log.info "## Starting dnsmasq daemon"
    # dnsmasq -C /dnsmasq.conf
fi



bashio::log.info "## Starting hostapd daemon"
# rfkill unblock wifi 2>/dev/null || true
# If debug level is greater than 1, start hostapd in debug mode
# if [ "$DEBUG" == "debug" ]; then
#     hostapd -d /hostapd.conf
# else
#     hostapd /hostapd.conf 
# fi
bashio::log.debug "===== nmcli connection ====="
ip a show "$INTERFACE"
nmcli -f ALL device wifi show-password
nmcli device wifi list
nmcli device show "$INTERFACE"
iw dev "$INTERFACE" info
iw dev
ip route
nmcli -f 802-11-wireless-security connection show hassio-access-point
# nmcli device monitor "$INTERFACE"

bashio::log.info "setup finished, sleep till the end of the world ....."
sleep infinity &
wait $!
