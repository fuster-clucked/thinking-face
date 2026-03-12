#!/bin/bash
set -o errexit -o nounset -o pipefail

exec 2>&1

cleanup() {
    trap - EXIT
    [[ -z ${AWS_CLI_DIR:-} ]] || rm --force --recursive "$AWS_CLI_DIR"
    [[ -z ${AWS_DCV_DIR:-} ]] || rm --force --recursive "$AWS_DCV_DIR"
    [[ -z ${GIT_ASKPASS:-} ]] || rm --force "$GIT_ASKPASS"
}

trap cleanup EXIT

export HOME=/root

curl --fail --show-error --location \
    https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
| gpg --dearmor --output /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl --fail --show-error --location \
    https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
| tee /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list
apt-get update > /dev/null
apt-get install --yes caddy unzip wireguard > /dev/null

if ! command -v aws >/dev/null 2>&1; then
    AWS_CLI_DIR=$(mktemp --directory)
    curl --fail --show-error --location \
        --output "$AWS_CLI_DIR/awscliv2.zip" \
        https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
    unzip -q \
        -d "$AWS_CLI_DIR" \
        "$AWS_CLI_DIR/awscliv2.zip"
    "$AWS_CLI_DIR/aws/install" \
        --install-dir /usr/local/lib/aws-cli \
        --bin-dir /usr/local/bin
fi

# Docker is already installed on GPU instances
if [ "${GPU,,}" != "true" ]; then
    # TODO install docker BuildKit for devcontainer (legacy builder is deprecated)
    apt-get install --yes docker.io > /dev/null
fi

AWS_DCV_DIR=$(mktemp --directory)

curl --fail --show-error --location \
    https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz \
| tar --extract --ungzip --directory "$AWS_DCV_DIR"

apt-get install --yes \
    "$AWS_DCV_DIR/nice-dcv-2025.0-20103-ubuntu2404-x86_64/nice-dcv-server_2025.0.20103-1_amd64.ubuntu2404.deb" \
    "$AWS_DCV_DIR/nice-dcv-2025.0-20103-ubuntu2404-x86_64/nice-xdcv_2025.0.688-1_amd64.ubuntu2404.deb" \
> /dev/null

# TODO don't require curl for code-server install
# TODO keep this version of devcontainer in sync with the version used in launch.yml
curl --fail --show-error --location \
    https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh \
| sh -s -- --version 0.88.0 --prefix=/usr/local

echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

WG_SERVER_KEY=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /wireguard/SERVER_KEY)

WG_CLIENT_PUB=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /wireguard/CLIENT_PUB)

mkdir --parents /etc/wireguard
cat > /etc/wireguard/wg0.conf << WG_CONF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $WG_SERVER_KEY
PostUp = iptables --append FORWARD --in-interface wg0 --jump ACCEPT; iptables --append FORWARD --out-interface wg0 --jump ACCEPT; iptables --table nat --append POSTROUTING --out-interface $(ip route | awk '/default/{print $5}') --jump MASQUERADE
PostDown = iptables --delete FORWARD --in-interface wg0 --jump ACCEPT; iptables --delete FORWARD --out-interface wg0 --jump ACCEPT; iptables --table nat --delete POSTROUTING --out-interface $(ip route | awk '/default/{print $5}') --jump MASQUERADE

[Peer]
AllowedIPs = 10.10.0.2/32
PublicKey = $WG_CLIENT_PUB
WG_CONF

mkdir --parents /etc/caddy
cat > /etc/caddy/Caddyfile << CADDY_CONF
thinkingface.lan {
    reverse_proxy unix//run/thinkingface/code-server.sock
    tls internal
}
CADDY_CONF

CADDY_CA_KEY=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /caddy/CA_KEY)

CADDY_CA_CRT=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /caddy/CA_CRT)

mkdir --parents /var/lib/caddy/.local/share/caddy/pki/authorities/local
echo "$CADDY_CA_KEY" > /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.key
echo "$CADDY_CA_CRT" > /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
chown --recursive caddy:caddy /var/lib/caddy/.local
chmod 600 /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.key

DCV_PASSWORD=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /thinkingface/DCV_PASSWORD)

printf 'dcv:%s\n' "$DCV_PASSWORD" | chpasswd

mkdir --parents /usr/local/libexec
cat > /usr/local/libexec/dcv-init << DCV_INIT
#!/bin/bash
set -o errexit -o nounset -o pipefail

exec sleep infinity
DCV_INIT
chmod 0755 /usr/local/libexec/dcv-init

cat > /usr/local/sbin/devcontainer-start << 'SYSD_BIN'
#!/bin/bash
set -o errexit -o nounset -o pipefail

dcv create-session \
    --user dcv \
    --owner dcv \
    --init /usr/local/libexec/dcv-init \
    workspace

for ((i = 1; i <= 30; i++)); do
    DCV_SESSION=$(dcv describe-session --json workspace)
    read -r DISPLAY XAUTHORITY < <(
        jq --raw-output '[.["x11-display"],.["x11-authority"]] | @tsv' <<< "$DCV_SESSION"
    )
    if [[ -n "$XAUTHORITY" && -f "$XAUTHORITY" ]]; then
        break
    fi
    if ((i == 30)); then
        echo "Attempt $i/30 ..."
        echo "$DCV_SESSION"
        exit 1
    fi
    echo "Attempt $i/30 ..."
    sleep 1
done

# TODO Xauthority should be bind-mount'ed as readonly
install --directory --owner=root --group=caddy --mode=2770 /run/thinkingface

xauth -f "$XAUTHORITY" nlist "$DISPLAY" \
    | sed 's/^..../ffff/' \
    | xauth -f /run/thinkingface/Xauthority nmerge -

export DISPLAY
export XAUTHORITY=/run/thinkingface/Xauthority

devcontainer up \
    --workspace-folder /root/workspace \
    --mount type=bind,source=/run/thinkingface,target=/run/thinkingface \
    --mount type=bind,source=/tmp/.X11-unix,target=/tmp/.X11-unix

CS_PASSWORD=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name /thinkingface/CS_PASSWORD)

printf '%s\n' \
    'socket: /run/thinkingface/code-server.sock' \
    'socket-mode: "0660"' \
    'auth: password' \
    "password: $CS_PASSWORD" \
    'cert: false' \
| devcontainer exec \
  --workspace-folder /root/workspace \
  sh -lc '
    set -o errexit -o nounset

    umask 077
    mkdir --parents "${XDG_CONFIG_HOME:-$HOME/.config}/code-server"
    cat > "${XDG_CONFIG_HOME:-$HOME/.config}/code-server/config.yaml"

    curl --fail --show-error --location \
        https://code-server.dev/install.sh \
    | sh -s -- --version 4.130.0

    code-server "$PWD"
  '
SYSD_BIN
chmod 0755 /usr/local/sbin/devcontainer-start

cat > /etc/systemd/system/devcontainer.service << SYSD_CONF
[Unit]
Requires=docker.service dcvserver.service
After=docker.service dcvserver.service network-online.target
Wants=network-online.target

[Service]
ExecStart=devcontainer-start

[Install]
WantedBy=multi-user.target
SYSD_CONF

GIT_ASKPASS=$(mktemp)
chmod 700 "$GIT_ASKPASS"

cat > "$GIT_ASKPASS" <<'ASKPASS'
#!/bin/bash
set -o errexit -o nounset -o pipefail

case "$1" in
    *Username*)
        printf '%s\n' 'x-access-token'
        ;;
    *Password*)
        printf '%s\n' "$GH_TOKEN"
        ;;
    *)
        printf '\n'
        ;;
esac
ASKPASS

GH_TOKEN=$(aws ssm get-parameter \
    --output text \
    --query 'Parameter.Value' \
    --with-decryption \
    --name "$TOKEN")

GIT_ASKPASS="$GIT_ASKPASS" \
GH_TOKEN="$GH_TOKEN" \
git clone \
    --branch "${REPO_REF#refs/heads/}" \
    "https://github.com/$REPO_NAME.git" \
    /root/workspace

systemctl disable --now ufw
sysctl --load
systemctl daemon-reload

# TODO some systemctl commands can be done in bulk or simpified (is-active, etc)

for SERVICE in \
    docker.service \
    wg-quick@wg0 \
    caddy \
    dcvserver \
    devcontainer.service
do
    systemctl enable "$SERVICE"
    if systemctl restart "$SERVICE"; then
        :
    else
        # TODO always send the service output, not just on failure
        journalctl --no-pager --output=short-precise --unit "$SERVICE" || true
        exit 1
    fi
done

for ((i = 1; i <= 30; i++)); do
    for SERVICE in \
        wg-quick@wg0 \
        caddy \
        dcvserver \
        devcontainer.service
    do
        STATUS=$(systemctl show --property=ActiveState --value "$SERVICE")
        case "$STATUS" in
            inactive|failed|deactivating)
                echo "Attempt $i/30 ..."
                # TODO always send the service output, not just on failure
                journalctl --no-pager --output=short-precise --unit "$SERVICE" || true
                exit 1
                ;;
        esac
    done

    if OUT=$(curl --fail --show-error --location --insecure \
        --resolve thinkingface.lan:443:127.0.0.1 \
        https://thinkingface.lan/healthz \
        2>&1
    ); then
        break
    else
        RC=$?
    fi

    if ((i == 30)); then
        echo "Attempt $i/30 ..."
        echo "$OUT" >&2
        exit $RC
    fi

    echo "Attempt $i/30 ..."
    sleep 5
done
