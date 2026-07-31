#!/bin/bash
set -ouex pipefail

GITHUB_REPO="sysxfml/bazzite-amd-hdmi-kde"
RELEASE_TAG="latest-kernel"

pushd /usr/lib/kernel/install.d
mv 05-rpmostree.install 05-rpmostree.install.bak
mv 50-dracut.install 50-dracut.install.bak
printf '%s\n' '#!/bin/sh' 'exit 0' > 05-rpmostree.install
printf '%s\n' '#!/bin/sh' 'exit 0' > 50-dracut.install
chmod +x  05-rpmostree.install 50-dracut.install
popd

pkgs=(
    kernel
    kernel-core
    kernel-modules
    kernel-modules-core
    kernel-modules-extra
    kernel-modules-akmods
    kernel-devel
    kernel-devel-matched
    kernel-tools
    kernel-tools-libs
    kernel-common
)

dnf5 -y remove --no-autoremove ${pkgs[@]} || true

rm -rf /usr/lib/modules/*

echo "Installing custom kernel RPMs from local /ctx mount..."
dnf5 --setopt=disable_excludes=* install -y /ctx/kernel-rpms/*.rpm

pushd /usr/lib/kernel/install.d
mv -f 05-rpmostree.install.bak 05-rpmostree.install
mv -f 50-dracut.install.bak 50-dracut.install
popd

if [ -f "/usr/libexec/rpm-ostree/wrapped/dracut" ]
then
  DRACUT="/usr/libexec/rpm-ostree/wrapped/dracut"
else
  DRACUT="/usr/bin/dracut"
fi

temp_conf_file="$(mktemp '/etc/dracut.conf.d/zzz-loglevels-XXXXXXXXXX.conf')"
cat >"${temp_conf_file}" <<'EOF'
stdloglvl=4
sysloglvl=0
kmsgloglvl=0
fileloglvl=0
EOF

for kernel_path in /usr/lib/modules/*/
do
  kernel_path="${kernel_path%/}"
  initramfs_image="${kernel_path}/initramfs.img"
  qual_kernel=${kernel_path##*/}
  
  "${DRACUT}" \
    --kver "${qual_kernel}" \
    --force \
    --add 'ostree' \
    --no-hostonly \
    --reproducible \
    "${initramfs_image}"
    
  chmod 0600 "${initramfs_image}"
done

rm -- "${temp_conf_file}"

install -D -m 0644 /ctx/40-amdgpu-frl.toml /usr/lib/bootc/kargs.d/40-amdgpu-frl.toml

ostree container commit
