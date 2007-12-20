# GOTCHA: Make sure to use the -h option on tar to dereference symlinks when
# creating the source archive. This prevents a broken symlink and allows us
# to not duplicate the LICENSE file twice in the svn repository

%define tm_srcpath	/bld/shared/source/vm-builder
%define tm_devtag	vm-builder_1_3
%define tm_modules	syseng/vm-builder
%define tm_skiptag	0

%define TM_Component	vm-builder
%define app_prefix	/usr

Name: %{TM_Component}
Summary: Scripts for provisioning new virtual machines.
Packager: Jeff Schroeder <jeffschroeder@computer.org>
Version: 1.3
Release: 1
Source: %{TM_Component}-%{version}-%{release}.tar.gz
License: GPL
Vendor: Ticketmaster, Inc
Group: Applications/System
BuildRoot: %{_tmppath}/%{name}
BuildArch: noarch

%description
Easily provision new VMWare GSX virtual machines in a scriptable fashion.

%prep
rm -rf %{buildroot}
%setup -q -n %{name}-%{version}-%{release}

#%build

%install
#!/bin/bash
# Since we use bash brace expansion, lets make sure we are using bash
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT
%{__mkdir_p} $RPM_BUILD_ROOT/etc/%{TM_Component}
%{__mkdir_p} $RPM_BUILD_ROOT%{app_prefix}/bin
%{__mkdir_p} $RPM_BUILD_ROOT%{app_prefix}/{lib,libexec}/%{TM_Component}
%{__mkdir_p} $RPM_BUILD_ROOT/home/%{TM_Component}/{images/ks,template/linux,template/win2k3}
%{__mkdir_p} $RPM_BUILD_ROOT%{app_prefix}/share/%{TM_Component}/doc

%{__chmod} 0755 $RPM_BUILD_ROOT%{app_prefix}/libexec
%{__chmod} 0755 -R $RPM_BUILD_ROOT/home/%{TM_Component}

%{__install} -p -m 0755 vm-builder $RPM_BUILD_ROOT%{app_prefix}/bin/vm-builder
%{__install} -p -m 0755 vm-functions $RPM_BUILD_ROOT%{app_prefix}/lib/%{TM_Component}/vm-functions
%{__install} -p -m 0755 {new_vmware_config,setup-vm-builder.sh} $RPM_BUILD_ROOT%{app_prefix}/libexec/%{TM_Component}
%{__install} -p -m 0644 doc/{TODO,LICENSE,README} $RPM_BUILD_ROOT%{app_prefix}/share/%{TM_Component}/doc
%{__install} -p -m 0644 conf/vmware-gsx.conf $RPM_BUILD_ROOT/etc/%{TM_Component}/vmware-gsx.conf
%{__install} -p -m 0755 conf/template-linux.vmx $RPM_BUILD_ROOT/home/%{TM_Component}/template/linux/template.vmx
%{__install} -p -m 0755 conf/template-win2k3.vmx $RPM_BUILD_ROOT/home/%{TM_Component}/template/win2k3/template.vmx

%clean
rm -rf %{buildroot}

%post
cat << EOF

Run "%{TM_Component} -s" as root to fetch the proper boot images for
CentOS 4.6, 5.1, and set them up as an example. You will need a working
kickstart ks.cfg on a webserver somewhere to put into the isolinux.cfg
and blank vmware disk images (*.vmdk).
EOF

%files
%defattr(-,root,root)
%dir /home/%{TM_Component}
%dir /home/%{TM_Component}/images
%dir /home/%{TM_Component}/images/ks
%dir /home/%{TM_Component}/template
%dir /home/%{TM_Component}/template/linux
%dir /home/%{TM_Component}/template/win2k3
%dir /etc/%{TM_Component}
%dir %{app_prefix}/libexec/%{TM_Component}
%dir %{app_prefix}/lib/%{TM_Component}
%dir %{app_prefix}/share/%{TM_Component}
%dir %{app_prefix}/share/%{TM_Component}/doc

/home/%{TM_Component}/template/linux/template.vmx
/home/%{TM_Component}/template/win2k3/template.vmx

%{app_prefix}/bin/vm-builder
%{app_prefix}/share/%{TM_Component}/doc/*
%{app_prefix}/lib/%{TM_Component}/vm-functions
%{app_prefix}/libexec/%{TM_Component}/*
%config(noreplace) /etc/%{TM_Component}/vmware-gsx.conf

%changelog
* Wed Dec 20 2007 Jeff Schroeder <jeffschroeder@computer.org> vm-builder 1.3-1
- vm-builder.spec: Use bash for bashisms and flesh out %files
- setup-vm-builder: More checks, use $EDITOR, and normalize iso naming
- vm-builder: Added -s option to download and setup boot images along with
  better cleanup when a directory is created but the script fails
- vm-functions: Moved to /usr/lib/vm-functions, added -s, and nuke_it()
- Back to tabs instead of spaces *le sigh*

* Wed Dec 19 2007 Jeff Schroeder <jeffschroeder@computer.org> vm-builder 1.2-1
- Remove all Ticketmaster-isms and incorporate changes suggested by Phil
- vm-builder: Removed pointless vmlist checks and added /etc/vmware checks
- setup-vm-builder: Include vmware-gsx.conf and be generally more intelligent
- setup-vm-builder: Add in CentOS 4.6 along with 5.1
- vmware-gsx.conf: Removed unused variables and add autodetection for paths
  using /etc/vmware/config
- Add vmx templates for Linux and Windows 2003 doh!
- find . -type f | xargs sed -i -e 's/\t/	/g' tabs to spaces consistently

* Tue Dec 18 2007 Jeff Schroeder <jeffschroeder@computer.org> vm-builder 1.1-1
- Fix all of the pathing and rename /usr/bin/new_server to /usr/bin/vm-builder
- Set up everything and rewrite the docs for the open source release.
- Move everything from /$CLASS/shared/* Ticketmaster-ism to FHS compliant paths
- Add setup-vm-builder.sh script to set everything up for CentOS 5.1 vms

* Mon Dec 17 2007 Jeff Schroeder <jeffschroeder@computer.org> vm-builder 1.0-1
- vm-builder: Make the error checking more robust and fail politely
  instead of spewing nasty errors and then continuing.
- Write a proper README file.
