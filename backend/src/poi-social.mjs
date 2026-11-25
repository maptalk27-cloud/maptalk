import { digest } from './security.mjs';
import { userJSON } from './user-profile.mjs';
import { poiVisitDay, POI_VISIT_DAY_POLICY } from './poi-visit-day.mjs';

// These routes reuse the main server's authorization boundary, never a client
// cache or the recent feed. Queries are bounded and all writes are synchronous
// after authorizedJSON rechecks the current account following its await.
export function createPOISocialRoutes({ db, now, APIError, id, object, requireValue,
  notFound, authorizedJSON, memoryFor, visibleOwner, visibilitySQL, pageInput, json }) {
  db.function('poi_visit_day', { deterministic: true }, poiVisitDay);
  const permitted = alias => `(${alias}.owner_id = ? OR (${alias}.visibility = 'public'
    AND ${alias}.moderation_status = 'approved' AND ${visibilitySQL(`${alias}.owner_id`)}))`;
  const viewerArgs = viewerID => [viewerID, viewerID, viewerID];

  function attachment(memoryID, mediaID, viewerID) {
    const memory = memoryFor(memoryID, viewerID);
    if (!db.prepare('SELECT 1 FROM memory_media WHERE memory_id = ? AND media_id = ?').get(memoryID, mediaID)) throw notFound();
    return memory;
  }

  function availablePlace(placeID, viewerID) {
    return Boolean(db.prepare(`SELECT 1 FROM memories m WHERE m.kind = 'poi' AND m.place_id = ?
      AND ${permitted('m')} LIMIT 1`).get(placeID, ...viewerArgs(viewerID)));
  }

  function serializePlace(row) {
    return { id: row.id, name: row.name, category: row.category, sourceId: row.source_id ?? null,
      ...(row.directory_kind ? { directoryKind: row.directory_kind } : {}),
      coordinate: { latitude: row.latitude, longitude: row.longitude } };
  }

  function peerFor(peerID, viewerID) {
    if (peerID === viewerID || !visibleOwner(viewerID, peerID)) throw notFound();
    const peer = db.prepare('SELECT id, handle FROM users WHERE id = ?').get(peerID);
    if (!peer) throw notFound();
    return peer;
  }

  function serializeMessage(row, viewerID) {
    let context = null;
    if (row.context_memory_id) {
      try {
        attachment(row.context_memory_id, row.context_media_id, viewerID);
        context = { memoryId: row.context_memory_id, mediaId: row.context_media_id };
      } catch (error) {
        if (!(error instanceof APIError) || error.status !== 404) throw error;
      }
    }
    return { id: row.id, senderId: row.sender_id, recipientId: row.recipient_id, text: row.text,
      createdAt: new Date(row.created_at).toISOString(), context };
  }

  function page(rows, limit, serialize, rowID = row => row.id) {
    const items = rows.slice(0, limit), last = items.at(-1);
    return { items: items.map(serialize), nextCursor: rows.length > limit
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at, id: rowID(last) })).toString('base64url') : null };
  }

  return async function route({ request, response, path, method, url, user }) {
    if (path === '/v1/places/visit-counts' && method === 'POST') {
      requireValue(url.searchParams.size === 0, 'Unknown query parameter.');
      const body = object(await authorizedJSON(request, user.id), ['items']);
      requireValue(Array.isArray(body.items) && body.items.length >= 1 && body.items.length <= 100,
        'Request between 1 and 100 place/owner pairs.');
      const unique = new Map();
      for (const value of body.items) {
        const item = object(value, ['placeId', 'ownerId']);
        const placeId = id(item.placeId), ownerId = id(item.ownerId);
        unique.set(`${placeId}:${ownerId}`, { placeId, ownerId });
      }
      const items = [...unique.values()];
      // One indexed query for the batch; DISTINCT civil day, not visit/media
      // rows. No recent-feed cutoff or archive-hidden preference affects it.
      const rows = db.prepare(`WITH requested(place_id, owner_id) AS (VALUES ${items.map(() => '(?, ?)').join(',')})
        SELECT m.place_id, m.owner_id,
          COUNT(DISTINCT poi_visit_day(COALESCE(m.published_at, m.created_at), p.latitude, p.longitude)) AS count
        FROM requested r JOIN memories m ON m.place_id = r.place_id AND m.owner_id = r.owner_id
        JOIN places p ON p.id = m.place_id
        WHERE m.kind = 'poi' AND ${permitted('m')}
        GROUP BY m.place_id, m.owner_id`).all(...items.flatMap(item => [item.placeId, item.ownerId]), ...viewerArgs(user.id));
      const counts = new Map(rows.map(row => [`${row.place_id}:${row.owner_id}`, row.count]));
      json(response, 200, { items: items.map(item => ({ ...item, count: counts.get(`${item.placeId}:${item.ownerId}`) ?? 0 })),
        dayPolicy: POI_VISIT_DAY_POLICY });
      return true;
    }

    const likeMatch = /^\/v1\/memories\/([^/]+)\/media\/([^/]+)\/like$/.exec(path);
    if (likeMatch && ['GET', 'PUT'].includes(method)) {
      requireValue(url.searchParams.size === 0, 'Unknown query parameter.');
      const memoryID = id(likeMatch[1]), mediaID = id(likeMatch[2]);
      const body = method === 'PUT' ? object(await authorizedJSON(request, user.id), ['liked']) : null;
      attachment(memoryID, mediaID, user.id);
      if (body) {
        requireValue(typeof body.liked === 'boolean', 'liked must be a boolean.');
        if (body.liked) db.prepare('INSERT OR IGNORE INTO media_likes(memory_id, media_id, user_id, created_at) VALUES (?, ?, ?, ?)')
          .run(memoryID, mediaID, user.id, now());
        else db.prepare('DELETE FROM media_likes WHERE memory_id = ? AND media_id = ? AND user_id = ?')
          .run(memoryID, mediaID, user.id);
      }
      const liked = Boolean(db.prepare('SELECT 1 FROM media_likes WHERE memory_id = ? AND media_id = ? AND user_id = ?')
        .get(memoryID, mediaID, user.id));
      const count = db.prepare(`SELECT COUNT(*) AS n FROM media_likes l WHERE memory_id = ? AND media_id = ?
        AND ${visibilitySQL('l.user_id')}`).get(memoryID, mediaID, user.id, user.id).n;
      json(response, 200, { liked, count });
      return true;
    }

    const savedMatch = /^\/v1\/places\/([^/]+)\/saved$/.exec(path);
    if (savedMatch && ['GET', 'PUT'].includes(method)) {
      requireValue(url.searchParams.size === 0, 'Unknown query parameter.');
      const placeID = id(savedMatch[1]);
      const body = method === 'PUT' ? object(await authorizedJSON(request, user.id), ['saved']) : null;
      if (body) requireValue(typeof body.saved === 'boolean', 'saved must be a boolean.');
      // Removing one's own saved ID is allowed even if its source was revoked.
      // Other operations cannot use an arbitrary place ID to expose history.
      if (body?.saved !== false && !availablePlace(placeID, user.id)) throw notFound();
      if (body?.saved === true) db.prepare('INSERT OR IGNORE INTO saved_places(user_id, place_id, created_at) VALUES (?, ?, ?)')
        .run(user.id, placeID, now());
      else if (body?.saved === false) db.prepare('DELETE FROM saved_places WHERE user_id = ? AND place_id = ?').run(user.id, placeID);
      json(response, 200, { saved: Boolean(db.prepare('SELECT 1 FROM saved_places WHERE user_id = ? AND place_id = ?').get(user.id, placeID)) });
      return true;
    }

    if (path === '/v1/me/saved-places' && method === 'GET') {
      const { limit, cursor } = pageInput(url.searchParams);
      const after = cursor ? 'AND (s.created_at < ? OR (s.created_at = ? AND s.place_id < ?))' : '';
      const args = [user.id, ...viewerArgs(user.id)];
      if (cursor) args.push(cursor.createdAt, cursor.createdAt, cursor.id);
      const rows = db.prepare(`SELECT p.*, ps.source_id, s.created_at FROM saved_places s JOIN places p ON p.id = s.place_id
        LEFT JOIN place_sources ps ON ps.place_id = p.id WHERE s.user_id = ?
        AND EXISTS (SELECT 1 FROM memories m WHERE m.place_id = s.place_id AND m.kind = 'poi' AND ${permitted('m')})
        ${after} ORDER BY s.created_at DESC, s.place_id DESC LIMIT ?`).all(...args, limit + 1);
      json(response, 200, page(rows, limit, row => ({ place: serializePlace(row), savedAt: new Date(row.created_at).toISOString() })));
      return true;
    }

    const messageMatch = /^\/v1\/messages\/([^/]+)$/.exec(path);
    if (messageMatch && ['GET', 'POST'].includes(method)) {
      const peerID = id(messageMatch[1]);
      const body = method === 'POST' ? object(await authorizedJSON(request, user.id), ['id', 'text', 'context']) : null;
      peerFor(peerID, user.id);
      if (method === 'GET') {
        const { limit, cursor } = pageInput(url.searchParams);
        const after = cursor ? 'AND (created_at < ? OR (created_at = ? AND id < ?))' : '';
        const args = [user.id, peerID, peerID, user.id];
        if (cursor) args.push(cursor.createdAt, cursor.createdAt, cursor.id);
        const rows = db.prepare(`SELECT * FROM direct_messages WHERE
          ((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?))
          ${after} ORDER BY created_at DESC, id DESC LIMIT ?`).all(...args, limit + 1);
        json(response, 200, page(rows, limit, row => serializeMessage(row, user.id)));
        return true;
      }
      requireValue(url.searchParams.size === 0, 'Unknown query parameter.');
      const messageID = id(body.id);
      requireValue(typeof body.text === 'string' && body.text.length <= 1000 && !body.text.includes('\u0000'),
        'Write a message of up to 1000 characters.');
      const text = body.text.trim();
      let context = null;
      if (body.context !== undefined && body.context !== null) {
        object(body.context, ['memoryId', 'mediaId']);
        context = { memoryId: id(body.context.memoryId), mediaId: id(body.context.mediaId) };
      }
      requireValue(text.length > 0 || context !== null, 'Write a message or attach a media context.');
      const hash = digest(JSON.stringify({ recipientId: peerID, text, context }));
      const existing = db.prepare('SELECT * FROM direct_messages WHERE id = ?').get(messageID);
      if (existing) {
        if (existing.sender_id !== user.id || existing.request_hash !== hash) {
          throw new APIError(409, 'id_conflict', 'Use a new ID for a different message.');
        }
        json(response, 200, serializeMessage(existing, user.id));
        return true;
      }
      if (context && attachment(context.memoryId, context.mediaId, user.id).owner_id !== peerID) throw notFound();
      const recent = db.prepare('SELECT COUNT(*) AS n FROM direct_messages WHERE sender_id = ? AND created_at > ?')
        .get(user.id, now() - 60_000).n;
      if (recent >= 30) {
        response.setHeader('Retry-After', '60');
        throw new APIError(429, 'rate_limited', 'Please wait a moment before sending again.');
      }
      db.prepare(`INSERT INTO direct_messages(id, sender_id, recipient_id, text, context_memory_id, context_media_id, request_hash, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(messageID, user.id, peerID, text, context?.memoryId ?? null, context?.mediaId ?? null, hash, now());
      json(response, 201, serializeMessage(db.prepare('SELECT * FROM direct_messages WHERE id = ?').get(messageID), user.id));
      return true;
    }

    if (path === '/v1/messages' && method === 'GET') {
      const { limit, cursor } = pageInput(url.searchParams);
      const after = cursor ? 'AND (created_at < ? OR (created_at = ? AND peer_id < ?))' : '';
      const args = [user.id, user.id, user.id, user.id];
      if (cursor) args.push(cursor.createdAt, cursor.createdAt, cursor.id);
      // Only this viewer's messages enter the window; never scan other private
      // conversations or expose their existence. The two arms use their indexes.
      const rows = db.prepare(`WITH mine AS (
        SELECT *, recipient_id AS peer_id FROM direct_messages WHERE sender_id = ?
        UNION ALL SELECT *, sender_id AS peer_id FROM direct_messages WHERE recipient_id = ?
      ), ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY peer_id ORDER BY created_at DESC, id DESC) AS rank FROM mine)
      SELECT * FROM ranked WHERE rank = 1 AND ${visibilitySQL('ranked.peer_id')}
      ${after} ORDER BY created_at DESC, peer_id DESC LIMIT ?`).all(...args, limit + 1);
      json(response, 200, page(rows, limit, row => ({
        peer: userJSON(db, db.prepare('SELECT id, handle FROM users WHERE id = ?').get(row.peer_id)),
        lastMessage: serializeMessage(row, user.id), updatedAt: new Date(row.created_at).toISOString(),
      }), row => row.peer_id));
      return true;
    }
    return false;
  };
}
