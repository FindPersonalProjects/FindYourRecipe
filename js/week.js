// Week numbers and the weekly challenge pick. Pure functions, shared by the app and the tests.

export function isoWeek(d = new Date()) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const year = t.getUTCFullYear();
  const week = Math.ceil(((t - Date.UTC(year, 0, 1)) / 86400000 + 1) / 7);
  return `${year}-W${String(week).padStart(2, '0')}`;
}

export function fnv1a(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

// Same recipe for everyone this week: the eligible recipe with the lowest hash(week + id).
// Adding or removing other recipes never changes the pick.
export function pickChallenge(index, week) {
  let best = null, bestHash = Infinity;
  for (const r of index) {
    if (r.e || r.t > 120 || r.d === 'hard') continue;
    const h = fnv1a(`${week}:${r.id}`);
    if (h < bestHash) { bestHash = h; best = r.id; }
  }
  return best;
}
