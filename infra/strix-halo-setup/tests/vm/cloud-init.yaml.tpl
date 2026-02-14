#cloud-config
hostname: strix-test-vm
manage_etc_hosts: true

users:
  - name: testuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

package_update: true

packages:
  - curl
  - git
  - python3
  - python3-pip
  - build-essential
  - network-manager
  - vim
  - wget
  - ca-certificates
  - gnupg
  - lsb-release
