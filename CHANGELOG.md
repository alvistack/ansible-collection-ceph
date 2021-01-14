# Ansible Collection for Ceph

## 4.7.0 - TBC

### Major Changes

  - Migrate base Vagrant box from `generic/*` to `alvistack/*`

## 4.6.0 - 2020-12-28

### Major Changes

  - Remove Ceph 14.2 Nautilus support
  - Simplify Molecule scenario for vagrant-libvirt
  - Migrate from Travis CI to GitLab CI
  - Support Fedora 33
  - Remove Fedora 32 support
  - Support Ubuntu 20.10
  - Bugfix graceful shutdown deadlock due to systemd dependencies

## 4.5.0 - 2020-10-07

  - Initial release for Ansible 2.10 or higher
  - This collection was designed for:
      - Ubuntu 18.04/20.04
      - RHEL/CentOS 7/8
      - openSUSE Leap 15.2
      - Debian 10
      - Fedora 32
