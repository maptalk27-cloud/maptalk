export function mediaJSON(row) {
  return { id: row.id, mimeType: row.mime_type, byteCount: row.byte_count, path: `/v1/media/${row.id}` };
}

/** Public account metadata only. Callers enforce the viewer/owner boundary. */
export function userJSON(db, user) {
  const avatar = db.prepare(`SELECT media.id, media.mime_type, media.byte_count FROM user_profiles
    JOIN media ON media.id = user_profiles.avatar_media_id AND media.owner_id = user_profiles.user_id
    WHERE user_profiles.user_id = ?`).get(user.id);
  return { id: user.id, handle: user.handle, ...(avatar ? { avatar: mediaJSON(avatar) } : {}) };
}
