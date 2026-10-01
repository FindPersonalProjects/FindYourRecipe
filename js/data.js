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
    ['15', 'Under 15 min'],
    ['30', 'Under 30 min'],
    ['60', 'Under 1 hour'],
    ['120', '1 – 2 hours'],
    ['long', 'Weekend project (2h+)']
  ],
  hands: [
    ['any', 'Any amount'],
    ['15', '15 min or less'],
    ['30', '30 min or less'],
    ['60', '1 hour or less']
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
    ['1', 'Pescatarian'],
    ['2', 'Vegetarian'],
    ['3', 'Vegan']
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

// Bit flags written by scripts/build-recipes.ps1 (index field "x").
export const ALLERGENS = [
  ['gluten', 1, 'Gluten'],
  ['dairy', 2, 'Dairy'],
  ['egg', 4, 'Eggs'],
  ['peanut', 8, 'Peanuts'],
  ['treenut', 16, 'Tree nuts'],
  ['fish', 32, 'Fish'],
  ['shellfish', 64, 'Shellfish'],
  ['soy', 128, 'Soy'],
  ['sesame', 256, 'Sesame'],
  ['pork', 512, 'Pork'],
  ['alcohol', 1024, 'Alcohol']
];

export function allergenNames(mask) {
  return ALLERGENS.filter(([, bit]) => mask & bit).map(([, , label]) => label);
}

export const DIET_LABEL = { 1: 'Pescatarian', 2: 'Vegetarian', 3: 'Vegan' };

export const DEFAULT_FILTERS = { region: 'any', cuisine: 'any', time: 'any', hands: 'any', course: 'any', diet: 'any', difficulty: 'any', protein: 'any', avoid: [] };

export function matches(r, f) {
  if (f.avoid?.length) {
    const mask = ALLERGENS.filter(([key]) => f.avoid.includes(key)).reduce((m, [, bit]) => m | bit, 0);
    if (r.x & mask) return false;
  }
  if (f.hands !== 'any' && r.h > Number(f.hands)) return false;
  if (f.region !== 'any' && r.g !== f.region) return false;
  if (f.cuisine !== 'any' && r.c !== f.cuisine) return false;
  if (f.course !== 'any' && r.k !== f.course) return false;
  if (f.difficulty !== 'any' && r.d !== f.difficulty) return false;
  if (f.protein !== 'any' && r.p !== f.protein) return false;
  if (f.diet !== 'any' && r.v < Number(f.diet)) return false;
  switch (f.time) {
    case '15': if (r.t > 15) return false; break;
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
