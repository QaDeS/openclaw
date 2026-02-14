#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: strix-test-vm
    password: "$6$rounds=4096$vmtest$hashedpasswordplaceholder"  # disabled, key-only auth
    username: testuser
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - ${SSH_PUBKEY}
  storage:
    layout:
      name: lvm
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
  late-commands:
    - echo 'testuser ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/testuser
