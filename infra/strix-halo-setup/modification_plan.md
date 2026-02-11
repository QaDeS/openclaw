# Modification Plan: Fix All Pre-existing Test Failures

**Current state:** 333 passing / 18 failing across 3 categories.

---

## 1. Install shellcheck (10 failures)

Shellcheck is not installed on the machine, so all `test_shellcheck.bats` tests exit with code 127.

**Files failing:**
- `tests/test_shellcheck.bats` — all 10 tests (provision script + 9 component scripts)

**Action:**
- Install shellcheck to `~/.local/bin` (user-local, no sudo needed):
  ```
  curl -fsSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
    | tar xJ --strip-components=1 -C ~/.local/bin shellcheck-v0.10.0/shellcheck
  ```
- Ensure `~/.local/bin` is on `$PATH` (it is by default on Ubuntu).
- Then fix any shellcheck warnings in all scripts (see task 6).

---

## 2. Fix ace_step venv test (1 failure)

The user changed `components/50-ace-step.sh` to pin Python 3.11 via uv instead of using `python3 -m venv`.

**Old code:** `sudo -u comfyui "$UV" --no-config venv "${ACE_STEP_VENV}"`
**New code:** `sudo -u comfyui "$UV" --no-config venv --seed --python 3.11 "${ACE_STEP_VENV}"`

**Failing test:**
- `tests/test_component_ace_step.bats` line 60-65: `ace_step: creates an isolated venv (not uv sync)` — greps for `python3 -m venv`

**Action:** Update the test to check for `uv.*venv.*--python 3.11` instead of `python3 -m venv`. Keep the "must NOT call uv sync" check. Update the test name to reflect `uv venv --python 3.11`:

```bash
@test "ace_step: creates isolated Python 3.11 venv via uv (not uv sync)" {
    grep -q "uv.*venv.*--python 3.11" "$STRIX_DIR/components/50-ace-step.sh"
    # Must NOT call uv sync as a command (it pulls CUDA torch)
    ! grep -v '^\s*#' "$STRIX_DIR/components/50-ace-step.sh" | grep -q "uv sync"
}
```

---

## 3. Fix base xorg tests (2 failures)

The user overhauled `deploy_base_config()` in `components/10-base.sh`:
- **Removed:** hardcoded xorg config with `3840x2160` resolution and `GFX1151` device target
- **Added:** auto-detect approach — installs `xserver-xorg-video-amdgpu` and removes forced config files (`70-dummy.conf`, `70-amdgpu.conf`), letting Xorg pick up hardware automatically

**Failing tests:**
- `tests/test_component_base.bats` line 133-134: `base: xorg config creates 4K resolution` — greps for `3840x2160`
- `tests/test_component_base.bats` line 137-138: `base: xorg config targets GFX1151` — greps for `GFX1151`

**Action:** Replace both tests with ones that verify the new auto-detect strategy:

```bash
@test "base: xorg auto-detects GPU (no forced driver config)" {
    # New approach: remove forced configs, let Xorg auto-detect amdgpu
    grep -q "rm -f.*70-dummy.conf" "$STRIX_DIR/components/10-base.sh"
    grep -q "rm -f.*70-amdgpu.conf" "$STRIX_DIR/components/10-base.sh"
}

@test "base: installs amdgpu Xorg driver for hardware detection" {
    grep -q "xserver-xorg-video-amdgpu" "$STRIX_DIR/components/10-base.sh"
}
```

---

## 4. Fix security scanner tests (5 failures)

The code installs only `mcp-scan` (comment: "a2a-scanner/skill-scanner not yet on PyPI") but tests expect `a2a-scanner`, `mcp-scanner`, `skill-scanner`.

**Failing tests:**
- `tests/test_component_security.bats` lines 101-109:
  - `security: installs security scanners via uv tool` — passes (grep for `uv tool install`)
  - `security: installs a2a-scanner, mcp-scanner, skill-scanner` — fails (these don't exist in the code)
- `tests/test_defense_daemon.bats` lines 36-46:
  - `defense: SCANNERS includes a2a-scanner` — fails
  - `defense: SCANNERS includes mcp-scanner` — fails
  - `defense: SCANNERS includes skill-scanner` — fails

**Root cause:** The daemon's `SCANNERS` list only has `["mcp-scan", "scan"]` and `["audit-project-mutation"]`. The test names reference tools that were planned but don't exist yet.

**Action:**

### a) Update `tests/test_component_security.bats`:
Replace the failing test with one matching reality:
```bash
@test "security: installs mcp-scan via uv tool" {
    grep -q "uv.*tool install.*mcp-scan" "$STRIX_DIR/components/60-security.sh"
}
```

### b) Update `tests/test_defense_daemon.bats`:
Replace the three scanner-name tests with:
```bash
@test "defense: SCANNERS includes mcp-scan" {
    grep -q "mcp-scan" "$DAEMON"
}
```
Remove the `a2a-scanner` and `skill-scanner` tests (not on PyPI, not in the code).

### c) Update `defense/cisco-defense-daemon.py`:
No change needed — it already correctly references `mcp-scan`.

---

## 5. Add comfyui rsync sudoers test (new coverage)

The user added rsync-as-comfyui sudoers support to `components/30-comfyui.sh` for model uploads. This is untested.

**Action:** Add a script-content test in `tests/test_component_comfyui.bats`:

```bash
@test "comfyui: allows provisioning user to rsync as comfyui" {
    grep -q "sudoers.d/comfyui-upload" "$STRIX_DIR/components/30-comfyui.sh"
    grep -q "NOPASSWD.*rsync" "$STRIX_DIR/components/30-comfyui.sh"
}
```

---

## 6. Fix shellcheck warnings in all scripts

After shellcheck is installed, run it against every script and fix warnings. The test command is:
```
shellcheck -s bash -e SC2086,SC2034,SC2155 <file>
```
(SC2086 = word splitting, SC2034 = unused vars, SC2155 = declare+assign are already excluded.)

**Files to check:**
- `provision_strix_halo.sh`
- `components/05-ssh.sh`
- `components/07-ssh-hardening.sh`
- `components/10-base.sh`
- `components/20-llm-stack.sh`
- `components/30-comfyui.sh`
- `components/40-zimage.sh`
- `components/50-ace-step.sh`
- `components/60-security.sh`
- `components/62-ddns.sh`

**Action:** Run shellcheck on each, fix all warnings. Common fixes:
- Quote variables in `cp`, `mkdir`, etc.
- Use `$()` instead of backticks
- Add `|| true` where needed
- Fix unquoted array expansions

---

## 7. Run full test suite — target: 0 failures

After all fixes, run `bats tests/` and verify all tests pass.

**Expected outcome:** ~351 tests passing (333 currently passing + 18 fixed), 0 failing.
