# Secrets Management (agenix)

This directory uses [agenix](https://github.com/ryantm/agenix) for secret management.

## Setup

1. **Edit `secrets.nix`**: Replace the placeholder SSH public keys with your actual keys.
   Get your public key: `cat ~/.ssh/id_ed25519.pub`

2. **Create secrets**:
   ```bash
   cd nix/secrets

   # Supabase DB password
   agenix -e supabase-db-password.age

   # Namecheap DDNS password
   agenix -e ddns-password.age

   # OpenClaw env vars
   agenix -e openclaw-env.age
   ```

3. **Reference in host config** (`hosts/strix.nix`):
   ```nix
   age.secrets.supabase-db-password.file = ../secrets/supabase-db-password.age;

   services.strixHalo.hosting.dbPasswordFile = config.age.secrets.supabase-db-password.path;
   ```

## Re-keying

If you change the SSH keys in `secrets.nix`, re-encrypt all secrets:
```bash
agenix -r
```

## Files

- `secrets.nix` — Key declarations (which keys can decrypt which secrets)
- `*.age` — Encrypted secret files (safe to commit)
