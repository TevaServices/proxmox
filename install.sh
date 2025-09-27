#!/usr/bin/env bash
# Modified version of this script: https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pmg-install.sh

for file in /etc/apt/sources.list.d/*.sources; do
  if grep -q "Components:.*pve-enterprise" "$file"; then
    sed -i '/^\s*Types:/,/^$/s/^\([^#].*\)$/# \1/' "$file"
  fi
done

for file in /etc/apt/sources.list.d/*.sources; do
  if grep -q "enterprise.proxmox.com.*ceph" "$file"; then
    sed -i '/^\s*Types:/,/^$/s/^\([^#].*\)$/# \1/' "$file"
  fi
done

cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

mkdir -p /usr/local/bin
cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const closeButton = dialog.querySelector('.fa-close');" \
      "      const exclamationIcon = dialog.querySelector('.fa-exclamation-triangle');" \
      "      const continueButton = dialog.querySelector('button');" \
      "      if (closeButton && exclamationIcon && continueButton) { dialog.remove(); console.log('Removed subscription dialog'); }" \
      "    });" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const hasInteractiveElements = card.querySelector('button, input, a');" \
      "      const hasComplexStructure = card.querySelector('.pwt-grid, .pwt-flex, .pwt-button');" \
      "      if (!hasInteractiveElements && !hasComplexStructure) { card.remove(); console.log('Removed subscription card'); }" \
      "    });" \
      "  }" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF

chmod 755 /usr/local/bin/pve-remove-nag.sh
    
cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
chmod 644 /etc/apt/apt.conf.d/no-nag-script

systemctl enable -q --now pve-ha-lrm
systemctl enable -q --now pve-ha-crm
systemctl enable -q --now corosync

# Custom section

# sysctl fs.inotify.max_user_watches=524288
# sysctl fs.inotify.max_user_instances=512

IFACE="$(ip -o route show default 2>/dev/null | awk "{print \$5; exit}")"
if [ -z "${IFACE:-}" ]; then
  IFACE="$(ls -1 /sys/class/net | grep -vE "^(lo|vmbr|tap|veth)$" | head -n1)"
fi

MAC="$(cat "/sys/class/net/${IFACE}/address" | tr "[:upper:]" "[:lower:]")"

HOST="$(echo "$MAC" | awk -F: "{printf \"%s%s%s\", \$4,\$5,\$6}")"

DOMAIN="pve.local"

FQDN="pve-${HOST}.${DOMAIN}"

hostnamectl set-hostname "${FQDN}"

IPV4="$(ip -4 -o addr show dev "${IFACE}" | awk "{print \$4}" | cut -d/ -f1 || true)"

if [ -n "${IPV4:-}" ]; then
  sed -i "/^${IPV4//./\\.}\\s/d" /etc/hosts || true
  sed -i "/^127\\.0\\.1\\.1\\s/d" /etc/hosts || true
  printf "%s %s %s\n" "${IPV4}" "${FQDN}" "${HOST}" >> /etc/hosts
else
  sed -i "/^127\\.0\\.1\\.1\\s/d" /etc/hosts || true
  printf "127.0.1.1 %s %s\n" "${FQDN}" "${HOST}" >> /etc/hosts
fi

# VG="pve"
# LV="lvol0"
# MNT="/mnt/data"

# lvcreate -l +100%FREE -n "$LV" "$VG"
# mkdir -p "$MNT"
# mkfs.xfs -f "/dev/$VG/$LV"
# UUID=$(blkid -s UUID -o value "/dev/$VG/$LV")
# echo "UUID=$UUID  $MNT  xfs  defaults  0  0" >> /etc/fstab
# mount -a

apt update &>/dev/null || true
apt -y dist-upgrade &>/dev/null || true

rm -v /var/lib/proxmox-first-boot/pending-first-boot-setup
reboot
