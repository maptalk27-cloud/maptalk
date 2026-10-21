import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const checks = fileURLToPath(new URL('./host_secrets_checks.py', import.meta.url));
// The Python suite only imports functions under mocks and uses freshly generated
// test keys. It never invokes the real installer entry point or any AWS command.
for (const name of [
  'cli_is_read_only_scoped_and_instance_role_only',
  'secret_identity_and_current_version_are_validated',
  'external_failures_never_include_captured_values',
  'payload_preserves_keys_and_existing_public_configuration',
  'apple_key_requires_an_unencrypted_valid_p256_key',
  'apple_key_accepts_optional_final_lf_without_changing_original_bytes',
  'apple_key_rejects_extra_data_outside_single_pem_block',
  'encryption_keys_require_canonical_independent_32_byte_values',
  'install_creates_private_files_and_preserves_bootstrap_marker',
  'rerun_never_replaces_or_rotates_existing_files',
  'changed_or_partial_installations_fail_without_modification',
  'file_symlinks_hardlinks_and_broad_permissions_are_rejected',
  'unsafe_directory_or_symlink_parent_is_rejected',
  'mid_install_failure_rolls_back_only_new_files',
  'concurrent_file_creation_cannot_be_overwritten',
  'lock_prevents_concurrent_installation_and_rejects_symlinks',
  'main_suppresses_all_failure_details',
  'main_refuses_arguments_or_non_root_before_fetching_any_secret',
]) {
  test(`host secrets: ${name.replaceAll('_', ' ')}`, () => {
    const result = spawnSync('python3', ['-B', checks, `HostSecretsChecks.test_${name}`], {
      encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }, timeout: 15000,
    });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
  });
}
