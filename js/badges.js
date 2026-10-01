// Achievement badges, worked out from the cook's own history.

const day = iso => (iso || '').slice(0, 10);

function longestStreak(dates) {
  const days = [...new Set(dates.map(day))].sort();
  let best = 0, run = 0, prev = null;
  for (const d of days) {
    run = prev && (new Date(d) - new Date(prev)) === 86400000 ? run + 1 : 1;
    best = Math.max(best, run);
    prev = d;
  }
  return best;
}

/**
 * ctx: { draws, ratings (id -> {stars, created_at}), meta (id -> index entry), photos (id -> url) }
 * Returns [{ id, icon, name, desc, have, need, earned }]
 */
export function computeBadges({ draws, ratings, meta, photos }) {
  const rated = Object.entries(ratings).map(([id, r]) => ({ id, ...r, m: meta[id] || {} }));
  const count = fn => rated.filter(fn).length;
  const regions = new Set(rated.map(r => r.m.g).filter(g => g && g !== 'Global'));
  const cuisines = new Set(rated.map(r => r.m.c).filter(Boolean));
  const challengeIds = new Set(draws.filter(d => d.kind === 'challenge').map(d => d.recipe_id));

  const list = [
    ['first-stir', '🥄', 'First Stir', 'Draw your first mystery recipe', new Set(draws.map(d => d.recipe_id)).size, 1],
    ['first-verdict', '⭐', 'First Verdict', 'Cook and rate a recipe', rated.length, 1],
    ['home-cook', '🍳', 'Home Cook', 'Rate 10 recipes', rated.length, 10],
    ['head-chef', '👩‍🍳', 'Head Chef', 'Rate 25 recipes', rated.length, 25],
    ['globe-trotter', '🌍', 'Globe Trotter', 'Cook dishes from 5 regions', regions.size, 5],
    ['culture-collector', '🗺️', 'Culture Collector', 'Cook 10 different cuisines', cuisines.size, 10],
    ['time-traveler', '📜', 'Time Traveler', 'Cook a vintage recipe', count(r => r.m.e), 1],
    ['challenger', '🏆', 'Challenger', 'Finish a weekly challenge', rated.filter(r => challengeIds.has(r.id)).length, 1],
    ['sweet-tooth', '🍰', 'Sweet Tooth', 'Cook 5 desserts', count(r => r.m.k === 'dessert'), 5],
    ['plant-powered', '🌱', 'Plant Powered', 'Cook 5 vegan dishes', count(r => r.m.v === 3), 5],
    ['dragon-slayer', '🐉', 'Dragon Slayer', 'Cook a hard recipe', count(r => r.m.d === 'hard'), 1],
    ['brave-soul', '🧯', 'Honest Critic', 'Give a recipe 1 star', count(r => r.stars === 1), 1],
    ['easy-to-please', '😍', 'Easy to Please', 'Give 5 recipes 5 stars', count(r => r.stars === 5), 5],
    ['on-a-roll', '🔥', 'On a Roll', 'Rate recipes 3 days in a row', longestStreak(rated.map(r => r.created_at)), 3],
    ['photographer', '📷', 'Food Photographer', 'Add 3 photos of your dishes', Object.keys(photos || {}).length, 3]
  ];
  return list.map(([id, icon, name, desc, have, need]) => ({ id, icon, name, desc, have: Math.min(have, need), need, earned: have >= need }));
}
