#!/bin/bash
set -o errexit -o nounset -o pipefail

exec 2>&1

cleanup() {
    trap - EXIT
    systemctl unmask --runtime apt-daily.timer apt-daily-upgrade.timer
    [[ -z ${AWS_CLI_DIR:-} ]] || rm --force --recursive "$AWS_CLI_DIR"
    [[ -z ${AWS_DCV_DIR:-} ]] || rm --force --recursive "$AWS_DCV_DIR"
    [[ -z ${GIT_ASKPASS:-} ]] || rm --force "$GIT_ASKPASS"
}

trap cleanup EXIT
systemctl mask --runtime --now apt-daily.timer apt-daily-upgrade.timer

export HOME=/root

curl --fail --show-error --location \
    https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
| gpg --dearmor --output /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl --fail --show-error --location \
    https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
| tee /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list

AWS_DCV_DIR=$(mktemp --directory)
curl --fail --show-error --location \
    https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz \
| tar --extract --ungzip --directory "$AWS_DCV_DIR"

apt-get update > /dev/null
apt-get install --yes \
    caddy unzip wireguard \
    "$AWS_DCV_DIR/nice-dcv-2025.0-20103-ubuntu2404-x86_64/nice-dcv-server_2025.0.20103-1_amd64.ubuntu2404.deb" \
> /dev/null

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
    apt-get install --yes \
        docker.io \
        "$AWS_DCV_DIR/nice-dcv-2025.0-20103-ubuntu2404-x86_64/nice-xdcv_2025.0.688-1_amd64.ubuntu2404.deb" \
    > /dev/null
else
    apt-get install --yes xserver-xorg-core x11-xserver-utils xinit > /dev/null
fi

# TODO don't require curl for code-server install
# TODO keep this version of devcontainer in sync with the version used in launch.yml
curl --fail --show-error --location \
    https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh \
| sh -s -- --version 0.88.0 --prefix=/usr/local

if [[ ${WIREGUARD:-false} == true ]]; then
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
    chmod 0600 /etc/wireguard/wg0.conf
fi

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
install --directory --owner=root --group=caddy --mode=2771 /run/thinkingface

cat > /usr/local/libexec/keepalive <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail

exec sleep infinity
EOF
chmod 0755 /usr/local/libexec/keepalive

if [[ ${GPU,,} == true ]]; then
    nvidia-xconfig \
        --preserve-busid \
        --enable-all-gpus \
        --allow-empty-initial-configuration

    cat > /etc/systemd/system/xorg.service << 'SYSD_CONF'
[Unit]
After=systemd-modules-load.service

[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/thinkingface/Xauthority
ExecStartPre=/bin/bash -c 'COOKIE=$(/usr/bin/mcookie); /usr/bin/xauth -f "$XAUTHORITY" add "$DISPLAY" . "$COOKIE"; /usr/bin/chown dcv:caddy "$XAUTHORITY"; /usr/bin/chmod 0640 "$XAUTHORITY"'
ExecStart=/usr/bin/xinit \
    /usr/local/libexec/keepalive \
    -- \
    /usr/lib/xorg/Xorg \
    :0 \
    -auth /run/thinkingface/Xauthority \
    -config /etc/X11/xorg.conf \
    -nolisten tcp \
    -noreset
ExecStartPost=/bin/bash -c 'for ((i = 1; i <= 30; i++)); do /usr/bin/xset q >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=multi-user.target
SYSD_CONF
fi

cat > /usr/local/libexec/dcv-session-create << 'SYSD_BIN'
#!/bin/bash
set -o errexit -o nounset -o pipefail

if [ "${GPU,,}" != "true" ]; then
    dcv create-session \
        --user dcv \
        --owner dcv \
        --init /usr/local/libexec/keepalive \
        workspace
else
    dcv create-session \
        --type=console \
        --owner dcv \
        workspace
fi
SYSD_BIN
chmod 0755 /usr/local/libexec/dcv-session-create

cat > /usr/local/libexec/dcv-session-run << 'SYSD_BIN'
#!/bin/bash
set -o errexit -o nounset -o pipefail

if [ "${GPU,,}" != "true" ]; then
    exec sleep infinity
else
    export DISPLAY=:0
    export XAUTHORITY=/run/thinkingface/Xauthority
    export XDG_SESSION_TYPE=x11
    export XDG_SESSION_CLASS=user
    exec dbus-run-session -- \
        /bin/bash -c '/usr/lib/x86_64-linux-gnu/dcv/dcvxdgagentlauncher --session-id=workspace --ignore-events; exec sleep infinity'
fi
SYSD_BIN
chmod 0755 /usr/local/libexec/dcv-session-run

DCV_DEPS=dcvserver.service
if [[ ${GPU,,} == true ]]; then
    DCV_DEPS+=' xorg.service'
fi

cat > /etc/systemd/system/dcv-session.service << SYSD_CONF
[Unit]
Requires=$DCV_DEPS
After=$DCV_DEPS

[Service]
User=dcv
PAMName=login
Environment=GPU=${GPU,,}
ExecStartPre=+/usr/local/libexec/dcv-session-create
ExecStart=/usr/local/libexec/dcv-session-run
ExecStopPost=-+/usr/bin/dcv close-session workspace
SYSD_CONF

cat > /usr/local/sbin/devcontainer-start << 'SYSD_BIN'
#!/bin/bash
set -o errexit -o nounset -o pipefail

for ((i = 1; i <= 30; i++)); do
    if [ "${GPU,,}" != "true" ]; then
        DCV_SESSION=$(dcv describe-session --json workspace)
        read -r DISPLAY XAUTHORITY < <(
            jq --raw-output '[.["x11-display"],.["x11-authority"]] | @tsv' <<< "$DCV_SESSION"
        )
        if [[ -n "$XAUTHORITY" && -f "$XAUTHORITY" ]]; then
            break
        fi
    else
        if DISPLAY=:0 XAUTHORITY=/run/thinkingface/Xauthority xset q; then
            DISPLAY=:0
            XAUTHORITY=/run/thinkingface/Xauthority
            break
        fi
    fi
    if ((i == 30)); then
        echo "Attempt $i/30 ..."
        if [ "${GPU,,}" != "true" ]; then
            echo "$DCV_SESSION"
        fi
        exit 1
    fi
    echo "Attempt $i/30 ..."
    sleep 1
done

XAUTH_ENTRY=$(
    xauth -f "$XAUTHORITY" nlist "$DISPLAY" \
        | sed 's/^..../ffff/'
)
printf '%s\n' "$XAUTH_ENTRY" \
    | xauth -f /run/thinkingface/Xauthority nmerge -
chown dcv:caddy /run/thinkingface/Xauthority
chmod 0640 /run/thinkingface/Xauthority

export DISPLAY
export XAUTHORITY=/run/thinkingface/Xauthority

# TODO Xauthority should be bind-mount'ed as readonly
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
Requires=docker.service dcv-session.service
After=docker.service dcv-session.service network-online.target
Wants=network-online.target

[Service]
Environment=GPU=${GPU,,}
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

SERVICES=(
    docker.service
    caddy
)
if [[ ${WIREGUARD:-false} == true ]]; then
    SERVICES+=(wg-quick@wg0)
fi
if [[ ${GPU,,} == true ]]; then
    SERVICES+=(xorg.service)
fi
SERVICES+=(
    dcvserver.service
    devcontainer.service
)

# TODO some systemctl commands can be done in bulk or simpified (is-active, etc)
for SERVICE in "${SERVICES[@]}"; do
    systemctl enable "$SERVICE"
    if systemctl restart "$SERVICE"; then
        :
    else
        # TODO always send the service output, not just on failure
        journalctl --no-pager --output=short-precise --unit "$SERVICE" || true
        exit 1
    fi
done

# TODO wait duration should be configurable
for ((i = 1; i <= 120; i++)); do
    for SERVICE in "${SERVICES[@]}"; do
        STATUS=$(systemctl show --property=ActiveState --value "$SERVICE")
        case "$STATUS" in
            failed)
                echo "Attempt $i/120 ..."
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

    if ((i == 120)); then
        echo "Attempt $i/120 ..."
        echo "$OUT" >&2
        exit $RC
    fi

    echo "Attempt $i/120 ..."
    sleep 5
done
