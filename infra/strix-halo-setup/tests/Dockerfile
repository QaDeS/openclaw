FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- Layer 1: System packages (cached unless base image changes) ---
# These are test-only tools (bats, shellcheck, etc.), NOT the provisioning
# targets. They will not leak to the host since this runs in a container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bats \
    python3 \
    python3-yaml \
    shellcheck \
    git \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# --- Layer 2: Test user + system dirs (rarely changes) ---
RUN useradd -m -s /bin/bash testuser \
    && mkdir -p /home/testuser/.ssh \
    && echo "ssh-ed25519 AAAA_FAKE_KEY testuser@test" > /home/testuser/.ssh/authorized_keys \
    && chmod 700 /home/testuser/.ssh \
    && chmod 600 /home/testuser/.ssh/authorized_keys \
    && mkdir -p /etc/systemd/system

# --- Layer 3: Source scripts (changes when provisioning scripts change) ---
# Copy provisioning sources first (changes less often than tests)
WORKDIR /workspace/infra/strix-halo-setup
COPY components/ components/
COPY systemd/     systemd/
COPY docker/      docker/
COPY defense/     defense/
COPY provision_strix_halo.sh .

# --- Layer 4: Test files (changes most often — last for fast rebuilds) ---
COPY tests/ tests/
RUN chmod +x tests/run-tests.sh

WORKDIR /workspace/infra/strix-halo-setup/tests
ENTRYPOINT ["./run-tests.sh"]
