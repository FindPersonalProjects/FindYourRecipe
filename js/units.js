// Converts and scales the amounts in recipe text between US and metric units.
// All functions take already-escaped HTML text and return HTML.

const FRACTIONS = { '½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3, '⅛': 0.125, '⅜': 0.375, '⅝': 0.625, '⅞': 0.875 };
const GLYPHS = [[0.125, '⅛'], [0.25, '¼'], [1 / 3, '⅓'], [0.5, '½'], [2 / 3, '⅔'], [0.75, '¾'], [0.875, '⅞']];
const SPOON = { steps: [0.125, 0.25, 0.5, 0.75] };
const HALF = { steps: [0.5] };
const QUARTER = { steps: [0.25, 0.5, 0.75] };
const CUP = { steps: [0.25, 1 / 3, 0.5, 2 / 3, 0.75] };

const NUM = String.raw`(?:\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:[.,]\d+)?\s?[½¼¾⅓⅔⅛⅜⅝⅞]|\d+(?:[.,]\d+)?|[½¼¾⅓⅔⅛⅜⅝⅞])`;
const AMOUNT = String.raw`(${NUM})(?:\s*(?:-|–|to)\s*(${NUM}))?`;

const UNIT_PATTERNS = [
  ['floz', String.raw`fl\.?\s?oz\.?|fluid ounces?`],
  ['kg', String.raw`kg|kgs|kilos?|kilograms?`],
  ['g', String.raw`g|gr|grams?|gm`],
  ['ml', String.raw`ml|mls|millilit(?:re|er)s?`],
  ['l', String.raw`l|L|lit(?:re|er)s?|ltrs?`],
  ['oz', String.raw`oz\.?|ounces?`],
  ['lb', String.raw`lbs?\.?|pounds?`],
  ['cup', String.raw`cups?|c\.`],
  ['pint', String.raw`pints?|pt`],
  ['quart', String.raw`quarts?|qts?`],
  ['stick', String.raw`sticks?`],
  ['gill', String.raw`gills?`],
  ['tbsp', String.raw`tbsp|tablespoons?`],
  ['tsp', String.raw`tsp|teaspoons?`]
];
const UNIT_ALT = UNIT_PATTERNS.map(([, p]) => p).join('|');
const AMOUNT_UNIT_RX = new RegExp(String.raw`${AMOUNT}\s*(${UNIT_ALT})(?![a-zA-Z])`, 'g');
const PAIR_RX = new RegExp(String.raw`(${NUM}(?:\s*(?:-|–|to)\s*${NUM})?)\s*(${UNIT_ALT})(?![a-zA-Z])\s*(?:\/|\(|or)\s*(${NUM}(?:\s*(?:-|–|to)\s*${NUM})?)\s*(${UNIT_ALT})(?![a-zA-Z])\)?`, 'g');
const TEMP_RX = /(\d{2,3})\s*(?:°|º|degrees?\s*)?\s*([CF])\b/g;
const LEADING_RX = new RegExp(String.raw`^(\s*)${AMOUNT}`);
const BARE_NUM_RX = new RegExp(String.raw`${AMOUNT}(?![\d/])`, 'g');

const METRIC = new Set(['g', 'kg', 'ml', 'l']);
const US = new Set(['oz', 'lb', 'cup', 'pint', 'quart', 'stick', 'floz', 'gill']);

// grams per US cup for common ingredients (most specific first)
const DENSITY = [
  [/bread flour|strong flour/, 130], [/whole ?(wheat|meal) flour/, 120], [/self[- ]raising|plain flour|all[- ]purpose|\bflour\b/, 125],
  [/icing sugar|powdered sugar|confectioners/, 120], [/brown sugar|muscovado|demerara/, 220], [/caster|granulated|\bsugar\b/, 200],
  [/\bbutter\b|margarine/, 227], [/cocoa/, 85], [/rolled oats|\boats\b|oatmeal/, 90], [/\brice\b/, 185], [/quinoa/, 170],
  [/couscous/, 180], [/lentils?/, 200], [/polenta|cornmeal/, 160], [/corn ?flour|cornstarch/, 128], [/semolina/, 167],
  [/panko/, 50], [/breadcrumbs?/, 110], [/ground almonds|almond flour/, 96], [/desiccated coconut|shredded coconut/, 85],
  [/chocolate chips|chopped chocolate/, 170], [/raisins|sultanas|currants/, 150], [/honey|golden syrup|treacle|molasses/, 340],
  [/maple syrup/, 320], [/parmesan|grated cheese|cheddar/, 100], [/peanut butter/, 258], [/yogh?urt/, 245], [/sour cream/, 230],
  [/\boil\b/, 218], [/walnuts|pecans|almonds|hazelnuts|cashews|nuts/, 120],
  [/\bsalt\b/, 290], [/baking (powder|soda)|bicarbonate/, 230], [/\byeast\b/, 150],
  [/cumin|paprika|cinnamon|turmeric|chill?i powder|ground coriander|ground ginger|black pepper|white pepper|ground pepper|cayenne|nutmeg|curry powder|garam masala|allspice|ground cloves|mixed spice|five spice/, 100],
  [/dried (oregano|thyme|basil|rosemary|mint|herbs|parsley)|mixed herbs/, 30]
];

const C_TO_F = { 100: 210, 110: 225, 120: 250, 130: 265, 140: 275, 150: 300, 160: 325, 170: 325, 175: 350, 180: 350, 190: 375, 200: 400, 210: 410, 220: 425, 230: 450, 240: 475, 250: 480 };
const F_TO_C = { 225: 110, 250: 120, 275: 140, 300: 150, 325: 160, 350: 180, 375: 190, 400: 200, 425: 220, 450: 230, 475: 240, 500: 260 };

export function defaultSystem() {
  const lang = (navigator.language || '').toLowerCase();
  return /^en-(us|lr)$|^my\b/.test(lang) ? 'us' : 'metric';
}

function unitKey(raw) {
  for (const [key, p] of UNIT_PATTERNS) if (new RegExp(`^(?:${p})$`, 'i').test(raw.trim())) return key;
  return null;
}

export function parseNum(s) {
  s = s.trim().replace(',', '.');
  let m;
  if ((m = s.match(/^(\d+)\s+(\d+)\/(\d+)$/))) return +m[1] + m[2] / m[3];
  if ((m = s.match(/^(\d+)\/(\d+)$/))) return m[1] / m[2];
  if ((m = s.match(/^(\d+(?:\.\d+)?)\s?([½¼¾⅓⅔⅛⅜⅝⅞])$/))) return +m[1] + FRACTIONS[m[2]];
  if (FRACTIONS[s] != null) return FRACTIONS[s];
  return parseFloat(s);
}

// 1.25 -> "1¼", 0.33 -> "⅓", 14.1 -> "14"
export function niceNum(n, { fractions = true, steps = null } = {}) {
  if (!isFinite(n)) return '';
  if (!fractions || n >= 20) return String(Math.round(n));
  const whole = Math.floor(n);
  const rest = n - whole;
  const allowed = steps ? GLYPHS.filter(([v]) => steps.some(s => Math.abs(s - v) < 0.01)) : GLYPHS;
  let best = [0, ''], diff = rest;
  for (const [v, g] of allowed) if (Math.abs(rest - v) < diff) { diff = Math.abs(rest - v); best = [v, g]; }
  if (Math.abs(1 - rest) < diff) return String(whole + 1);
  if (!best[1]) return String(whole);
  return whole ? `${whole}${best[1]}` : best[1];
}

function roundMetric(n) {
  if (n < 10) return Math.round(n * 2) / 2;
  if (n < 100) return Math.round(n / 5) * 5;
  if (n < 1000) return Math.round(n / 10) * 10;
  return Math.round(n / 50) * 50;
}

function densityFor(context) {
  const t = (context || '').toLowerCase();
  for (const [rx, d] of DENSITY) if (rx.test(t)) return { d, butter: /\bbutter\b|margarine/.test(t) && !/peanut|nut butter/.test(t) };
  return null;
}

// --- unit converters: value(s) in source unit -> display string in target system

function gramsToUS(g, context) {
  const dens = densityFor(context);
  if (dens) {
    const cups = g / dens.d;
    if (dens.butter && cups < 0.5) return `${niceNum(g / 14.2, HALF)} tbsp`;
    if (cups >= 0.25) return `${niceNum(cups, CUP)} cup${cups > 1.1 ? 's' : ''}`;
    const tbsp = g / (dens.d / 16);
    if (tbsp >= 1) return `${niceNum(tbsp, HALF)} tbsp`;
    return `${niceNum(tbsp * 3, SPOON)} tsp`;
  }
  const oz = g / 28.35;
  if (oz < 16) return `${niceNum(oz < 4 ? Math.max(0.25, oz) : Math.round(oz * 2) / 2, QUARTER)} oz`;
  return `${niceNum(oz / 16, QUARTER)} lb`;
}

function mlToUS(ml) {
  const tsp = ml / 4.93;
  if (tsp < 3) return `${niceNum(tsp, SPOON)} tsp`;
  const tbsp = ml / 14.79;
  if (tbsp < 4) return `${niceNum(tbsp, HALF)} tbsp`;
  const cups = ml / 236.6;
  if (cups <= 6) return `${niceNum(cups, CUP)} cup${cups > 1.1 ? 's' : ''}`;
  return `${niceNum(ml / 946, QUARTER)} quarts`;
}

function gramsToMetric(g) {
  return g >= 1000 ? `${+(g / 1000).toFixed(2)} kg` : `${roundMetric(g)} g`;
}

function mlToMetric(ml) {
  return ml >= 1000 ? `${+(ml / 1000).toFixed(2)} L` : `${roundMetric(ml)} ml`;
}

function convertOne(value, unit, system, context) {
  if (system === 'us') {
    switch (unit) {
      case 'g': return gramsToUS(value, context);
      case 'kg': return gramsToUS(value * 1000, context);
      case 'ml': return mlToUS(value);
      case 'l': return mlToUS(value * 1000);
      case 'gill': return mlToUS(value * 142);
    }
  } else {
    const dens = densityFor(context);
    switch (unit) {
      case 'oz': return gramsToMetric(value * 28.35);
      case 'lb': return gramsToMetric(value * 453.6);
      case 'stick': return gramsToMetric(value * 113);
      case 'floz': return mlToMetric(value * 29.57);
      case 'pint': return mlToMetric(value * 473);
      case 'quart': return mlToMetric(value * 946);
      case 'gill': return mlToMetric(value * 142);
      case 'cup': return dens ? gramsToMetric(value * dens.d) : mlToMetric(value * 240);
    }
  }
  return null;
}

function formatAmount(a, b, unitRaw, scale) {
  const n1 = parseNum(a) * scale;
  const n2 = b ? parseNum(b) * scale : null;
  const unit = unitKey(unitRaw);
  const metric = unit && METRIC.has(unit);
  const fmt = n => (metric ? String(roundMetric(n)) : niceNum(n));
  return { n1, n2, unit, text: n2 != null ? `${fmt(n1)}–${fmt(n2)}` : fmt(n1) };
}

function wrapConverted(html, original) {
  return `<span class="conv" title="Original: ${original}">${html}</span>`;
}

// Converts one "amount unit" occurrence. Returns null if nothing to change.
function convertMatch(a, b, unitRaw, { system, scale, context }) {
  const unit = unitKey(unitRaw);
  if (!unit) return null;
  const v1 = parseNum(a) * scale;
  const v2 = b ? parseNum(b) * scale : null;
  const needs = unit === 'gill' || (system === 'us' ? METRIC.has(unit) : US.has(unit));
  if (needs) {
    const c1 = convertOne(v1, unit, system, context);
    if (!c1) return null;
    if (v2 == null) return c1;
    const c2 = convertOne(v2, unit, system, context);
    const [n1, u1] = c1.split(/ (.+)/), [n2, u2] = c2.split(/ (.+)/);
    return u1 === u2 ? `${n1}–${n2} ${u2}` : `${c1}–${c2}`;
  }
  if (scale === 1) return null;
  const f = formatAmount(a, b, unitRaw, scale);
  return `${f.text} ${unitRaw}`;
}

function convertTemps(html, system) {
  return html.replace(TEMP_RX, (m, deg, unit) => {
    const d = +deg;
    if (system === 'us' && unit === 'C' && d >= 90) {
      const f = C_TO_F[d] ?? Math.round((d * 9 / 5 + 32) / 5) * 5;
      return wrapConverted(`${f}°F`, m);
    }
    if (system === 'metric' && unit === 'F' && d >= 200) {
      const c = F_TO_C[d] ?? Math.round(((d - 32) * 5 / 9) / 5) * 5;
      return wrapConverted(`${c}°C`, m);
    }
    return m;
  });
}

// Pick the matching half of "225 g (8 oz)" / "400g/14oz" pairs.
function resolvePairs(html, system, scale, context) {
  return html.replace(PAIR_RX, (m, amt1, u1, amt2, u2) => {
    const k1 = unitKey(u1), k2 = unitKey(u2);
    if (!k1 || !k2) return m;
    const sys1 = METRIC.has(k1) ? 'metric' : US.has(k1) ? 'us' : null;
    const sys2 = METRIC.has(k2) ? 'metric' : US.has(k2) ? 'us' : null;
    if (!sys1 || !sys2 || sys1 === sys2) return m;
    const [amt, u] = sys1 === system ? [amt1, u1] : [amt2, u2];
    const parts = amt.split(/\s*(?:-|–|to)\s*/);
    const out = convertMatch(parts[0], parts[1], u, { system, scale, context });
    return `\u0000${out ?? `${amt} ${u}`}\u0001`;
  });
}

function protect(html, fn) {
  // Segments between \u0000 and \u0001 are already final.
  return html.split(/(\u0000[^\u0001]*\u0001)/).map(seg => (seg.startsWith('\u0000') ? seg : fn(seg))).join('');
}

/**
 * Converts amounts in an ingredient or step.
 *   system: 'us' | 'metric'
 *   scale: batch multiplier (1 = as written)
 *   scaleBare: also scale bare numbers ("2" eggs) - for ingredient text only
 *   context: ingredient name, used for cup <-> gram densities
 */
export function convertText(html, { system, scale = 1, scaleBare = false, leadingOnly = false, context = '' }) {
  let out = resolvePairs(html, system, scale, context);
  out = protect(out, seg => seg.replace(AMOUNT_UNIT_RX, (m, a, b, unitRaw) => {
    const r = convertMatch(a, b, unitRaw, { system, scale, context: context || seg });
    if (r == null) return m;
    return `\u0000${unitKey(unitRaw) && (system === 'us' ? METRIC : US).has(unitKey(unitRaw)) ? wrapConverted(r, m) : r}\u0001`;
  }));
  if (scale !== 1 && scaleBare) {
    out = protect(out, seg => {
      if (leadingOnly) {
        return seg.replace(LEADING_RX, (m, sp, a, b) => `${sp}${formatAmount(a, b, '', scale).text}`);
      }
      return seg.replace(BARE_NUM_RX, (m, a, b) => formatAmount(a, b, '', scale).text);
    });
  }
  out = protect(out, seg => convertTemps(seg, system));
  return out.replace(/[\u0000\u0001]/g, '');
}
