%undefine __brp_mangle_shebangs

Name: redborder-ips
Version: %{__version}
Release: %{__release}%{?dist}
BuildArch: noarch
Summary: Main package for redborder ips

License: AGPL 3.0
URL: https://github.com/redBorder/redborder-ips
Source0: %{name}-%{version}.tar.gz

Requires: bash dialog dmidecode rsync nc telnet redborder-common redborder-chef-client redborder-rubyrvm redborder-cli rb-register bridge-utils bpctl pfring-dkms pfring net-tools bind-utils ipmitool watchdog bp_watchdog snort barnyard2 dhclient
Requires: chef-workstation
Requires: network-scripts network-scripts-teamd
Requires: redborder-cgroups
Requires: daq = 2.0.7 daq-modules = 2.0.7

%description
%{summary}

%prep
%setup -qn %{name}-%{version}

%build

%install
mkdir -p %{buildroot}/etc/redborder
mkdir -p %{buildroot}/usr/lib/redborder/bin
mkdir -p %{buildroot}/usr/lib/redborder/scripts
mkdir -p %{buildroot}/usr/lib/redborder/lib
mkdir -p %{buildroot}/etc/profile.d
mkdir -p %{buildroot}/var/chef/cookbooks
mkdir -p %{buildroot}/etc/chef/
install -D -m 0644 resources/redborder-ips.sh %{buildroot}/etc/profile.d
install -D -m 0644 resources/dialogrc %{buildroot}/etc/redborder
cp resources/bin/* %{buildroot}/usr/lib/redborder/bin
cp resources/scripts/* %{buildroot}/usr/lib/redborder/scripts
cp -r resources/etc/chef %{buildroot}/etc/
cp resources/etc/rb_sysconf.conf.default %{buildroot}/etc/
chmod 0755 %{buildroot}/usr/lib/redborder/bin/*
chmod 0755 %{buildroot}/usr/lib/redborder/scripts/*
install -D -m 0644 resources/lib/rb_wiz_lib.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/wiz_conf.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/wizard_helper.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/rb_config_utils.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/rb_functions.sh %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/systemd/rb-init-conf.service %{buildroot}/usr/lib/systemd/system/rb-init-conf.service
install -D -m 0755 resources/lib/dhclient-enter-hooks %{buildroot}/usr/lib/redborder/lib/dhclient-enter-hooks

%pre

%post
if ls /opt/chef-workstation/embedded/lib/ruby/gems/3.1.0/specifications/default/openssl-3.0.1.* 1> /dev/null 2>&1; then
  rm -f /opt/chef-workstation/embedded/lib/ruby/gems/3.1.0/specifications/default/openssl-3.0.1.*
fi
MARKER_FILE="/var/lib/redborder/upgrade_etc_hosts_patch_done"
case "$1" in
  1)
    # This is an initial install.
    :
  ;;
  2)
    # This is an upgrade.
    if [ -f "$MARKER_FILE" ]; then
      echo "Post-install patch already applied, skipping."
      exit 0
    fi

    CDOMAIN_FILE="/etc/redborder/cdomain"
    if [ -f "$CDOMAIN_FILE" ]; then
      SUFFIX=$(cat "$CDOMAIN_FILE")
    else
      SUFFIX="redborder.cluster"
    fi

    NEW_DOMAIN_HTTP2K="http2k.${SUFFIX}"
    NEW_DOMAIN_ERCHEF="erchef.service.${SUFFIX}"
    NEW_DOMAIN_S3="s3.service.${SUFFIX}"

    # Safely replace only if not already changed
    grep -qE '\bhttp2k\.service[[:space:]]' /etc/hosts && \
    sed -i -E "s/\bhttp2k\.service\b/${NEW_DOMAIN_HTTP2K}/" /etc/hosts

    grep -qE '\berchef\.service[[:space:]]' /etc/hosts && \
    sed -i -E "s/\berchef\.service\b/${NEW_DOMAIN_ERCHEF}/" /etc/hosts

    grep -qE '\bs3\.service[[:space:]]' /etc/hosts && \
    sed -i -E "s/\bs3\.service\b/${NEW_DOMAIN_S3}/" /etc/hosts

    CHEF_FILES=(
      "/etc/chef/client.rb.default"
      "/etc/chef/client.rb"
      "/etc/chef/knife.rb.default"
      "/etc/chef/knife.rb"
      "/root/.chef/knife.rb"
    )

    for f in "${CHEF_FILES[@]}"; do
      if [ -f "$f" ]; then
        if grep -q 'https://erchef\.service/' "$f"; then
          sed -i "s|https://erchef\.service/|https://${NEW_DOMAIN_ERCHEF}/|" "$f"
          echo "Updated: $f"
        fi
      fi
    done

    mkdir -p "/var/lib/redborder"
    touch "$MARKER_FILE"
  ;;
esac

[ -f /usr/lib/redborder/bin/rb_rubywrapper.sh ] && /usr/lib/redborder/bin/rb_rubywrapper.sh -c
systemctl daemon-reload
systemctl enable pf_ring && systemctl start pf_ring
# adjust kernel printk settings for the console
echo "kernel.printk = 1 4 1 7" > /usr/lib/sysctl.d/99-redborder-printk.conf
/sbin/sysctl --system > /dev/null 2>&1

%files
%defattr(0755,root,root)
/usr/lib/redborder/bin
/usr/lib/redborder/scripts
%defattr(0755,root,root)
/etc/profile.d/redborder-ips.sh
/usr/lib/redborder/lib/dhclient-enter-hooks
%defattr(0644,root,root)
/etc/chef/
/etc/rb_sysconf.conf.default
/etc/redborder
/usr/lib/redborder/lib/rb_wiz_lib.rb
/usr/lib/redborder/lib/wiz_conf.rb
/usr/lib/redborder/lib/wizard_helper.rb
/usr/lib/redborder/lib/rb_config_utils.rb
/usr/lib/redborder/lib/rb_functions.sh
/usr/lib/systemd/system/rb-init-conf.service
%doc

%changelog
* Tue Apr 22 2025 Rafael Gómez <rgomez@redborder.com> - 3.1.1-1
- Remove openssl gemspec file handling from chef-workstation package

* Fri Mar 28 2025 Vicente Mesa, José Navarro <vimesa@redborder.com, jnavarro@redborder.com> - 3.1.0-1
- Chef update handling conflict with openssl

* Mon Apr 14 2025 Rafael Gómez <rgomez@redborder.com> - 3.0.0-1
- Add domain configuration update during package upgrade for http2k

* Thu Dec 14 2023 Miguel Negrón <manegron@redborder.com> - 1.4.0-1
- Set version for daq to 2.0.7

* Thu Dec 14 2023 Miguel Álvarez <malvarez@redborder.com> - 1.3.5-1
- Add cgroups

* Tue Nov 21 2023 Vicente Mesa <vimesa@redborder.com> - 1.3.4-1
- Add dhclient

* Tue Nov 14 2023 Miguel Negrón <manegron@redborder.com> - 1.3.3-1
- add network scripts

* Mon Oct 02 2023 Miguel Negrón <manegron@redborder.com> - 1.3.2-1
- Add new script and open kafka port

* Mon Mar 21 2021 Miguel Negron <manegron@redborder.com> - 0.0.1-1
- first spec version
