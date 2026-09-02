Name: cookbook-grr
Version: %{__version}
Release: %{__release}%{?dist}
BuildArch: noarch
Summary: cookbook to install and configure grr in the redborder platform.

License: AGPL 3.0
URL: https://github.com/redBorder/cookbook-grr
Source0: %{name}-%{version}.tar.gz

%description
%{summary}

%prep
%setup -qn %{name}-%{version}

%build

%install
mkdir -p %{buildroot}/var/chef/cookbooks/grr
cp -f -r  resources/* %{buildroot}/var/chef/cookbooks/grr
chmod -R 0755 %{buildroot}/var/chef/cookbooks/grr
install -D -m 0644 README.md %{buildroot}/var/chef/cookbooks/grr/README.md

%pre
if [ -d /var/chef/cookbooks/grr ]; then
    rm -rf /var/chef/cookbooks/grr
fi

%post
case "$1" in
  1)
    # This is an initial install.
    :
  ;;
  2)
    # This is an upgrade.
    su - -s /bin/bash -c 'source /etc/profile && rvm gemset use default && env knife cookbook upload grr'
  ;;
esac

%postun
# Deletes directory when uninstalling the package
if [ "$1" = 0 ] && [ -d /var/chef/cookbooks/grr ]; then
  rm -rf /var/chef/cookbooks/grr
fi

%files
%defattr(0644,root,root)
%attr(0755,root,root)
/var/chef/cookbooks/grr
%defattr(0644,root,root)
/var/chef/cookbooks/grr/README.md

%doc

%changelog
* Thu Aug 28 2025 Vicente Mesa <vimesa@redborder.com>
- Create grr cookbook
