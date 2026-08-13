#!/bin/bash
set -ouex pipefail

GITHUB_REPO="sysxfml/bazzite-amd-hdmi-kde"
RELEASE_TAG="latest-kernel"

# 1. 安全屏蔽系统钩子（修复了之前的 shebang 问题）
pushd /usr/lib/kernel/install.d
mv 05-rpmostree.install 05-rpmostree.install.bak
mv 50-dracut.install 50-dracut.install.bak
cat <<'EOF' > 05-rpmostree.install
#!/bin/sh
exit 0
EOF
cat <<'EOF' > 50-dracut.install
#!/bin/sh
exit 0
EOF
chmod +x 05-rpmostree.install 50-dracut.install
popd

# 2. 核心战术变更：直接注入定制的 OGC+FRL 内核
# 不再执行 remove 卸载！直接利用 dnf5 的安装与替换机制。
# 这将完美保留系统原有的 kernel-modules-akmods 闭源驱动代码。
echo "Installing custom FRL kernel RPMs from local /ctx mount..."
dnf5 --setopt=disable_excludes=* install -y /ctx/kernel-rpms/*.rpm

# 3. 智能清理旧内核模块残留 (仅清理已被替换掉的无用目录)
for kver in $(ls /usr/lib/modules/)
do
  # 排除当前运行的内核版本以及仍然存在对应 kernel-core 包的版本
  if [[ "$kver" != "$(uname -r)" ]] && rpm -q kernel-core-${kver} &>/dev/null
  then
    continue
  fi
  
  # 如果目录存在但对应的 kernel-core 包已被替换，则清理它
  if [ -d "/usr/lib/modules/${kver}" ] && ! rpm -q kernel-core-${kver} &>/dev/null
  then
    echo "Removing stale modules for ${kver}"
    rm -rf "/usr/lib/modules/${kver}"
  fi
done

# 4. 恢复系统钩子
pushd /usr/lib/kernel/install.d
mv -f 05-rpmostree.install.bak 05-rpmostree.install
mv -f 50-dracut.install.bak 50-dracut.install
popd

# 5. 生成新内核的 initramfs 引导文件
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
  qual_kernel=${kernel_path##*/}
  initramfs_image="${kernel_path}/initramfs.img"

  # 仅为有效且存在 kernel-core 的定制内核生成引导文件
  if ! rpm -q "kernel-core-${qual_kernel}" &>/dev/null
  then
    continue
  fi
  
  "${DRACUT}" \
    --kver "${qual_kernel}" \
    --force \
    --add 'ostree' \
    --add 'fido2' \
    --zstd \
    -v \
    --no-hostonly \
    --reproducible \
    "${initramfs_image}"
    
  chmod 0600 "${initramfs_image}"
done

rm -- "${temp_conf_file}"

# 6. 注入 HDMI 2.1 大屏参数
install -D -m 0644 /ctx/40-amdgpu-frl.toml /usr/lib/bootc/kargs.d/40-amdgpu-frl.toml

# 7. 标记内核更新完成
echo "Custom OGC+FRL kernel successfully installed."
echo "Original akmods are preserved and will rebuild external modules on first boot."

ostree container commit
