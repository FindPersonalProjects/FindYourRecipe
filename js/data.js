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
    }).then(r => {
      // Single-item lists can arrive as a bare value; always hand out arrays.
      r.steps = [].concat(r.steps || []);
      r.ingredients = [].concat(r.ingredients || []);
      return r;
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
  era: [
    ['any', 'Old and new'],
    ['modern', 'Modern only'],
    ['vintage', '📜 Vintage only (1861–1896)']
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
// [key, bit, label, group]: group "allergy" = common allergens, "avoid" = other things people skip
export const ALLERGENS = [
  ['gluten', 1, 'Gluten', 'allergy'],
  ['dairy', 2, 'Dairy', 'allergy'],
  ['egg', 4, 'Eggs', 'allergy'],
  ['peanut', 8, 'Peanuts', 'allergy'],
  ['treenut', 16, 'Tree nuts', 'allergy'],
  ['fish', 32, 'Fish', 'allergy'],
  ['shellfish', 64, 'Shellfish', 'allergy'],
  ['soy', 128, 'Soy', 'allergy'],
  ['sesame', 256, 'Sesame', 'allergy'],
  ['mustard', 2048, 'Mustard', 'allergy'],
  ['celery', 4096, 'Celery', 'allergy'],
  ['sulfites', 8192, 'Sulfites', 'allergy'],
  ['pork', 512, 'Pork', 'avoid'],
  ['redmeat', 1048576, 'Red meat', 'avoid'],
  ['alcohol', 1024, 'Alcohol', 'avoid'],
  ['spicy', 524288, 'Spicy heat', 'avoid'],
  ['nightshade', 16384, 'Nightshades', 'avoid'],
  ['allium', 262144, 'Onion & garlic', 'avoid'],
  ['mushroom', 32768, 'Mushrooms', 'avoid'],
  ['coconut', 65536, 'Coconut', 'avoid'],
  ['corn', 131072, 'Corn', 'avoid']
];

export function allergenNames(mask, group = 'allergy') {
  return ALLERGENS.filter(([, bit, , g]) => g === group && mask & bit).map(([, , label]) => label);
}

// Ingredient-based lifestyle tags (index field "y"); approximations, not certifications.
export const LIFESTYLES = [
  ['halal', 1, 'Halal-friendly', 'No pork, alcohol or blood. Meat still needs to be halal.'],
  ['kosher', 2, 'Kosher-style', 'No pork, shellfish or non-kosher fish, and no meat with dairy. Not certified.'],
  ['lowcarb', 4, 'Low-carb', 'No bread, pasta, rice, potatoes, sugar or other starchy staples.'],
  ['keto', 8, 'Keto-friendly', 'Low-carb, plus no beans, sweet fruit, milk or added sugar.'],
  ['paleo', 16, 'Paleo', 'No grains, legumes, dairy, refined sugar or processed oils.'],
  ['whole30', 32, 'Whole30-friendly', 'Paleo, plus no alcohol.'],
  ['nosugar', 64, 'No added sugar', 'No sugar, honey, syrups or sweetened extras.']
];

export function lifestyleNames(mask) {
  return LIFESTYLES.filter(([, bit]) => mask & bit).map(([, , label]) => label);
}

export const DIET_LABEL = { 1: 'Pescatarian', 2: 'Vegetarian', 3: 'Vegan' };

export const DEFAULT_FILTERS = { region: 'any', cuisine: 'any', time: 'any', hands: 'any', course: 'any', diet: 'any', difficulty: 'any', protein: 'any', era: 'any', avoid: [], lifestyle: [] };

export function matches(r, f) {
  if (f.avoid?.length) {
    const mask = ALLERGENS.filter(([key]) => f.avoid.includes(key)).reduce((m, [, bit]) => m | bit, 0);
    if (r.x & mask) return false;
  }
  if (f.lifestyle?.length) {
    const need = LIFESTYLES.filter(([key]) => f.lifestyle.includes(key)).reduce((m, [, bit]) => m | bit, 0);
    if (((r.y || 0) & need) !== need) return false;
  }
  if (f.era === 'modern' && r.e) return false;
  if (f.era === 'vintage' && !r.e) return false;
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
