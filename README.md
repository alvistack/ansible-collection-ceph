# Ansible Collection for Ceph

<a href="https://alvistack.com" title="AlviStack" target="_blank"><img src="/alvistack.svg" height="75" alt="AlviStack"></a>

[![Gitlab pipeline status](https://img.shields.io/gitlab/pipeline/alvistack/ansible-collection-ceph/master)](https://gitlab.com/alvistack/ansible-collection-ceph/-/pipelines)
[![GitHub tag](https://img.shields.io/github/tag/alvistack/ansible-collection-ceph.svg)](https://github.com/alvistack/ansible-collection-ceph/tags)
[![GitHub license](https://img.shields.io/github/license/alvistack/ansible-collection-ceph.svg)](https://github.com/alvistack/ansible-collection-ceph/blob/master/LICENSE)
[![Ansible Collection](https://img.shields.io/badge/galaxy-alvistack.ceph-blue.svg)](https://galaxy.ansible.com/alvistack/ceph)

Ansible collection for deploying Ceph.

This Ansible collection provides Ansible playbooks and roles for the
deployment and configuration of an [Ceph](https://github.com/ceph/ceph)
environment.

## Requirements

This collection require Ansible community package 4.10 or higher.

This collection was designed for:

- Ubuntu 20.04, 22.04, 24.04, 24.10, 25.04
- AlmaLinux 8, 9
- openSUSE Leap 15.6, Tumbleweed
- Debian 12, Testing
- Fedora 40, 41, 42, Rawhide
- CentOS 7, 8 Stream, 9 Stream
- RHEL 7, 8, 9

## Quick Start

### Bootstrap Ansible and Roles

Start by cloning the repository, checkout the corresponding branch, and
init with `git submodule`, then install Ansible (see
<https://software.opensuse.org/download/package?package=ansible&project=home%3Aalvistack>):

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
    printf "Components:\nEnabled: yes\nX-Repolib-Name: alvistack\nSigned-By: /etc/apt/keyrings/home-alvistack.asc\nSuites: /\nTypes: deb\nURIs: http://downloadcontent.opensuse.org/repositories/home:/alvistack/xUbuntu_24.04\n" | tee /etc/apt/sources.list.d/home-alvistack.sources > /dev/null
    curl -fsSL https://downloadcontent.opensuse.org/repositories/home:alvistack/xUbuntu_24.04/Release.key | tee /etc/apt/keyrings/home-alvistack.asc > /dev/null
    apt update
    apt install ansible

    # Confirm the version of Ansible
    ansible --version

### AIO

All-in-one (AIO) build is a great way to perform an Ceph build for:

- A development environment
- An overview of how all the Ceph services fit together
- A simple lab deployment

Simply execule our default Molecule test case and it will deploy all
default components into your localhost:

    # Run Molecule test case
    molecule test -s default

    # Confirm the version and status of Ceph
    ceph --version
    ceph --status
    ceph health detail

### Production

In order to avoid [Single Point of
Failure](https://en.wikipedia.org/wiki/Single_point_of_failure), at
least 3 instances for Ceph is recommended.

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

You should update the following files as per your production
environment:

- `/etc/ansible/hosts`
  - Update with your inventory hostnames and IPs
- `/etc/ansible/group_vars/all/*.yml`
  - Update `*_release` and `*_version` if you hope to pin the
    deployment into any legacy supported version

Once update now run the playbooks:

    # Run playbooks
    cd /opt/ansible-collection-ceph
    ansible-playbook playbooks/converge.yml

    # Confirm the version and status of Ceph
    ceph --version
    ceph --status
    ceph health detail

### Molecule

You could also run our
[Molecule](https://molecule.readthedocs.io/en/stable/) test cases if you
have [Vagrant](https://www.vagrantup.com/) and
[Libvirt](https://libvirt.org/) installed, e.g.

    # Run Molecule on Ubuntu 24.04
    molecule converge -s ubuntu-24.04

Please refer to [.gitlab-ci.yml](.gitlab-ci.yml) for more information on
running Molecule.

## Versioning

### `YYYYMMDD.Y.Z`

Release tags could be find from [GitHub
Release](https://github.com/alvistack/ansible-collection-ceph/tags) of
this repository. Thus using these tags will ensure you are running the
most up to date stable version of this image.

### `YYYYMMDD.0.0`

Version tags ended with `.0.0` are rolling release rebuild by [GitLab
pipeline](https://gitlab.com/alvistack/ansible-collection-ceph/-/pipelines)
in weekly basis. Thus using these tags will ensure you are running the
latest packages provided by the base image project.

## License

- Code released under [Apache License 2.0](LICENSE)
- Docs released under [CC BY
  4.0](http://creativecommons.org/licenses/by/4.0/)

## Author Information

- Wong Hoi Sing Edison
  - <https://twitter.com/hswong3i>
  - <https://github.com/hswong3i>
