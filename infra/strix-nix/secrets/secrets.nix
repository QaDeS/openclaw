# agenix secret declarations
# Each secret is an age-encrypted file decrypted at activation time.
#
# Usage:
#   1. Add your SSH public key(s) below
#   2. Create secrets: agenix -e secrets/<name>.age
#   3. Reference in modules: config.age.secrets.<name>.path
#
# See README.md for setup instructions.

let
  # Replace with your actual SSH public keys
  operator = "ssh-ed25519 AAAA... mk@strix";
  strix = "ssh-ed25519 AAAA... root@strix";
  allKeys = [ operator strix ];
in
{
  # Supabase/WordPress shared database password
  "supabase-db-password.age".publicKeys = allKeys;

  # Namecheap DDNS password
  "ddns-password.age".publicKeys = allKeys;

  # OpenClaw environment variables (API keys, tokens)
  "openclaw-env.age".publicKeys = allKeys;
}
