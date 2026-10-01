import { createStore } from './store.js';
import { DAILY_LIMIT } from './config.js';
import { loadIndex, getRecipe, FILTERS, DEFAULT_FILTERS, matches, regionsAndCuisines, formatMinutes } from './data.js';
import { cultureFor } from './cultures.js';

// ------------------------------------------------------------------ helpers

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const wait = ms => new Promise(r => setTimeout(r, ms));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const safeUrl = u => (/^https?:\/\//i.test(u || '') ? u : '');
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

function lsGet(key, fallback) {
  try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; } catch { return fallback; }
}
function lsSet(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* ignore */ }
}

let toastTimer;
function toast(msg, ms = 3200) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

const COURSE_LABEL = { breakfast: 'Breakfast', main: 'Main dish', soup: 'Soup & stew', side: 'Side / snack', dessert: 'Dessert' };
const DIFF_LABEL = { easy: 'Easy', medium: 'Medium', hard: 'Hard' };
const DIET_LABEL = { 1: 'Vegetarian', 2: 'Vegan' };

const SPOON_SVG = `<svg class="spoon" viewBox="0 0 32 32" aria-hidden="true">
  <ellipse cx="11" cy="11" rx="7" ry="9" transform="rotate(-45 11 11)" fill="#C98B4E" stroke="#8A5A2B" stroke-width="1.5"/>
  <line x1="15" y1="15" x2="29" y2="29" stroke="#8A5A2B" stroke-width="4" stroke-linecap="round"/></svg>`;

// ------------------------------------------------------------------ state

const state = {
  store: null,
  user: null,
  index: [],
  mode: lsGet('fyr:mode', 'gamble'),
  filters: { ...DEFAULT_FILTERS, ...lsGet('fyr:filters', {}) },
  usedToday: 0,
  draws: [],           // [{recipe_id, created_at}]
  ratings: {},         // recipe_id -> {stars, note}
  saved: new Set(),
  busy: false,
  timers: [],
  cookbookTab: 'pending'
};

// ------------------------------------------------------------------ boot

async function boot() {
  try {
    const [store, idx] = await Promise.all([createStore(), loadIndex()]);
    state.store = store;
    state.index = idx.recipes;
  } catch (e) {
    console.error(e);
    $('#potCount').textContent = 'The kitchen could not open. Please refresh the page.';
    return;
  }

  $('#demoBanner').hidden = state.store.mode !== 'local';
  state.user = state.store.user();
  state.store.onAuthChange(async user => {
    state.user = user;
    await refreshUserData();
    route();
  });

  buildFilters();
  wireKitchen();
  wireAuth();
  wireCookMode();
  setInterval(tickClock, 30000);

  await refreshUserData();
  window.addEventListener('hashchange', route);
  route();
}

async function refreshUserData() {
  updateAccountButton();
  if (!state.user) {
    state.usedToday = 0; state.draws = []; state.ratings = {}; state.saved = new Set();
  } else {
    try {
      const [used, hist, saved] = await Promise.all([state.store.usedToday(), state.store.history(), state.store.saved()]);
      state.usedToday = used;
      state.draws = hist.draws;
      state.ratings = Object.fromEntries(hist.ratings.map(r => [r.recipe_id, r]));
      state.saved = new Set(saved.map(s => s.recipe_id));
    } catch (e) {
      console.error(e);
      toast('Could not load your cookbook. Check your connection.');
    }
  }
  renderSpoons();
  renderPotCount();
  updatePendingBadge();
}

// ------------------------------------------------------------------ routing

function route() {
  const hash = location.hash || '#/';
  const [, page, id] = hash.split('/');
  $$('.view').forEach(v => { v.hidden = true; });
  $$('[data-nav]').forEach(a => a.removeAttribute('aria-current'));

  if (page === 'cookbook') {
    $('#view-cookbook').hidden = false;
    $('[data-nav="cookbook"]').setAttribute('aria-current', 'page');
    setDocked(false, false);
    renderCookbook();
  } else if (page === 'recipe' && id) {
    $('#view-recipe').hidden = false;
    setDocked(false, false);
    renderStaticRecipe(decodeURIComponent(id));
  } else {
    $('#view-kitchen').hidden = false;
    $('[data-nav="kitchen"]').setAttribute('aria-current', 'page');
    if (!$('#recipeCard').hidden) setDocked(true, false);
  }
  window.scrollTo({ top: 0 });
}

// ------------------------------------------------------------------ account

function updateAccountButton() {
  const b = $('#accountBtn');
  b.textContent = state.user ? `👩‍🍳 ${state.user.name}` : 'Sign in';
}

function updatePendingBadge() {
  const n = pendingIds().length;
  const b = $('#pendingBadge');
  b.hidden = n === 0;
  b.textContent = n;
  b.title = `${n} recipe${n === 1 ? '' : 's'} waiting for your rating`;
}

function pendingIds() {
  const seen = new Set();
  const out = [];
  for (const d of state.draws) {
    if (seen.has(d.recipe_id)) continue;
    seen.add(d.recipe_id);
    if (!state.ratings[d.recipe_id]) out.push(d.recipe_id);
  }
  return out;
}

// ------------------------------------------------------------------ auth dialog

let authMode = 'signin';

function wireAuth() {
  $('#accountBtn').addEventListener('click', () => openAuth(state.user ? 'account' : 'signin'));
  $('#authForm').addEventListener('submit', onAuthSubmit);
  $('#authSwitch').addEventListener('click', e => {
    const m = e.target.closest('[data-auth]');
    if (m) { e.preventDefault(); openAuth(m.dataset.auth); }
  });
}

function openAuth(mode, reason) {
  authMode = mode;
  const local = state.store.mode === 'local';
  const fields = $('.auth-fields');
  const sw = $('#authSwitch');
  $('#authError').textContent = '';

  if (mode === 'account') {
    $('#authTitle').textContent = `Hi, ${state.user.name}!`;
    $('#authSub').textContent = local ? 'You are cooking in demo mode on this browser.' : `Signed in as ${state.user.email}`;
    fields.innerHTML = '';
    $('#authSubmit').textContent = 'Sign out';
    sw.innerHTML = '';
  } else if (local) {
    $('#authTitle').textContent = 'Pull up a chair';
    $('#authSub').textContent = reason || 'Pick a cook name to start stirring. (Demo mode: saved in this browser only.)';
    fields.innerHTML = `<label class="field"><span>Cook name</span><input name="name" required maxlength="40" autocomplete="nickname" placeholder="e.g. Grandma Rosa"></label>`;
    $('#authSubmit').textContent = 'Start cooking';
    sw.innerHTML = '';
  } else if (mode === 'signup') {
    $('#authTitle').textContent = 'Join the kitchen';
    $('#authSub').textContent = reason || 'Make an account to keep your cookbook on any device.';
    fields.innerHTML = `
      <label class="field"><span>Cook name</span><input name="name" required maxlength="40" autocomplete="nickname"></label>
      <label class="field"><span>Email</span><input name="email" type="email" required autocomplete="email"></label>
      <label class="field"><span>Password</span><input name="password" type="password" required minlength="8" autocomplete="new-password"></label>`;
    $('#authSubmit').textContent = 'Create account';
    sw.innerHTML = `Already have an account? <a href="#" data-auth="signin">Sign in</a>`;
  } else if (mode === 'reset') {
    $('#authTitle').textContent = 'Forgot your password?';
    $('#authSub').textContent = 'We will email you a link to reset it.';
    fields.innerHTML = `<label class="field"><span>Email</span><input name="email" type="email" required autocomplete="email"></label>`;
    $('#authSubmit').textContent = 'Send reset link';
    sw.innerHTML = `<a href="#" data-auth="signin">Back to sign in</a>`;
  } else {
    $('#authTitle').textContent = 'Welcome back';
    $('#authSub').textContent = reason || 'Sign in to stir the pot, save recipes and keep your cookbook.';
    fields.innerHTML = `
      <label class="field"><span>Email</span><input name="email" type="email" required autocomplete="email"></label>
      <label class="field"><span>Password</span><input name="password" type="password" required autocomplete="current-password"></label>`;
    $('#authSubmit').textContent = 'Sign in';
    sw.innerHTML = `New here? <a href="#" data-auth="signup">Create an account</a> · <a href="#" data-auth="reset">Forgot password?</a>`;
  }
  const dlg = $('#authDialog');
  if (!dlg.open) dlg.showModal();
  $('input', fields)?.focus();
}

async function onAuthSubmit(e) {
  if (e.submitter?.value === 'cancel') return;
  e.preventDefault();
  const form = new FormData(e.target);
  const btn = $('#authSubmit');
  btn.disabled = true;
  $('#authError').textContent = '';
  try {
    if (authMode === 'account') {
      await state.store.signOut();
      $('#authDialog').close();
      toast('Signed out. See you at the stove!');
      return;
    }
    const args = Object.fromEntries(form);
    if (authMode === 'signup') {
      const { needsConfirm } = await state.store.signUp(args);
      if (needsConfirm) {
        $('#authTitle').textContent = 'Check your inbox';
        $('#authSub').textContent = `We sent a confirmation link to ${args.email}. Click it, then come back and sign in.`;
        $('.auth-fields').innerHTML = '';
        authMode = 'signin-after';
        btn.textContent = 'Got it';
        return;
      }
    } else if (authMode === 'reset') {
      await state.store.resetPassword(args.email);
      toast('Reset link sent, check your email.');
      openAuth('signin');
      return;
    } else if (authMode === 'signin-after') {
      openAuth('signin');
      return;
    } else {
      await state.store.signIn(args);
    }
    $('#authDialog').close();
    toast(`Welcome to the kitchen, ${state.store.user()?.name || 'chef'}!`);
  } catch (err) {
    $('#authError').textContent = err.message || 'Something went wrong.';
  } finally {
    btn.disabled = false;
  }
}

// ------------------------------------------------------------------ filters

function buildFilters() {
  for (const fs of $$('.chips')) {
    const key = fs.dataset.filter;
    for (const [value, label] of FILTERS[key]) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'chip';
      b.dataset.value = value;
      b.textContent = label;
      fs.append(b);
    }
    fs.addEventListener('click', e => {
      const chip = e.target.closest('.chip');
      if (!chip) return;
      setFilter(key, chip.dataset.value);
    });
  }

  const regionSel = $('#f-region');
  const regions = regionsAndCuisines(state.index);
  const regionNames = [...regions.keys()].sort((a, b) => (a === 'Global') - (b === 'Global') || a.localeCompare(b));
  regionSel.innerHTML = `<option value="any">All regions</option>` +
    regionNames.map(r => `<option value="${esc(r)}">${esc(r === 'Global' ? 'Global / unlisted' : r)}</option>`).join('');
  regionSel.addEventListener('change', () => {
    state.filters.cuisine = 'any';
    setFilter('region', regionSel.value);
  });
  $('#f-cuisine').addEventListener('change', e => setFilter('cuisine', e.target.value));
  $('#resetFilters').addEventListener('click', () => {
    state.filters = { ...DEFAULT_FILTERS };
    saveFilters();
    syncFilterUI();
  });

  $$('.mode-btn').forEach(b => b.addEventListener('click', () => {
    state.mode = b.dataset.mode;
    lsSet('fyr:mode', state.mode);
    syncFilterUI();
  }));
  syncFilterUI();
}

function setFilter(key, value) {
  state.filters[key] = value;
  saveFilters();
  syncFilterUI();
}

function saveFilters() { lsSet('fyr:filters', state.filters); }

function syncFilterUI() {
  const picky = state.mode === 'picky';
  $('#filters').hidden = !picky;
  $$('.mode-btn').forEach(b => b.setAttribute('aria-checked', String(b.dataset.mode === state.mode)));

  for (const fs of $$('.chips')) {
    const key = fs.dataset.filter;
    $$('.chip', fs).forEach(c => c.setAttribute('aria-pressed', String(c.dataset.value === state.filters[key])));
  }
  $('#f-region').value = state.filters.region;

  // cuisine list depends on region
  const regions = regionsAndCuisines(state.index);
  const counts = new Map();
  for (const [region, cuisines] of regions) {
    if (state.filters.region !== 'any' && region !== state.filters.region) continue;
    for (const [c, n] of cuisines) counts.set(c, (counts.get(c) || 0) + n);
  }
  const sel = $('#f-cuisine');
  sel.innerHTML = `<option value="any">Every culture</option>` +
    [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0]))
      .map(([c, n]) => `<option value="${esc(c)}">${esc(c)} (${n})</option>`).join('');
  if (state.filters.cuisine !== 'any' && !counts.has(state.filters.cuisine)) state.filters.cuisine = 'any';
  sel.value = state.filters.cuisine;

  renderPotCount();
}

function activeFilters() {
  return state.mode === 'picky' ? state.filters : DEFAULT_FILTERS;
}

function candidates() {
  const f = activeFilters();
  const all = state.index.filter(r => matches(r, f)).map(r => r.id);
  // Prefer recipes the user hasn't drawn before.
  const drawn = new Set(state.draws.map(d => d.recipe_id));
  const fresh = all.filter(id => !drawn.has(id));
  return { all, fresh: fresh.length ? fresh : all };
}

function renderPotCount() {
  if (!state.index.length) return;
  const { all } = candidates();
  const n = all.length;
  const el = $('#potCount');
  if (state.mode === 'gamble') {
    el.textContent = `${n.toLocaleString()} recipes simmering in the pot`;
  } else {
    el.textContent = n ? `${n.toLocaleString()} recipe${n === 1 ? '' : 's'} match your picky palate` : 'Nothing in the pot matches. Loosen a filter!';
  }
  updateStartButton();
}

// ------------------------------------------------------------------ spoons / limits

function renderSpoons() {
  const used = state.user ? state.usedToday : 0;
  $('#spoonRow').innerHTML = Array.from({ length: DAILY_LIMIT }, (_, i) =>
    SPOON_SVG.replace('class="spoon"', `class="spoon${i < used ? ' used' : ''}"`)).join('');
  $('#spoons').setAttribute('aria-label', `${DAILY_LIMIT - used} of ${DAILY_LIMIT} stirs left today`);
  tickClock();
  updateStartButton();
}

function tickClock() {
  const el = $('#spoonsReset');
  if (!state.user) { el.textContent = 'Sign in to get 3 stirs a day'; return; }
  if (state.usedToday === 0) { el.textContent = 'Fresh pot, all stirs ready'; return; }
  const now = new Date();
  const midnight = new Date(now); midnight.setHours(24, 0, 0, 0);
  const mins = Math.ceil((midnight - now) / 60000);
  el.textContent = `Refills in ${Math.floor(mins / 60)}h ${mins % 60}m`;
  if (mins >= 24 * 60 - 1) refreshUserData();
}

function updateStartButton() {
  const btn = $('#startBtn');
  const hint = $('#startHint');
  const { all } = candidates();
  const out = state.user && state.usedToday >= DAILY_LIMIT;
  btn.disabled = state.busy || !all.length || out;
  if (!state.user) hint.textContent = 'You will need to sign in first. It only takes a second.';
  else if (out) hint.textContent = 'That is all 3 stirs for today. Go cook something! The pot refills at midnight.';
  else hint.textContent = state.mode === 'picky' ? 'Filters on. The rating is still a secret.' : 'No peeking at the stars: you rate it first, then the truth comes out.';
}

// ------------------------------------------------------------------ pot animation

const ladle = { angle: 0.7, speed: 0, raf: 0, last: 0 };

function drawLadle(a) {
  const bx = 130 + 50 * Math.cos(a), by = 87 + 10 * Math.sin(a);
  const tx = 130 + 26 * Math.cos(a) + 46, ty = -36 + 6 * Math.sin(a);
  const h = $('#ladleHandle');
  h.setAttribute('x1', bx); h.setAttribute('y1', by);
  h.setAttribute('x2', tx); h.setAttribute('y2', ty);
  const hook = $('#ladleHook');
  hook.setAttribute('cx', tx + 3); hook.setAttribute('cy', ty - 6);
  const rip = $('#ladleRipple');
  rip.setAttribute('cx', bx); rip.setAttribute('cy', by + 1);
}

function ladleLoop(t) {
  const dt = ladle.last ? Math.min(50, t - ladle.last) / 1000 : 0;
  ladle.last = t;
  ladle.angle += dt * ladle.speed;
  drawLadle(ladle.angle);
  ladle.raf = ladle.speed ? requestAnimationFrame(ladleLoop) : 0;
}

function setBoiling(on) {
  $('#potStage').classList.toggle('boiling', on);
  ladle.speed = on && !reduceMotion ? (Math.PI * 2) / 1.6 : 0;   // one turn every 1.6s
  if (ladle.speed && !ladle.raf) { ladle.last = 0; ladle.raf = requestAnimationFrame(ladleLoop); }
}

function setDocked(on, animate = true) {
  const stage = $('#potStage');
  if (stage.classList.contains('docked') === on) return;
  const first = stage.getBoundingClientRect();
  stage.classList.toggle('docked', on);
  document.body.classList.toggle('has-dock', on);
  $('#potBtn').tabIndex = on ? 0 : -1;
  $('#potBtn').setAttribute('aria-label', on ? 'Back to the kitchen' : 'Start cooking');
  if (!animate || reduceMotion) return;
  const last = stage.getBoundingClientRect();
  const dx = first.left - last.left, dy = first.top - last.top, s = first.width / last.width;
  const base = on ? 'translateX(-50%)' : '';
  stage.animate([
    { transformOrigin: '0 0', transform: `translate(${dx}px, ${dy}px) ${base} scale(${s})` },
    { transformOrigin: '0 0', transform: `${base} scale(1)` }
  ], { duration: 700, easing: 'cubic-bezier(.3, .9, .3, 1)' });
}

// ------------------------------------------------------------------ kitchen

function wireKitchen() {
  drawLadle(ladle.angle);
  $('#startBtn').addEventListener('click', startCooking);
  $('#potBtn').addEventListener('click', () => {
    if ($('#potStage').classList.contains('docked')) backToKitchen();
  });
}

function backToKitchen() {
  $('#recipeCard').hidden = true;
  setBoiling(false);
  setDocked(false);
  window.scrollTo({ top: 0, behavior: reduceMotion ? 'auto' : 'smooth' });
}

async function startCooking() {
  if (state.busy) return;
  if (!state.user) { openAuth(state.store.mode === 'local' ? 'signin' : 'signup', 'Sign in to start stirring. You get 3 mystery recipes a day.'); return; }
  if (state.usedToday >= DAILY_LIMIT) { toast('The pot is empty for today. Come back after midnight!'); return; }

  const { fresh } = candidates();
  if (!fresh.length) { toast('No recipes match those filters.'); return; }

  state.busy = true;
  updateStartButton();
  $('#recipeCard').hidden = true;
  setDocked(false, false);
  const potBox = $('#potStage').getBoundingClientRect();
  window.scrollTo({ top: Math.max(0, scrollY + potBox.top - (innerHeight - potBox.height) / 2), behavior: reduceMotion ? 'auto' : 'smooth' });
  setBoiling(true);
  $('#potCount').textContent = 'Stirring the pot…';

  try {
    const [res] = await Promise.all([state.store.draw(fresh), wait(reduceMotion ? 300 : 2000)]);
    state.usedToday = res.usedToday;
    state.draws.unshift({ recipe_id: res.recipeId, created_at: new Date().toISOString() });
    const recipe = await getRecipe(res.recipeId);

    setDocked(true);
    const card = $('#recipeCard');
    card.innerHTML = recipeCardHTML(recipe, { fresh: true });
    card.hidden = false;
    card.classList.remove('pop'); void card.offsetWidth; card.classList.add('pop');
    wireRecipeCard(card, recipe);
    setTimeout(() => card.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' }), 150);
  } catch (e) {
    setBoiling(false);
    if (e.code === 'DAILY_LIMIT') {
      state.usedToday = DAILY_LIMIT;
      toast('That is all 3 stirs for today. The pot refills at midnight.');
    } else if (e.code === 'NOT_SIGNED_IN') {
      openAuth('signin');
    } else {
      console.error(e);
      toast('The pot boiled over. Please try again.');
    }
  } finally {
    state.busy = false;
    renderSpoons();
    renderPotCount();
    updatePendingBadge();
  }
}

// ------------------------------------------------------------------ recipe card

const DURATION_RX = /(\d+(?:[.,]\d+)?)(?:\s*(?:-|–|to)\s*(\d+(?:[.,]\d+)?))?\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b/gi;

function withTimers(escapedText) {
  return escapedText.replace(DURATION_RX, (m, a, b, unit) => {
    const n = parseFloat((b || a).replace(',', '.'));
    const u = unit.toLowerCase();
    const secs = Math.round(u.startsWith('h') ? n * 3600 : u.startsWith('s') ? n : n * 60);
    if (!secs || secs > 86400) return m;
    return `<button type="button" class="timer-chip" data-secs="${secs}" title="Start a ${esc(m)} timer">⏲ ${m}</button>`;
  });
}

function starsHTML(avg) {
  let out = '';
  for (let i = 1; i <= 5; i++) out += `<span class="${avg >= i - 0.25 ? 'on' : 'off'}">★</span>`;
  return out;
}

function recipeCardHTML(r, { fresh = false } = {}) {
  const culture = cultureFor(r);
  const source = safeUrl(r.source?.url);
  const img = safeUrl(r.image);
  const place = [r.cuisine, r.country && r.country !== r.cuisine ? r.country : ''].filter(Boolean).join(' · ');
  const tags = [
    place && `<li class="tag">🌍 ${esc(place)}</li>`,
    `<li class="tag">🍽 ${esc(COURSE_LABEL[r.course] || 'Dish')}</li>`,
    `<li class="tag">⏱ ${r.timeEstimated ? '≈ ' : ''}${esc(formatMinutes(r.minutes))}</li>`,
    `<li class="tag red">🔥 ${esc(DIFF_LABEL[r.difficulty] || r.difficulty)}</li>`,
    DIET_LABEL[r.diet] && `<li class="tag green">🌱 ${DIET_LABEL[r.diet]}</li>`
  ].filter(Boolean).join('');

  const via = r.via && r.via.name !== r.source?.name ? ` · via <a href="${esc(safeUrl(r.via.url))}" target="_blank" rel="noopener">${esc(r.via.name)}</a>` : '';
  const saved = state.saved.has(r.id);

  const ingredients = r.ingredients.map((ing, i) => `
    <li><label><input type="checkbox" data-ing="${i}"><span>${ing.qty ? `<span class="qty">${esc(ing.qty)}</span> ` : ''}${esc(ing.item)}</span></label></li>`).join('');
  const steps = r.steps.map(s => `<li>${withTimers(esc(s))}</li>`).join('');
  const cultureSrc = culture.source
    ? `<p class="src">Source: <a href="${esc(safeUrl(culture.source.url))}" target="_blank" rel="noopener">${esc(culture.source.name)}</a></p>`
    : `<p class="src">About ${esc(culture.label)}</p>`;

  return `
    <div class="card-tape" aria-hidden="true"></div>
    <div class="card-hero ${img ? '' : 'no-image'}">
      ${img ? `<div class="card-image"><img src="${esc(img)}" alt="${esc(r.name)}" loading="lazy" onerror="this.parentElement.remove()"></div>` : ''}
      <div class="card-intro">
        <p class="card-kicker">${fresh ? 'Fresh out of the pot!' : 'From your cookbook'}</p>
        <h2 class="card-title">${esc(r.name)}</h2>
        <p class="card-author">by <strong>${esc(r.author)}</strong>${source ? ` · <a href="${esc(source)}" target="_blank" rel="noopener">original recipe ↗</a>` : ''}${via}</p>
        <ul class="tags">${tags}</ul>
        <div class="rating-slot"></div>
        <div class="card-actions">
          <button type="button" class="btn btn-small btn-ghost save-btn" aria-pressed="${saved}">${saved ? '♥ Saved' : '♡ Save'}</button>
          <button type="button" class="btn btn-small btn-primary cook-btn">👩‍🍳 Cook mode</button>
          <button type="button" class="btn btn-small btn-ghost copy-btn">🛒 Copy shopping list</button>
          <button type="button" class="btn btn-small btn-ghost print-btn">🖨 Print</button>
        </div>
      </div>
    </div>
    <div class="card-body">
      <section class="card-section">
        <h3>🌍 Cultural roots</h3>
        <div class="culture"><p>${esc(culture.text)}</p>${cultureSrc}</div>
      </section>
      <section class="card-section">
        <h3>🧺 Ingredients <span class="muted" style="font-size:15px;font-family:var(--font-body)">(${r.ingredients.length}, tap to check off)</span></h3>
        <ul class="ingredients">${ingredients}</ul>
      </section>
      <section class="card-section">
        <h3>🥄 Method</h3>
        <ol class="steps">${steps}</ol>
        ${r.timeEstimated ? `<p class="muted" style="font-size:14px">⏱ The total time is estimated from the steps above.</p>` : ''}
        ${safeUrl(r.youtube) ? `<p><a href="${esc(r.youtube)}" target="_blank" rel="noopener">▶ Watch a video of this recipe</a></p>` : ''}
      </section>
      <div class="rate-slot"></div>
      <p class="muted" style="font-size:13px;margin-top:22px">Recipe from ${esc(r.source?.name || 'the web')}${r.license === 'CC BY-SA 4.0' ? ', shared under CC BY-SA 4.0' : ''}. Loved it or hated it? ${source ? `<a href="${esc(source)}" target="_blank" rel="noopener">Leave a review on the original page too.</a>` : ''}</p>
    </div>`;
}

function wireRecipeCard(card, r) {
  renderRatingArea(card, r);

  $('.save-btn', card).addEventListener('click', async e => {
    if (!state.user) { openAuth('signin'); return; }
    const btn = e.currentTarget;
    const on = !state.saved.has(r.id);
    btn.disabled = true;
    try {
      await state.store.setSaved(r.id, on);
      on ? state.saved.add(r.id) : state.saved.delete(r.id);
      btn.setAttribute('aria-pressed', String(on));
      btn.textContent = on ? '♥ Saved' : '♡ Save';
      toast(on ? 'Saved to your cookbook' : 'Removed from saved');
    } catch { toast('Could not save. Try again.'); }
    btn.disabled = false;
  });

  $('.cook-btn', card).addEventListener('click', () => openCookMode(r));
  $('.print-btn', card).addEventListener('click', () => window.print());
  $('.copy-btn', card).addEventListener('click', async () => {
    const text = `${r.name}\n\n` + r.ingredients.map(i => `- ${i.qty ? i.qty + ' ' : ''}${i.item}`).join('\n');
    try { await navigator.clipboard.writeText(text); toast('Shopping list copied!'); }
    catch { toast('Could not copy. Your browser blocked it.'); }
  });

  // Remember ingredient checkboxes per recipe.
  const key = `fyr:checked:${r.id}`;
  const checked = new Set(lsGet(key, []));
  $$('[data-ing]', card).forEach(cb => {
    cb.checked = checked.has(Number(cb.dataset.ing));
    cb.addEventListener('change', () => {
      cb.checked ? checked.add(Number(cb.dataset.ing)) : checked.delete(Number(cb.dataset.ing));
      lsSet(key, [...checked]);
    });
  });

  card.addEventListener('click', e => {
    const chip = e.target.closest('.timer-chip');
    if (chip) startTimer(Number(chip.dataset.secs), `${r.name}: ${chip.textContent.replace('⏲', '').trim()}`);
  });
}

async function renderRatingArea(card, r) {
  const ratingSlot = $('.rating-slot', card);
  const rateSlot = $('.rate-slot', card);
  const mine = state.ratings[r.id];

  if (!mine) {
    ratingSlot.innerHTML = `
      <div class="mystery">
        <span class="mystery-stars" aria-label="Rating hidden">? ? ? ? ?</span>
        <p><strong>Rating hidden.</strong> Cook it, rate it, and then you'll see what everyone else thought.</p>
      </div>`;
    rateSlot.innerHTML = rateBoxHTML(r);
    wireRateBox(card, r);
    return;
  }

  ratingSlot.innerHTML = `<div class="mystery"><span class="mystery-stars" style="color:var(--butter)">${'★'.repeat(mine.stars)}</span><p>You gave this <strong>${mine.stars} star${mine.stars === 1 ? '' : 's'}</strong>.</p></div>`;
  rateSlot.innerHTML = `<div class="reveal"><p class="muted">Loading the community rating…</p></div>`;
  try {
    const stats = (await state.store.revealed([r.id]))[r.id];
    rateSlot.innerHTML = revealHTML(r, mine.stars, stats);
  } catch {
    rateSlot.innerHTML = '';
  }
}

function rateBoxHTML(r) {
  const stars = [5, 4, 3, 2, 1].map(n =>
    `<input type="radio" name="stars-${esc(r.id)}" id="s${n}-${esc(r.id)}" value="${n}"><label for="s${n}-${esc(r.id)}" title="${n} star${n > 1 ? 's' : ''}">★</label>`).join('');
  return `
    <form class="rate-box">
      <h3>🍴 Cooked it? Rate it to reveal the real rating</h3>
      <p class="muted" style="margin:0">Be honest! Your stars go into the community rating for this recipe.</p>
      <div class="star-input" role="radiogroup" aria-label="Your rating">${stars}</div>
      <label class="field"><span>Kitchen notes (optional)</span><textarea name="note" maxlength="500" placeholder="Too salty? Perfect crust? Leave yourself a note."></textarea></label>
      <label class="rate-confirm"><input type="checkbox" name="cooked" required> I really cooked (and tasted) this</label>
      <button class="btn btn-primary" type="submit">Reveal the rating</button>
      <p class="form-error" role="alert"></p>
    </form>`;
}

function wireRateBox(card, r) {
  const form = $('.rate-box', card);
  form.addEventListener('submit', async e => {
    e.preventDefault();
    const fd = new FormData(form);
    const stars = Number(fd.get(`stars-${r.id}`));
    const err = $('.form-error', form);
    if (!stars) { err.textContent = 'Pick 1 to 5 stars first.'; return; }
    const btn = $('button[type=submit]', form);
    btn.disabled = true;
    try {
      const stats = await state.store.rate(r.id, stars, fd.get('note'));
      state.ratings[r.id] = { recipe_id: r.id, stars, note: fd.get('note') };
      updatePendingBadge();
      $('.rating-slot', card).innerHTML = `<div class="mystery"><span class="mystery-stars" style="color:var(--butter)">${'★'.repeat(stars)}</span><p>You gave this <strong>${stars} star${stars === 1 ? '' : 's'}</strong>.</p></div>`;
      const slot = $('.rate-slot', card);
      slot.innerHTML = revealHTML(r, stars, stats);
      $('.reveal', slot).classList.add('flip');
      slot.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
    } catch (e2) {
      err.textContent = e2.code === 'NOT_DRAWN' ? 'You can only rate recipes you drew from the pot.' : 'Could not save your rating. Try again.';
      btn.disabled = false;
    }
  });
}

function verdict(avg) {
  if (avg >= 4.5) return ['Jackpot! 🎰', 'You hit a crowd favorite.'];
  if (avg >= 3.5) return ['Solid win 🏆', 'Most cooks were happy with this one.'];
  if (avg >= 2.5) return ['Coin flip 🪙', 'This one splits the room.'];
  if (avg >= 1.5) return ['Brave soul 🫡', 'Most cooks were not fans. You survived!'];
  return ['Kitchen disaster survivor 🧯', 'The crowd says this one is rough.'];
}

function revealHTML(r, mine, stats) {
  const source = safeUrl(r.source?.url);
  const rateSrc = source ? `<a class="btn btn-small btn-ghost" href="${esc(source)}" target="_blank" rel="noopener">Rate it on ${esc(r.source.name)} too ↗</a>` : '';
  if (!stats || stats.count <= 1) {
    return `
      <div class="reveal">
        <p class="reveal-badge">First taster! 🥇</p>
        <div class="reveal-stars" aria-label="${mine} stars">${starsHTML(mine)}</div>
        <p class="reveal-num">You're the first cook to rate this one</p>
        <p class="reveal-compare">Your ${mine}-star rating is its first. Future cooks will be gambling on your verdict.</p>
        ${rateSrc}
      </div>`;
  }
  const [title, line] = verdict(stats.avg);
  const others = stats.avg;
  const diff = Math.round((mine - others) * 10) / 10;
  const cmp = Math.abs(diff) < 0.3 ? 'You agree with the crowd.'
    : diff > 0 ? `You were ${Math.abs(diff)} star${Math.abs(diff) === 1 ? '' : 's'} kinder than the crowd.`
      : `You were ${Math.abs(diff)} star${Math.abs(diff) === 1 ? '' : 's'} tougher than the crowd.`;
  return `
    <div class="reveal">
      <p class="reveal-badge">${esc(title)}</p>
      <div class="reveal-stars" aria-label="${stats.avg} out of 5">${starsHTML(stats.avg)}</div>
      <p class="reveal-num">${stats.avg.toFixed(1)} / 5 from ${stats.count} cooks</p>
      <p class="reveal-compare">${esc(line)} You gave it ${mine}★. ${esc(cmp)}</p>
      ${rateSrc}
    </div>`;
}

// ------------------------------------------------------------------ cookbook

async function renderCookbook() {
  const list = $('#recipeList');
  if (!state.user) {
    $('#cookbookWho').textContent = '';
    $('#stats').innerHTML = '';
    list.innerHTML = `<div class="empty"><span class="big">📖</span>Sign in to see your cookbook.<br><br><button class="btn btn-primary" id="cbSignIn">Sign in</button></div>`;
    $('#cbSignIn').addEventListener('click', () => openAuth('signin'));
    return;
  }
  $('#cookbookWho').textContent = `${state.user.name}'s recipes`;

  const uniqueDrawn = [...new Set(state.draws.map(d => d.recipe_id))];
  const rated = Object.values(state.ratings);
  const avgMine = rated.length ? (rated.reduce((s, r) => s + r.stars, 0) / rated.length).toFixed(1) : '–';
  $('#stats').innerHTML = [
    [uniqueDrawn.length, 'Mystery dishes drawn'],
    [rated.length, 'Cooked & rated'],
    [avgMine, 'Your average rating'],
    [state.saved.size, 'Saved favorites']
  ].map(([n, l]) => `<div class="stat"><div class="stat-num">${n}</div><div class="stat-label">${l}</div></div>`).join('');

  $$('.tab').forEach(t => {
    t.setAttribute('aria-selected', String(t.dataset.tab === state.cookbookTab));
    t.onclick = () => { state.cookbookTab = t.dataset.tab; renderCookbook(); };
  });

  let ids;
  if (state.cookbookTab === 'pending') ids = pendingIds();
  else if (state.cookbookTab === 'saved') ids = [...state.saved];
  else ids = uniqueDrawn.filter(id => state.ratings[id]);

  if (!ids.length) {
    const msg = {
      pending: ['🍳', 'Nothing waiting to be rated. Go stir the pot!'],
      saved: ['♡', 'No saved recipes yet. Tap “Save” on a recipe you want to make again.'],
      rated: ['⭐', 'You haven\'t rated anything yet. Cook a mystery dish and come back!']
    }[state.cookbookTab];
    list.innerHTML = `<div class="empty"><span class="big">${msg[0]}</span>${msg[1]}</div>`;
    return;
  }

  list.innerHTML = `<p class="empty">Gathering your recipes…</p>`;
  const tab = state.cookbookTab;
  const [recipes, revealed] = await Promise.all([
    Promise.all(ids.map(id => getRecipe(id).catch(() => null))),
    state.store.revealed(ids.filter(id => state.ratings[id])).catch(() => ({}))
  ]);
  if (tab !== state.cookbookTab) return;

  list.innerHTML = recipes.filter(Boolean).map(r => {
    const mine = state.ratings[r.id];
    const crowd = revealed[r.id];
    const stars = mine
      ? `<div class="mini-stars">You <span class="s">${'★'.repeat(mine.stars)}</span>${crowd && crowd.count > 1 ? ` · Crowd <span class="s">★</span> ${crowd.avg.toFixed(1)}` : ''}</div>`
      : `<div class="mini-stars muted">Rating hidden ? ? ?</div>`;
    const img = safeUrl(r.image);
    return `
      <a class="mini" href="#/recipe/${encodeURIComponent(r.id)}">
        <div class="mini-img">${img ? `<img src="${esc(img)}" alt="" loading="lazy" onerror="this.replaceWith('🍲')">` : '🍲'}</div>
        <div class="mini-body">
          <p class="mini-title">${esc(r.name)}</p>
          <p class="mini-meta">${esc(r.cuisine || 'Global')} · ${esc(formatMinutes(r.minutes))}</p>
          ${stars}
        </div>
      </a>`;
  }).join('');
}

async function renderStaticRecipe(id) {
  const card = $('#recipeCardStatic');
  const known = state.draws.some(d => d.recipe_id === id) || state.saved.has(id);
  if (!state.user || !known) {
    card.innerHTML = `<div class="empty" style="padding:40px"><span class="big">🔒</span>This recipe isn't in your cookbook. Recipes only show up after you draw them from the pot.</div>`;
    return;
  }
  card.innerHTML = `<p class="empty">Opening the recipe…</p>`;
  try {
    const r = await getRecipe(id);
    card.innerHTML = recipeCardHTML(r);
    wireRecipeCard(card, r);
  } catch {
    card.innerHTML = `<p class="empty">Could not load this recipe.</p>`;
  }
}

// ------------------------------------------------------------------ cook mode

const cook = { recipe: null, i: 0, wake: null };

function wireCookMode() {
  $('#cookClose').addEventListener('click', () => $('#cookMode').close());
  $('#cookPrev').addEventListener('click', () => showCookStep(cook.i - 1));
  $('#cookNext').addEventListener('click', () => {
    if (cook.i >= cook.recipe.steps.length - 1) { $('#cookMode').close(); toast('Done! Don\'t forget to rate it.'); }
    else showCookStep(cook.i + 1);
  });
  $('#cookMode').addEventListener('close', () => { cook.wake?.release?.().catch(() => {}); cook.wake = null; });
  $('#cookMode').addEventListener('keydown', e => {
    if (e.key === 'ArrowRight') $('#cookNext').click();
    if (e.key === 'ArrowLeft') $('#cookPrev').click();
  });
  $('#cookMode').addEventListener('click', e => {
    const chip = e.target.closest('.timer-chip');
    if (chip) startTimer(Number(chip.dataset.secs), `${cook.recipe.name}: ${chip.textContent.replace('⏲', '').trim()}`);
  });
}

async function openCookMode(r) {
  cook.recipe = r;
  $('#cookTitle').textContent = r.name;
  $('#cookMode').showModal();
  showCookStep(0);
  try { cook.wake = await navigator.wakeLock?.request('screen'); } catch { /* not supported */ }
}

function showCookStep(i) {
  const steps = cook.recipe.steps;
  cook.i = Math.max(0, Math.min(i, steps.length - 1));
  $('#cookStepNum').textContent = `Step ${cook.i + 1} of ${steps.length}`;
  $('#cookStep').innerHTML = withTimers(esc(steps[cook.i]));
  $('#cookBar').style.width = `${((cook.i + 1) / steps.length) * 100}%`;
  $('#cookPrev').disabled = cook.i === 0;
  $('#cookNext').textContent = cook.i === steps.length - 1 ? 'Finish 🎉' : 'Next step →';
}

// ------------------------------------------------------------------ timers

let timerTick = 0;

function startTimer(secs, label) {
  state.timers.push({ id: Math.random().toString(36).slice(2), end: Date.now() + secs * 1000, label, done: false });
  toast(`Timer started: ${label.split(': ').pop()}`);
  renderTimers();
  timerTick ||= setInterval(renderTimers, 1000);
}

function beep() {
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    [0, 0.35, 0.7].forEach(t => {
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.frequency.value = 880; o.connect(g); g.connect(ctx.destination);
      g.gain.setValueAtTime(0.25, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + t + 0.3);
      o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.3);
    });
    navigator.vibrate?.([200, 100, 200]);
  } catch { /* no audio */ }
}

function renderTimers() {
  const dock = $('#timerDock');
  const now = Date.now();
  for (const t of state.timers) {
    if (!t.done && now >= t.end) { t.done = true; beep(); toast(`⏰ Time's up: ${t.label.split(': ').pop()}`, 6000); }
  }
  dock.innerHTML = state.timers.map(t => {
    const left = Math.max(0, Math.round((t.end - now) / 1000));
    const h = Math.floor(left / 3600), m = Math.floor((left % 3600) / 60), s = left % 60;
    const time = t.done ? 'Done!' : `${h ? h + ':' : ''}${String(m).padStart(h ? 2 : 1, '0')}:${String(s).padStart(2, '0')}`;
    return `<div class="timer ${t.done ? 'done' : ''}"><span class="timer-time">${time}</span><span class="timer-label">${esc(t.label)}</span><button type="button" data-stop="${t.id}" aria-label="Dismiss timer">×</button></div>`;
  }).join('');
  if (!state.timers.length) { clearInterval(timerTick); timerTick = 0; }
}

$('#timerDock').addEventListener('click', e => {
  const b = e.target.closest('[data-stop]');
  if (!b) return;
  state.timers = state.timers.filter(t => t.id !== b.dataset.stop);
  renderTimers();
});

boot();
