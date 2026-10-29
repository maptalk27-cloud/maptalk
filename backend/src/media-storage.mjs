export const DEFAULT_USER_MEDIA_LIMIT_BYTES = 50 * 1024 * 1024;

// This remains a finite per-user safety budget, not an unlimited storage plan.
// Changing the configured value is an operator decision, never an API input.
export function userMediaLimitBytes(value = DEFAULT_USER_MEDIA_LIMIT_BYTES) {
  if (!Number.isSafeInteger(value) || value < 1024 * 1024 || value > 1024 * 1024 * 1024) {
    throw new Error('User media limit must be an integer between 1 MiB and 1 GiB.');
  }
  return value;
}

// Only reclaim a particular previously linked asset. Sweeping every unlinked
// upload would delete photos whose offline post has not reached the server yet.
export function reclaimUnreferencedMedia(db, ownerID, mediaIDs) {
  const remove = db.prepare(`DELETE FROM media WHERE id = ? AND owner_id = ?
    AND NOT EXISTS (SELECT 1 FROM memory_media WHERE media_id = media.id)
    AND NOT EXISTS (SELECT 1 FROM cluster_media WHERE media_id = media.id)
    AND NOT EXISTS (SELECT 1 FROM user_profiles WHERE avatar_media_id = media.id)`);
  for (const mediaID of new Set(mediaIDs)) remove.run(mediaID, ownerID);
}
