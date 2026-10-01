// Recipe index loading and filtering.

let indexPromise = null;
const recipeCache = new Map();

export function loadIndex() {
  indexPromise ||= fetch('data/index.json').then(r => {
    if (!r.ok) throw new Error('Could not load the recipe index');
    return r.json();
  });
  return indexPromise;
}

export function getRecipe(id) {
  if (!recipeCache.has(id)) {
    recipeCache.set(id, fetch(`data/r/${encodeURIComponent(id)}.json`).then(r => {
      if (!r.ok) { recipeCache.delete(id); throw new Error('Recipe not found'); }
      return r.json();
    }));
  }
  return recipeCache.get(id);
}

export const FILTERS = {
  time: [
    ['any', 'Any time'],
    ['30', 'Under 30 min'],
    ['60', 'Under 1 hour'],
    ['120', '1 – 2 hours'],
    ['long', 'Weekend project (2h+)']
  ],
  course: [
    ['any', 'Any meal'],
    ['breakfast', 'Breakfast'],
    ['main', 'Main dish'],
    ['soup', 'Soup & stew'],
    ['side', 'Sides & snacks'],
    ['dessert', 'Dessert']
  ],
  diet: [
    ['any', 'Anything goes'],
    ['1', 'Vegetarian'],
    ['2', 'Vegan']
  ],
  difficulty: [
    ['any', 'Any skill'],
    ['easy', 'Easy'],
    ['medium', 'Medium'],
    ['hard', 'Hard']
  ],
  protein: [
    ['any', 'Surprise me'],
    ['poultry', 'Chicken & poultry'],
    ['beef', 'Beef'],
    ['pork', 'Pork'],
    ['lamb', 'Lamb & goat'],
    ['seafood', 'Seafood'],
    ['pasta', 'Pasta & noodles'],
    ['veggie', 'Veggie-forward']
  ]
};

export const DEFAULT_FILTERS = { region: 'any', cuisine: 'any', time: 'any', course: 'any', diet: 'any', difficulty: 'any', protein: 'any' };

export function matches(r, f) {
  if (f.region !== 'any' && r.g !== f.region) return false;
  if (f.cuisine !== 'any' && r.c !== f.cuisine) return false;
  if (f.course !== 'any' && r.k !== f.course) return false;
  if (f.difficulty !== 'any' && r.d !== f.difficulty) return false;
  if (f.protein !== 'any' && r.p !== f.protein) return false;
  if (f.diet !== 'any' && r.v < Number(f.diet)) return false;
  switch (f.time) {
    case '30': if (r.t > 30) return false; break;
    case '60': if (r.t > 60) return false; break;
    case '120': if (r.t <= 60 || r.t > 120) return false; break;
    case 'long': if (r.t <= 120) return false; break;
  }
  return true;
}

export function regionsAndCuisines(recipes) {
  const regions = new Map();
  for (const r of recipes) {
    if (!regions.has(r.g)) regions.set(r.g, new Map());
    if (r.c) {
      const m = regions.get(r.g);
      m.set(r.c, (m.get(r.c) || 0) + 1);
    }
  }
  return regions;
}

export function formatMinutes(m) {
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60), rest = m % 60;
  if (h >= 24) return `${Math.round(m / 1440 * 2) / 2} day${m >= 2880 ? 's' : ''}`;
  return rest ? `${h} hr ${rest} min` : `${h} hr`;
}
