// Accounts, daily draws, saves and ratings.
// SupabaseStore is used when keys are configured; LocalStore is a demo fallback.

import { SUPABASE_URL, SUPABASE_ANON_KEY, DAILY_LIMIT } from './config.js';

const tz = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

function localDay(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export class StoreError extends Error {
  constructor(code, message) { super(message || code); this.code = code; }
}

function friendly(err) {
  const msg = (err && (err.message || err.error_description)) || String(err);
  for (const code of ['DAILY_LIMIT', 'NOT_SIGNED_IN', 'NO_CANDIDATES', 'NOT_DRAWN', 'BAD_STARS']) {
    if (msg.includes(code)) return new StoreError(code);
  }
  return new StoreError('ERROR', msg);
}

// ------------------------------------------------------------------ Supabase

class SupabaseStore {
  mode = 'supabase';

  async init() {
    const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
    this.sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data } = await this.sb.auth.getSession();
    this.session = data.session;
    this.profile = null;
    if (this.session) await this.#loadProfile();
  }

  onAuthChange(cb) {
    this.sb.auth.onAuthStateChange(async (_event, session) => {
      this.session = session;
      this.profile = null;
      if (session) await this.#loadProfile();
      cb(this.user());
    });
  }

  async #loadProfile() {
    const uid = this.session.user.id;
    const { data } = await this.sb.from('profiles').select('display_name').eq('user_id', uid).maybeSingle();
    if (data) { this.profile = data; return; }
    const name = this.session.user.user_metadata?.display_name || this.session.user.email.split('@')[0];
    await this.sb.from('profiles').upsert({ user_id: uid, display_name: name });
    this.profile = { display_name: name };
  }

  user() {
    if (!this.session) return null;
    return { id: this.session.user.id, email: this.session.user.email, name: this.profile?.display_name || 'Home Cook' };
  }

  async signUp({ email, password, name }) {
    const { data, error } = await this.sb.auth.signUp({
      email, password,
      options: { data: { display_name: name }, emailRedirectTo: location.origin + location.pathname }
    });
    if (error) throw friendly(error);
    return { needsConfirm: !data.session };
  }

  async signIn({ email, password }) {
    const { error } = await this.sb.auth.signInWithPassword({ email, password });
    if (error) throw friendly(error);
  }

  async resetPassword(email) {
    const { error } = await this.sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    if (error) throw friendly(error);
  }

  async signOut() { await this.sb.auth.signOut(); }

  async usedToday() {
    const { data, error } = await this.sb.rpc('draw_status', { tz: tz() });
    if (error) throw friendly(error);
    return data || 0;
  }

  async draw(candidates) {
    const { data, error } = await this.sb.rpc('draw_recipe', { candidates, tz: tz() });
    if (error) throw friendly(error);
    const row = Array.isArray(data) ? data[0] : data;
    return { recipeId: row.recipe_id, usedToday: row.used_today };
  }

  async joinChallenge(recipeId, week) {
    const { error } = await this.sb.rpc('join_challenge', { p_recipe_id: recipeId, p_week: week });
    if (error) throw friendly(error);
  }

  async challengeCount(week) {
    const { data, error } = await this.sb.rpc('challenge_count', { p_week: week });
    if (error) throw friendly(error);
    return data || 0;
  }

  async history() {
    const [draws, ratings] = await Promise.all([
      this.sb.from('draws').select('recipe_id, created_at, kind, week').order('created_at', { ascending: false }).limit(500),
      this.sb.from('ratings').select('recipe_id, stars, note, created_at')
    ]);
    if (draws.error) throw friendly(draws.error);
    if (ratings.error) throw friendly(ratings.error);
    return { draws: draws.data, ratings: ratings.data };
  }

  async rate(recipeId, stars, note) {
    const { data, error } = await this.sb.rpc('rate_recipe', { p_recipe_id: recipeId, p_stars: stars, p_note: note || null });
    if (error) throw friendly(error);
    const row = Array.isArray(data) ? data[0] : data;
    return { avg: Number(row.avg_stars), count: row.rating_count };
  }

  async revealed(ids) {
    if (!ids.length) return {};
    const { data, error } = await this.sb.rpc('revealed_ratings', { p_recipe_ids: ids });
    if (error) throw friendly(error);
    return Object.fromEntries(data.map(r => [r.recipe_id, { avg: Number(r.avg_stars), count: r.rating_count }]));
  }

  async saved() {
    const { data, error } = await this.sb.from('saved_recipes').select('recipe_id, created_at').order('created_at', { ascending: false });
    if (error) throw friendly(error);
    return data;
  }

  // Dish photos live in a private storage bucket, one per user per recipe.
  #photoPath(recipeId) { return `${this.session.user.id}/${recipeId}.jpg`; }

  async setPhoto(recipeId, blob) {
    const { error } = await this.sb.storage.from('dish-photos')
      .upload(this.#photoPath(recipeId), blob, { upsert: true, contentType: 'image/jpeg' });
    if (error) throw friendly(error);
  }

  async removePhoto(recipeId) {
    const { error } = await this.sb.storage.from('dish-photos').remove([this.#photoPath(recipeId)]);
    if (error) throw friendly(error);
  }

  async photos() {
    const uid = this.session.user.id;
    const { data, error } = await this.sb.storage.from('dish-photos').list(uid, { limit: 1000 });
    if (error || !data?.length) return {};
    const paths = data.map(f => `${uid}/${f.name}`);
    const { data: signed } = await this.sb.storage.from('dish-photos').createSignedUrls(paths, 3600);
    const out = {};
    for (const s of signed || []) if (s.signedUrl) out[s.path.split('/')[1].replace(/\.jpg$/, '')] = `${s.signedUrl}`;
    return out;
  }

  async sendFeedback(fb) {
    const { error } = await this.sb.from('feedback').insert(fb);
    if (error) throw friendly(error);
    return { delivered: true };
  }

  async setSaved(recipeId, on) {
    const q = on
      ? this.sb.from('saved_recipes').upsert({ recipe_id: recipeId })
      : this.sb.from('saved_recipes').delete().eq('recipe_id', recipeId);
    const { error } = await q;
    if (error) throw friendly(error);
  }
}

// ------------------------------------------------------------------ Local demo

const LS_KEY = 'fyr:local:v1';

function readLS() {
  try { return JSON.parse(localStorage.getItem(LS_KEY)) || { current: null, users: {} }; }
  catch { return { current: null, users: {} }; }
}
function writeLS(state) {
  try { localStorage.setItem(LS_KEY, JSON.stringify(state)); } catch { /* storage unavailable */ }
}

class LocalStore {
  mode = 'local';
  #cbs = [];

  async init() { this.state = readLS(); }

  onAuthChange(cb) { this.#cbs.push(cb); }
  #emit() { writeLS(this.state); for (const cb of this.#cbs) cb(this.user()); }

  #me() {
    const u = this.state.users[this.state.current];
    if (!u) throw new StoreError('NOT_SIGNED_IN');
    return u;
  }

  user() {
    const u = this.state.users[this.state.current];
    return u ? { id: this.state.current, email: '', name: u.name } : null;
  }

  async signIn({ name }) {
    const key = name.trim().toLowerCase();
    if (!key) throw new StoreError('ERROR', 'Pick a cook name.');
    this.state.users[key] ||= { name: name.trim(), draws: [], ratings: {}, saved: [] };
    this.state.current = key;
    this.#emit();
  }
  async signUp(args) { await this.signIn(args); return { needsConfirm: false }; }
  async resetPassword() {}
  async signOut() { this.state.current = null; this.#emit(); }

  async usedToday() {
    const today = localDay();
    return this.#me().draws.filter(d => d.day === today && d.kind !== 'challenge').length;
  }

  // The weekly challenge doesn't use one of the 3 daily stirs.
  async joinChallenge(recipeId, week) {
    const me = this.#me();
    if (me.draws.some(d => d.kind === 'challenge' && d.week === week)) return;
    me.draws.unshift({ recipe_id: recipeId, day: localDay(), kind: 'challenge', week, created_at: new Date().toISOString() });
    writeLS(this.state);
  }

  async challengeCount(week) {
    return Object.values(this.state.users).filter(u => u.draws.some(d => d.kind === 'challenge' && d.week === week)).length;
  }

  async draw(candidates) {
    const me = this.#me();
    const used = await this.usedToday();
    if (used >= DAILY_LIMIT) throw new StoreError('DAILY_LIMIT');
    if (!candidates.length) throw new StoreError('NO_CANDIDATES');
    const recipeId = candidates[Math.floor(Math.random() * candidates.length)];
    me.draws.unshift({ recipe_id: recipeId, day: localDay(), created_at: new Date().toISOString() });
    writeLS(this.state);
    return { recipeId, usedToday: used + 1 };
  }

  async history() {
    const me = this.#me();
    return {
      draws: me.draws,
      ratings: Object.entries(me.ratings).map(([recipe_id, r]) => ({ recipe_id, ...r }))
    };
  }

  async rate(recipeId, stars, note) {
    const me = this.#me();
    if (!me.draws.some(d => d.recipe_id === recipeId)) throw new StoreError('NOT_DRAWN');
    me.ratings[recipeId] = { stars, note: note || '', created_at: new Date().toISOString() };
    writeLS(this.state);
    return this.#stats(recipeId);
  }

  // In demo mode the only "community" is the cooks who used this browser.
  #stats(recipeId) {
    const all = Object.values(this.state.users).map(u => u.ratings[recipeId]).filter(Boolean);
    const avg = all.reduce((s, r) => s + r.stars, 0) / all.length;
    return { avg: Math.round(avg * 100) / 100, count: all.length };
  }

  async revealed(ids) {
    const me = this.#me();
    return Object.fromEntries(ids.filter(id => me.ratings[id]).map(id => [id, this.#stats(id)]));
  }

  async saved() { return this.#me().saved.map(s => ({ ...s })); }

  // Demo mode keeps small, compressed photos in browser storage.
  #photoKey(recipeId) { return `fyr:photo:${this.state.current}:${recipeId}`; }

  async setPhoto(recipeId, blob) {
    const dataUrl = await new Promise((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(fr.result);
      fr.onerror = reject;
      fr.readAsDataURL(blob);
    });
    try { localStorage.setItem(this.#photoKey(recipeId), dataUrl); }
    catch { throw new StoreError('ERROR', 'Your browser is out of space for photos. Remove an older photo and try again.'); }
  }

  async removePhoto(recipeId) {
    try { localStorage.removeItem(this.#photoKey(recipeId)); } catch { /* ignore */ }
  }

  async photos() {
    const out = {};
    try {
      const prefix = `fyr:photo:${this.state.current}:`;
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k.startsWith(prefix)) out[k.slice(prefix.length)] = localStorage.getItem(k);
      }
    } catch { /* ignore */ }
    return out;
  }

  // Demo mode has no server to receive feedback; the page offers a GitHub issue instead.
  async sendFeedback() { return { delivered: false }; }

  async setSaved(recipeId, on) {
    const me = this.#me();
    me.saved = me.saved.filter(s => s.recipe_id !== recipeId);
    if (on) me.saved.unshift({ recipe_id: recipeId, created_at: new Date().toISOString() });
    writeLS(this.state);
  }
}

export async function createStore() {
  if (SUPABASE_URL && SUPABASE_ANON_KEY) {
    try {
      const s = new SupabaseStore();
      await s.init();
      return s;
    } catch (e) {
      console.error('Supabase unavailable, falling back to local demo mode', e);
    }
  }
  const s = new LocalStore();
  await s.init();
  return s;
}
