// Test cases shared by the Node runner (tests/run.mjs, used in CI) and the browser runner (tests/index.html).

import { convertText, parseNum, niceNum } from '../js/units.js';
import { matches, DEFAULT_FILTERS, formatMinutes, allergenNames, lifestyleNames } from '../js/data.js';
import { computeBadges } from '../js/badges.js';
import { isoWeek, pickChallenge } from '../js/week.js';

const strip = html => html.replace(/<[^>]+>/g, '');
const us = (text, context = '', scale = 1) => strip(convertText(text, { system: 'us', scale, scaleBare: true, context }));
const metric = (text, context = '', scale = 1) => strip(convertText(text, { system: 'metric', scale, scaleBare: true, context }));

function eq(actual, expected, label = '') {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label ? label + ': ' : ''}expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const recipe = (over = {}) => ({ id: 'x', c: 'Italian', g: 'Europe', k: 'main', p: 'beef', t: 45, h: 30, d: 'easy', v: 0, x: 0, y: 0, e: 0, ...over });

export const cases = [
  // ---------------------------------------------------------------- units
  ['parses fractions and mixed numbers', () => {
    eq(parseNum('1 1/2'), 1.5); eq(parseNum('½'), 0.5); eq(parseNum('2½'), 2.5); eq(parseNum('1,5'), 1.5);
  }],
  ['formats amounts as kitchen fractions', () => {
    eq(niceNum(0.25), '¼'); eq(niceNum(1.5), '1½'); eq(niceNum(2.98), '3'); eq(niceNum(25.4), '25');
  }],
  ['grams of meat become ounces or pounds', () => {
    eq(us('400 g', 'chicken'), '14 oz'); eq(us('600 g', 'chicken'), '1¼ lb'); eq(us('1.5 kg', 'potatoes'), '3¼ lb');
  }],
  ['baking staples convert by volume', () => {
    eq(us('250 g', 'plain flour'), '2 cups'); eq(us('200 g', 'caster sugar'), '1 cup'); eq(us('30 g', 'butter'), '2 tbsp');
    eq(us('5 g', 'salt'), '¾ tsp');
  }],
  ['red pepper (the vegetable) is not treated as a spice', () => { eq(us('400 g', 'red pepper'), '14 oz'); }],
  ['liquids convert to cups', () => { eq(us('350 ml', 'stock'), '1½ cups'); eq(us('500 ml', 'stock'), '2 cups'); }],
  ['US amounts convert to metric', () => {
    eq(metric('8 oz', 'beef'), '230 g'); eq(metric('1 cup', 'milk'), '240 ml'); eq(metric('1 1/2 cups', 'flour'), '190 g');
  }],
  ['oven temperatures convert', () => {
    eq(strip(convertText('Heat to 200C/180C fan.', { system: 'us' })), 'Heat to 400°F/350°F fan.');
    eq(strip(convertText('Preheat to 350°F.', { system: 'metric' })), 'Preheat to 180°C.');
  }],
  ['paired units keep only the chosen system', () => {
    eq(strip(convertText('8 oz (225 g) minced beef', { system: 'us', scale: 1, scaleBare: true, leadingOnly: true })), '8 oz minced beef');
    eq(strip(convertText('8 oz (225 g) minced beef', { system: 'metric', scale: 2, scaleBare: true, leadingOnly: true })), '450 g minced beef');
  }],
  ['batch scaling scales counts and ranges', () => {
    eq(us('1/2', 'lime', 2), '1'); eq(us('2-3 cloves', 'garlic', 2), '4–6 cloves'); eq(us('Juice of 1/2', 'lemon', 3), 'Juice of 1½');
  }],

  // ---------------------------------------------------------------- filters
  ['default filters match everything', () => { eq(matches(recipe(), DEFAULT_FILTERS), true); }],
  ['diet levels nest (vegan counts as vegetarian)', () => {
    const f = { ...DEFAULT_FILTERS, diet: '2' };
    eq(matches(recipe({ v: 3 }), f), true); eq(matches(recipe({ v: 2 }), f), true); eq(matches(recipe({ v: 1 }), f), false);
  }],
  ['allergy filter excludes recipes containing it', () => {
    const f = { ...DEFAULT_FILTERS, avoid: ['gluten', 'peanut'] };
    eq(matches(recipe({ x: 0 }), f), true); eq(matches(recipe({ x: 1 }), f), false); eq(matches(recipe({ x: 8 | 2 }), f), false);
    eq(matches(recipe({ x: 2 }), f), true);
  }],
  ['lifestyle filter needs every chosen tag', () => {
    const f = { ...DEFAULT_FILTERS, lifestyle: ['halal', 'lowcarb'] };
    eq(matches(recipe({ y: 1 | 4 }), f), true); eq(matches(recipe({ y: 1 }), f), false);
  }],
  ['time filters', () => {
    eq(matches(recipe({ t: 15 }), { ...DEFAULT_FILTERS, time: '15' }), true);
    eq(matches(recipe({ t: 20 }), { ...DEFAULT_FILTERS, time: '15' }), false);
    eq(matches(recipe({ t: 90 }), { ...DEFAULT_FILTERS, time: '120' }), true);
    eq(matches(recipe({ t: 600, h: 20 }), { ...DEFAULT_FILTERS, hands: '30' }), true);
  }],
  ['era filter', () => {
    eq(matches(recipe({ e: 1 }), { ...DEFAULT_FILTERS, era: 'modern' }), false);
    eq(matches(recipe({ e: 1 }), { ...DEFAULT_FILTERS, era: 'vintage' }), true);
  }],
  ['formats minutes', () => { eq(formatMinutes(45), '45 min'); eq(formatMinutes(90), '1 hr 30 min'); eq(formatMinutes(120), '2 hr'); }],
  ['names allergens and lifestyles', () => {
    eq(allergenNames(1 | 4), ['Gluten', 'Eggs']); eq(allergenNames(512, 'avoid'), ['Pork']); eq(lifestyleNames(1 | 64), ['Halal-friendly', 'No added sugar']);
  }],

  // ---------------------------------------------------------------- weekly challenge
  ['ISO week numbers', () => {
    eq(isoWeek(new Date(2026, 9, 7)), '2026-W41'); eq(isoWeek(new Date(2021, 0, 3)), '2020-W53'); eq(isoWeek(new Date(2024, 11, 30)), '2025-W01');
  }],
  ['challenge pick is stable and skips vintage/hard/long recipes', () => {
    const index = [recipe({ id: 'a' }), recipe({ id: 'b' }), recipe({ id: 'c', e: 1 }), recipe({ id: 'd', d: 'hard' }), recipe({ id: 'e', t: 300 })];
    const pick = pickChallenge(index, '2026-W41');
    eq(['a', 'b'].includes(pick), true);
    // Adding a recipe either keeps the pick or picks the new one; it never reshuffles to another old recipe.
    eq([pick, 'new-one'].includes(pickChallenge([...index, recipe({ id: 'new-one' })], '2026-W41')), true);
    // Removing other recipes keeps the pick.
    eq(pickChallenge(index.filter(r => r.id === pick), '2026-W41'), pick);
    // Different weeks can pick different recipes, but the same week always picks the same one.
    eq(pickChallenge(index, '2026-W41'), pick);
  }],

  // ---------------------------------------------------------------- badges
  ['badges unlock from history', () => {
    const meta = { a: recipe({ id: 'a', e: 1 }), b: recipe({ id: 'b', k: 'dessert' }) };
    const draws = [{ recipe_id: 'a' }, { recipe_id: 'b', kind: 'challenge' }];
    const ratings = { a: { stars: 1, created_at: '2026-10-01T10:00:00Z' }, b: { stars: 5, created_at: '2026-10-02T10:00:00Z' } };
    const got = Object.fromEntries(computeBadges({ draws, ratings, meta, photos: {} }).map(b => [b.id, b.earned]));
    eq(got['first-stir'], true); eq(got['time-traveler'], true); eq(got['challenger'], true); eq(got['brave-soul'], true);
    eq(got['home-cook'], false); eq(got['on-a-roll'], false);
  }]
];

export async function runCases(log = console.log) {
  let failed = 0;
  for (const [name, fn] of cases) {
    try { await fn(); log(`✔ ${name}`); }
    catch (e) { failed++; log(`✘ ${name}\n    ${e.message}`); }
  }
  log(`\n${cases.length - failed} passed, ${failed} failed`);
  return failed;
}
