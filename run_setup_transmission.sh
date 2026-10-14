#!/usr/bin/env bash
# Wrapper around run_setup.sh that:
#   - connects with WireGuard, port forwarding on, no dedicated IP
#   - picks the lowest latency port-forwarding region outside the UK,
#     skipping geolocated regions (shown as "(geo)" in the region name)
#   - sets transmission-daemon's peer port to the forwarded port
#
# PIA_USER/PIA_PASS are prompted for by run_setup.sh unless set in the environment.
#
# Optional environment variables:
#   MAX_LATENCY       max latency in seconds when testing regions (default 0.2)
#   EXCLUDE_COUNTRIES space separated country codes to skip (default "GB")
#   PIA_DNS           force PIA DNS (default true)
#   DISABLE_IPV6      disable IPv6 (default yes)
#   TR_HOST           transmission RPC host[:port] (default localhost:9091)
#   TR_AUTH           transmission RPC "user:password", if RPC auth is enabled

set -o pipefail

cd "$(dirname "$0")" || exit 1

if (( EUID != 0 )); then
  echo "This script needs to be run as root. Try again with 'sudo $0'"
  exit 1
fi

for cmd in curl jq wg; do
  if ! command -v "$cmd" >/dev/null; then
    echo "Required command '$cmd' was not found."
    exit 1
  fi
done

export MAX_LATENCY=${MAX_LATENCY:-0.2}
EXCLUDE_COUNTRIES=${EXCLUDE_COUNTRIES:-GB}
TR_HOST=${TR_HOST:-localhost:9091}

# Send a JSON request to transmission-daemon's RPC API and print the response.
# The daemon only accepts requests carrying the session id it hands out in the
# X-Transmission-Session-Id header, so fetch that first.
tr_rpc() {
  local url="http://$TR_HOST/transmission/rpc" auth=() sessionId
  [[ -n $TR_AUTH ]] && auth=(-u "$TR_AUTH")
  sessionId=$(curl -s -m 10 "${auth[@]}" -o /dev/null -D - "$url" |
    grep -i '^X-Transmission-Session-Id:' | awk '{print $2}' | tr -d '\r')
  curl -s -m 10 "${auth[@]}" -H "X-Transmission-Session-Id: $sessionId" -d "$1" "$url"
}

# Region ids in the excluded countries, plus all geolocated regions (their
# servers are not physically in the country the region is named after)
serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v6'
excludedRegions="$(curl -s "$serverlist_url" | head -1 |
  jq -r --arg countries "$EXCLUDE_COUNTRIES" \
  '($countries | split(" ")) as $c | .regions[] |
  select(.geo == true or (.country as $x | $c | index($x))) | .id')"
if [[ -z $excludedRegions ]]; then
  echo "Could not fetch the PIA server list."
  exit 1
fi

# Build the latency ordered list of port forwarding regions.
# PIA_USER/PIA_PASS are unset so get_region.sh stops before fetching a token.
echo "Testing port forwarding regions (excluding $EXCLUDE_COUNTRIES and geolocated regions)..."
env -u PIA_USER -u PIA_PASS -u PIA_TOKEN \
  PIA_PF=true PREFERRED_REGION=none VPN_PROTOCOL=no ./get_region.sh >/dev/null || exit 1

# latencyList is sorted by latency: "<time> <region id>\t<ip>\t<name>"
PREFERRED_REGION=""
while read -r _ regionId _; do
  if ! grep -qxF "$regionId" <<< "$excludedRegions"; then
    PREFERRED_REGION=$regionId
    break
  fi
done < /opt/piavpn-manual/latencyList

if [[ -z $PREFERRED_REGION ]]; then
  echo "No non-geolocated region outside $EXCLUDE_COUNTRIES responded within ${MAX_LATENCY}s."
  echo "Try a higher timeout, for example: sudo MAX_LATENCY=1 $0"
  exit 1
fi
echo "Selected region: $(grep -P "^\S+ \Q$PREFERRED_REGION\E\t" /opt/piavpn-manual/latencyList)"
echo

# Hard coded connection settings. AUTOCONNECT must stay unset, or run_setup.sh
# ignores PREFERRED_REGION and picks the lowest latency region itself.
unset AUTOCONNECT
export PREFERRED_REGION
export VPN_PROTOCOL=wireguard
export PIA_PF=true
export DIP_TOKEN=no
export PIA_DNS=${PIA_DNS:-true}
export DISABLE_IPV6=${DISABLE_IPV6:-yes}

set_transmission_port() {
  local port=$1
  echo "Setting transmission-daemon peer port to $port"
  if [[ $(tr_rpc '{"method":"session-set","arguments":{"peer-port":'"$port"'}}' |
        jq -r '.result' 2>/dev/null) != "success" ]]; then
    echo "Failed to set the peer port via http://$TR_HOST/transmission/rpc"
    return
  fi
  echo "Port is open: $(tr_rpc '{"method":"port-test"}' | jq -r '.arguments."port-is-open"')"
}

# port_forwarding.sh prints "Forwarded port<TAB><port>" each time it refreshes
# the binding (every 15 minutes) and keeps running, so watch its output
# rather than waiting for it to exit.
watch_port() {
  local line currentPort=""
  while IFS= read -r line; do
    line=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$line")
    if [[ $line =~ ^Forwarded\ port[[:space:]]+([0-9]+) ]] &&
       [[ ${BASH_REMATCH[1]} != "$currentPort" ]]; then
      currentPort=${BASH_REMATCH[1]}
      set_transmission_port "$currentPort"
    fi
  done
}

./run_setup.sh | tee >(watch_port)
