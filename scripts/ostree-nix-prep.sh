#!/usr/bin/env bash
# Make the Determinate installer's `install ostree` work on composefs ostree
# systems (Bazzite, Fedora Atomic 42+). There, `/` is a read-only composefs
# overlay: `chattr -i /` is unsupported and `mkdir /nix` fails, so the
# installer's nix-directory.service can never create the /nix mount point.
#
# 1. root.transient = true: `/` gets a throwaway writable layer each boot, so
#    nix-directory.service can mkdir /nix (the store itself lives in
#    /var/home/nix and is bind-mounted, so nothing is lost on reboot).
# 2. A drop-in makes the service's chattr calls non-fatal.
#
# Idempotent. Needs a reboot when it changes the initramfs. Undo:
#   sudo rpm-ostree initramfs-etc --untrack=/etc/ostree/prepare-root.conf
#   sudo rm /etc/ostree/prepare-root.conf /etc/systemd/system/nix-directory.service.d/10-composefs.conf
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

conf=/etc/ostree/prepare-root.conf
base=/usr/lib/ostree/prepare-root.conf
need_reboot=0

if ! grep -qsE '^[[:space:]]*transient[[:space:]]*=[[:space:]]*(true|yes|1)' "$conf"; then
  if grep -qs '^\[root\]' "$base"; then
    echo "$base already has a [root] section; merge 'transient = true' into $conf by hand" >&2
    exit 1
  fi
  [[ -e $conf ]] && cp -a "$conf" "$conf.bak.$(date +%Y%m%dT%H%M%S)"
  # An /etc copy replaces the /usr one wholesale, so start from it.
  { cat "$base"; printf '[root]\ntransient = true\n'; } > "$conf"
  rpm-ostree initramfs-etc --track="$conf"
  need_reboot=1
fi

dropin=/etc/systemd/system/nix-directory.service.d/10-composefs.conf
mkdir -p "${dropin%/*}"
cat > "$dropin" <<'EOF'
# composefs root: chattr is unsupported; root.transient is what makes mkdir /nix work.
[Service]
ExecStartPre=
ExecStartPre=-chattr -i /
ExecStopPost=
ExecStopPost=-chattr +i /
EOF
systemctl daemon-reload

if (( need_reboot )); then
  echo "Done. Reboot, then re-run: curl -fsSL https://install.determinate.systems/nix | sh -s -- install ostree --no-confirm"
else
  echo "Already prepared. Run: curl -fsSL https://install.determinate.systems/nix | sh -s -- install ostree --no-confirm"
fi
