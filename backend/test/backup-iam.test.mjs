import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  BACKUP_RESOURCE, refineBackupPolicy,
} from '../deploy/aws/iam/refine-backup-policy.mjs';

const baseline = JSON.parse(readFileSync(new URL('../deploy/aws/iam/backup-autopilot-baseline.json', import.meta.url), 'utf8'));
const source = readFileSync(new URL('../src/s3-backup.mjs', import.meta.url));

test('backup policy retains only reviewed generated upload actions on the exact backup prefix', () => {
  const policy = refineBackupPolicy(baseline, source);
  assert.equal(policy.Version, '2012-10-17');
  assert.equal(policy.Statement.length, 1);
  assert.equal(policy.Statement[0].Effect, 'Allow');
  assert.deepEqual(policy.Statement[0].Action, ['s3:AbortMultipartUpload', 's3:PutObject']);
  assert.deepEqual(policy.Statement[0].Resource, [BACKUP_RESOURCE]);
  assert.equal(BACKUP_RESOURCE, 'arn:aws:s3:::maptalk-beta-579072312038-us-east-2/maptalk/backups/*');
  assert.equal(policy.Statement[0].Condition, undefined);
});

test('source drift fails closed before using deployment-specific IAM assumptions', () => {
  for (const changed of [
    Buffer.concat([source, Buffer.from('\n')]),
    Buffer.from(source.toString().replace("ServerSideEncryption: 'AES256'", "ServerSideEncryption: 'aws:kms'")),
  ]) assert.throws(() => refineBackupPolicy(baseline, changed), /source changed/);
});

test('unexpected or missing generated actions require explicit policy review', () => {
  const broader = structuredClone(baseline);
  broader.Statement[1].Action.push('s3:GetObject');
  assert.throws(() => refineBackupPolicy(broader, source), /action set changed/);
  const incomplete = structuredClone(baseline);
  incomplete.Statement[1].Action = incomplete.Statement[1].Action.filter(action => action !== 's3:PutObject');
  assert.throws(() => refineBackupPolicy(incomplete, source), /action set changed/);
});

test('refinement does not mutate the auditable Autopilot baseline', () => {
  const original = structuredClone(baseline);
  refineBackupPolicy(baseline, source);
  assert.deepEqual(baseline, original);
});

test('deployable artifact matches refinement and retained actions keep Autopilot evidence', () => {
  const deployed = JSON.parse(readFileSync(new URL('../deploy/aws/iam/backup-runtime-policy.json', import.meta.url), 'utf8'));
  const explanations = JSON.parse(readFileSync(new URL('../deploy/aws/iam/backup-autopilot-explanations.json', import.meta.url), 'utf8'));
  assert.deepEqual(deployed, refineBackupPolicy(baseline, source));
  for (const action of deployed.Statement.flatMap(statement => statement.Action)) {
    const evidence = explanations.ExplanationForAction[action];
    assert.ok(evidence?.length > 0, `${action} needs generated evidence`);
    for (const item of evidence) {
      assert.ok(item.Operations.some(operation => operation.Source?.Location?.includes('backend/src/s3-backup.mjs:')));
    }
  }
});

test('changes to generated identity-policy shape or retained conditions fail closed', () => {
  const changed = structuredClone(baseline);
  changed.Statement[1].Condition = { Bool: { 'aws:SecureTransport': 'true' } };
  assert.throws(() => refineBackupPolicy(changed, source), /conditions changed/);
  const resourcePolicy = structuredClone(baseline);
  resourcePolicy.Statement[1].Principal = '*';
  assert.throws(() => refineBackupPolicy(resourcePolicy, source), /shape changed/);
});
