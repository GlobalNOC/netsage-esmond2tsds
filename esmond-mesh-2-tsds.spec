Summary: Esmond Mesh to TSDS Importer
Name: esmond-mesh-2-tsds
Version: 1.2.0
Release: 2%{?dist}
License: Apache
URL: https://sites.google.com/site/netsagensf/home#NetSage
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
BuildArch: noarch
Requires: perl-libwww-perl
Requires: perl-GRNOC-Config
Requires: perl-GRNOC-WebService-Client
Requires: perl-JSON-XS
Requires: perl-List-MoreUtils
Requires: perl-DateTime
Requires: libperfsonar-esmond-perl
Requires: libperfsonar-psconfig-perl

%description
A script that takes a URL to a pS mesh json file, parses out the hosts
from it, and then queries the relevant MAs for data to push to a TSDS instance.

This is not a fully fledged general utility and makes some assumptions specific to the
NetSage project, such as working only on disjoint meshes.

%prep
%setup -q

%build

%install
rm -rf $RPM_BUILD_ROOT

%{__install} -d -m0755 %{buildroot}/etc/netsage/esmond-mesh-2-tsds/
%{__install} -d -m0755 %{buildroot}/var/lib/netsage/esmond-mesh-2-tsds/
%{__install} -d -m0755 %{buildroot}/usr/bin/
%{__install} -d -p %{buildroot}/etc/cron.d/

%{__install} bin/esmond2tsds        %{buildroot}/usr/bin/esmond2tsds
%{__install} conf/config.xml.example      %{buildroot}/etc/netsage/esmond-mesh-2-tsds/config.xml
%{__install} conf/esmond-mesh-2-tsds.cron  %{buildroot}/etc/cron.d/


%clean
rm -rf $RPM_BUILD_ROOT


%files
%defattr(755,root,root,-)
/usr/bin/esmond2tsds

%defattr(644,root,root,-)
%config(noreplace) /etc/cron.d/esmond-mesh-2-tsds.cron

%defattr(640,netsage,netsage,-)
%config(noreplace) /etc/netsage/esmond-mesh-2-tsds/config.xml

%defattr(755,netsage,netsage,-)
%dir /var/lib/netsage/esmond-mesh-2-tsds/

%pre
/usr/bin/getent passwd netsage || /usr/sbin/useradd -r -s /sbin/nologin netsage

%changelog
* Tue Aug 9 2016 Dan Doyle <daldoyle@netsage-archive.grnoc.iu.edu> - esmond-mesh-2-tsds
- Initial build.
