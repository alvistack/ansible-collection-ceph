# Ansible Collection for Ceph

<img src="/alvistack.svg" width="75" alt="AlviStack">

[![Gitlab pipeline status](https://img.shields.io/gitlab/pipeline/alvistack/ansible-collection-ceph/master)](https://gitlab.com/alvistack/ansible-collection-ceph/-/pipelines)
[![GitHub release](https://img.shields.io/github/release/alvistack/ansible-collection-ceph.svg)](https://github.com/alvistack/ansible-collection-ceph/releases)
[![GitHub license](https://img.shields.io/github/license/alvistack/ansible-collection-ceph.svg)](https://github.com/alvistack/ansible-collection-ceph/blob/master/LICENSE)
[![Ansible Collection](https://img.shields.io/badge/galaxy-alvistack.ceph-blue.svg)](https://galaxy.ansible.com/alvistack/ceph)

Ansible collection for deploying Ceph.

This Ansible collection provides Ansible playbooks and roles for the deployment and configuration of an [Ceph](https://github.com/ceph/ceph) environment.

## Requirements

This collection require Ansible community package 4.9 or higher.

This collection was designed for:

  - Ubuntu 18.04, 20.04, 21.04, 21.10
  - CentOS 7, 8 Stream
  - openSUSE Leap 15.2, Leap 15.3, Tumbleweed
  - Debian 10, 11
  - Fedora 34, 35
  - RHEL 7, 8

## Quick Start

### Bootstrap Ansible and Roles

Start by cloning the repository, checkout the corresponding branch, and init with `git submodule`, then install Ansible:

    # GIT checkout development branch
    mkdir -p /opt/ansible-collection-ceph
    cd /opt/ansible-collection-ceph
    git init
    git remote add upstream https://github.com/alvistack/ansible-collection-ceph.git
    git fetch --all --prune
    git checkout upstream/develop -- .
    git submodule sync --recursive
    git submodule update --init --recursive
    
    # Bootstrap Ansible
    # See https://software.opensuse.org/download/package?package=ansible&project=home%3Aalvistack
    echo 'deb http://download.opensuse.org/repositories/home:/alvistack/xUbuntu_20.04/ /' | tee /etc/apt/sources.list.d/home:alvistack.list
    curl -fsSL https://download.opensuse.org/repositories/home:alvistack/xUbuntu_20.04/Release.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/home_alvistack.gpg > /dev/null
    apt update
    apt install ansible
    
    # Confirm the version of Ansible
    ansible --version

### AIO

All-in-one (AIO) build is a great way to perform an Ceph build for:

  - A development environment
  - An overview of how all the Ceph services fit together
  - A simple lab deployment

Simply execule our default Molecule test case and it will deploy all default components into your localhost:

    # Run Molecule test case
    molecule test -s default
    
    # Confirm the version and status of Ceph
    ceph --version
    ceph --status
    ceph health detail

### Production

In order to avoid [Single Point of Failure](https://en.wikipedia.org/wiki/Single_point_of_failure), at least 3 instances for Ceph is recommended.

This deployment will setup the follow components:

  - [Ceph](https://ceph.io/)
      - Ceph Monitor Daemon
      - Ceph Manager Daemon
      - Ceph Object Storage Daemon
      - Ceph Metadata Server
      - Ceph Object Gateway

Start by copying the default inventory for customization:

    # Copy default inventory
    mkdir -p /etc/ansible
    rsync -av /opt/ansible-collection-ceph/inventory/default/ /etc/ansible

You should update the following files as per your production environment:

  - `/etc/ansible/hosts`
      - Update with your inventory hostnames and IPs
  - `/etc/ansible/group_vars/all/*.yml`
      - Update `*_release` and `*_version` if you hope to pin the deployment into any legacy supported version

Once update now run the playbooks:

    # Run playbooks
    cd /opt/ansible-collection-ceph
    ansible-playbook playbooks/converge.yml
    
    # Confirm the version and status of Ceph
    ceph --version
    ceph --status
    ceph health detail

### Molecule

You could also run our [Molecule](https://molecule.readthedocs.io/en/stable/) test cases if you have [Vagrant](https://www.vagrantup.com/) and [Libvirt](https://libvirt.org/) installed, e.g.

    # Run Molecule on Ubuntu 20.04
    molecule converge -s ubuntu-20.04

Please refer to [.gitlab-ci.yml](.gitlab-ci.yml) for more information on running Molecule.

## License

  - Code released under [Apache License 2.0](LICENSE)
  - Docs released under [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/)

## Author Information

  - Wong Hoi Sing Edison
      - <https://twitter.com/hswong3i>
      - <https://github.com/hswong3i>
