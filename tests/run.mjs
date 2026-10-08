// Node test runner, used by .github/workflows/tests.yml. Run locally with: node tests/run.mjs
import { readFileSync, existsSync } from 'node:fs';
import { runCases } from './cases.js';

let failed = await runCases();

// Data integrity: every index entry has a recipe file with ingredients and steps.
try {
  const index = JSON.parse(readFileSync(new URL('../data/index.json', import.meta.url)));
  const missing = index.recipes.filter(r => !existsSync(new URL(`../data/r/${r.id}.json`, import.meta.url)));
  const sample = index.recipes.filter((_, i) => i % 50 === 0);
  const broken = sample.filter(r => {
    const full = JSON.parse(readFileSync(new URL(`../data/r/${r.id}.json`, import.meta.url)));
    return !full.name || ![].concat(full.ingredients).length || ![].concat(full.steps).length;
  });
  if (index.count !== index.recipes.length) { failed++; console.log(`✘ index count ${index.count} != ${index.recipes.length}`); }
  if (missing.length) { failed++; console.log(`✘ ${missing.length} index entries have no recipe file, e.g. ${missing[0].id}`); }
  else console.log(`✔ all ${index.recipes.length} index entries have a recipe file`);
  if (broken.length) { failed++; console.log(`✘ recipes missing name/ingredients/steps: ${broken.map(r => r.id).join(', ')}`); }
  else console.log(`✔ sampled ${sample.length} recipes are complete`);
} catch (e) {
  failed++;
  console.log(`✘ data check crashed: ${e.message}`);
}

process.exit(failed ? 1 : 0);
