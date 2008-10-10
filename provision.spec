%define app_prefix	/usr

# test

Name: provision
Summary: A tool for provisioning new systems
Packager: Phil Dibowitz <phil.dibowitz@ticketmaster.com>
Version: 3.6.1
Release: 1
Source: %{name}-%{version}.tar.gz
License: GPL
Group: Applications/System
BuildRoot: %{_tmppath}/%{name}
BuildArch: noarch
Requires: perl

%description
This is a tool for provisioning new systems withing websys, and soon, within all of Systems Engineering

%prep
rm -rf %{buildroot}
%setup -q -n %{name}-%{version}

#%build

%install
%define doc_prefix      /%{app_prefix}/share/doc/%{name}-%{version}

[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT
%{__mkdir_p} $RPM_BUILD_ROOT/etc
%{__mkdir_p} $RPM_BUILD_ROOT%{app_prefix}/{lib,bin,libexec}
%{__mkdir_p} $RPM_BUILD_ROOT%{app_prefix}/lib/provision/{plugins,local_decision}
%{__mkdir_p} $RPM_BUILD_ROOT%{doc_prefix}
%{__chmod} 0755 $RPM_BUILD_ROOT%{app_prefix}/libexec

%{__install} -p -m 0755 provision $RPM_BUILD_ROOT%{app_prefix}/bin/provision
%{__install} -p -m 0755 provision_helper $RPM_BUILD_ROOT%{app_prefix}/libexec/provision_helper
%{__install} -p -m 0755 lib/provision/*.pm $RPM_BUILD_ROOT%{app_prefix}/lib/provision/
%{__install} -p -m 0755 lib/provision/plugins/*.pm $RPM_BUILD_ROOT%{app_prefix}/lib/provision/plugins
%{__install} -p -m 0755 lib/provision/local_decision/generic.pm $RPM_BUILD_ROOT%{app_prefix}/lib/provision/local_decision
%{__install} -p -m 0755 conf/provision.conf.dist $RPM_BUILD_ROOT/etc/provision.conf
%{__install} -p -m 0755 lib/provision/local_decision/template.pm $RPM_BUILD_ROOT%{doc_prefix}
%{__install} -p -m 0755 LICENSE $RPM_BUILD_ROOT%{doc_prefix}
%{__install} -p -m 0755 docs/* $RPM_BUILD_ROOT%{doc_prefix}

%clean
rm -rf %{buildroot}

%post

%preun

%files
%defattr(-,root,root)
%{app_prefix}/bin/provision
%dir %{app_prefix}/lib/provision
%{app_prefix}/lib/provision/*
%{app_prefix}/libexec/provision_helper
%config(noreplace) /etc/provision.conf
%{doc_prefix}/*

%changelog
* Tue Jan 15 2008 Phil Dibowitz <phil@ticketmaster.com> provision-3.6.1-1
- Fix vm.pm for vm-builder (jeffschroeder@computer.org)
- Update spec file to not install unnecessary files in /usr/lib and to include docs
- Update spec to remove TM-specific stuff
- Version bump to differentiate from the version 3.6.0 this code is all based on

* Mon Aug 01 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.6.0-1
- Core: Replace network_overlays with overlay_map
- Core: Add support for configurable hostname parsing
- Core: Add option to list all known plugins (bz#35581)
- VM: Add support for configuring path to VMs
- VM: Add support for configuring path to vmlist
- VM: Add support for new_server (bz#38642)
- Filer: Add support for configuring qtree name
- Filer: Add support for configuring filer admin host
- Filer: Add support for configuring username to access filer with
- Filer: Add support for configuring mount path of filer volumes
- DNS: Add support for configuring DNS master
- Move provision::util to library-style module
- Significant improvements in callbacks and configurability
- Various fixes and code abstractions

* Mon Jul 02 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.8-1
- Don't tell the user there were no filer changes if there were some.

* Tue Jun 28 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.7-1
- Add new 'network_overlays' top-level config tree to replace 'devqa_re' config
  which is more generic both for websys and coresys
- Start enforcing only "known" top-level config trees
- Define a top-level tree for local_decision plugins
- Fix websys filer logic for several clusters

* Tue May 08 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.6-1
- provision::plugins::dns - fix deprovision by porting it to new get_rev_zonefile_list() API
- remove erroneous -r option from help

* Fri May 04 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.5-1
- Lots of code cleanups
- Provide verbose option to output diffs in non-dryrun mode (bz#35549)
- Allow both --dryrun and --dry-run as valid options
- provision::plugins::dns - Ping an IP before allocating it even if we don't think it's used (bz#32868)
- provision::plugins::vm - Fix bug where provision gets confused reading vm-list (bz#35548)
- provision::plugins::filer - Don't touch quotas on a volume that has them turned off, regardless of what it *should* be. But warn. (bz#35000)

* Thu Apr 12 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.4-1
- provision::plugins::filer support multiple IP ranges for a cluster

* Wed Apr 11 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.3-1
- Support multiple IP ranges for a cluster
- Clean up module loading code a bit

* Sat Jan 09 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.2-1
- Fix false warning case in provision
- Fix deprovisioning bug in filer.pm

* Sat Jan 09 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5.1-1
- Fix util.pm typo

* Sat Jan 09 2007 Phil Dibowitz <phil@ticketmaster.com> provision-3.5-1
- Retool internal data model
- Retool provision <--> provision_helper protocol
- Add alias support
- Significantly improve removal support

* Sat Dec 05 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.2-1
- Fix three s/$out/$line/g bugs in the code

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.1-1
- Finalize deprovisioning support
- Some initial cname backend support

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.1-rc1
- Deprovisioning Support

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.0-1
- Fixes from code review:
- Heavy optimizations in the way provision handles it's plugin objects
- Significant bugfixes in file_grep and all its callers
- A few more conversions to constants
- Fix some incorrect websys filer logic
- More robust zonefile parsing 
- Better error checking

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.0-rc4
- Change some logic in the VM plugin, and fix a bug

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.0-rc3
- Fix ssh retval bug

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.0-rc2
- Update the ssh-fork logic to work on the old AS3 perl
- Fix a forgot-to-check-exists bug
- Change --plugins to --libexec, which I meant to do before
- Update help messages

* Sat Aug 26 2006 Phil Dibowitz <phil@ticketmaster.com> provision-3.0-rc1
- Complete core re-write
- Full plugin support
- Dry-run support
- VM support
- Better error handling
- Various bugfixes

* Wed Aug 1 2006 Phil Dibowitz <phil@ticketmaster.com> software-provision-2.3-1
- Add --filer option to override internal filer/volume logic
- Update logic for stg1 and stg2 fls/vol decision (bugz #26568)
- Only open files ro if that's all we need
- Fix debug output bug
- Fix rcs log bug

* Wed Jun 5 2006 Phil Dibowitz <phil@ticketmaster.com> software-provision-2.2-1
- Fix inconsistent dev/qa regex (bugz #25616)
- Fix -m not being effective on the dns plugin (bugz #25758)
- One bit of code cleanup
- Fix file-not-found-not-reported error (bugz #25650)
- Make one lockfile a bit more descriptive
- Document the -s flag

* Wed May 3 2006 Phil Dibowitz <phil@ticketmaster.com> software-provision-2.1-1
- the extended checkout logic didn't work so well as root. using File::stat now
- The filer doesn't create qtrees until you "look" at the volume. ::sigh::

* Wed May 3 2006 Phil Dibowitz <phil@ticketmaster.com> software-provision-2.0-1
- Support for cluster-level forward zones (lax0.websys.tmcs, etc.)
- Random updates for Coresys
- Actual change implimentation (run "make", etc.)
- Add "-m" (nocommit) option to NOT do the above.
- Add --skip tag so we can skip certain plugins (--skip dns, or --skip filer)
- Add locking
- Various bugfixes
- Add --plugins to specify path to remote plugins
- Better debug output

* Wed Apr 12 2006 Phil Dibowitz <phil@ticketmaster.com> software-provision-1.0-1
- Initial version

