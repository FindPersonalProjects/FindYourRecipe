// Builds a square "my gamble" image on a canvas and shares or downloads it.

const SITE_URL = () => location.origin + location.pathname;

function wrap(ctx, text, maxWidth) {
  const words = text.split(/\s+/);
  const lines = [];
  let line = '';
  for (const w of words) {
    const test = line ? `${line} ${w}` : w;
    if (ctx.measureText(test).width > maxWidth && line) { lines.push(line); line = w; } else line = test;
  }
  if (line) lines.push(line);
  return lines;
}

function stars(ctx, x, y, size, value) {
  for (let i = 0; i < 5; i++) {
    const fill = Math.max(0, Math.min(1, value - i));
    ctx.fillStyle = '#E3D3B3';
    ctx.fillText('★', x + i * size * 1.05, y);
    if (fill > 0) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(x + i * size * 1.05, y - size, size * fill, size * 1.3);
      ctx.clip();
      ctx.fillStyle = '#F2C14E';
      ctx.fillText('★', x + i * size * 1.05, y);
      ctx.restore();
    }
  }
}

export async function makeShareImage(recipe, { mine = null, crowd = null, verdict = '' } = {}) {
  await Promise.all(['800 64px Fraunces', '700 36px Nunito', '600 48px Caveat'].map(f => document.fonts?.load(f).catch(() => {})));
  const S = 1080;
  const c = document.createElement('canvas');
  c.width = c.height = S;
  const ctx = c.getContext('2d');

  // background + gingham strip
  ctx.fillStyle = '#FBF3E4'; ctx.fillRect(0, 0, S, S);
  for (let x = 0; x < S; x += 40) for (let y = 0; y < 40; y += 20) {
    ctx.fillStyle = ((x / 40 + y / 20) % 2) ? 'rgba(200,68,47,.55)' : 'rgba(200,68,47,.25)';
    ctx.fillRect(x, y, 40, 20);
  }
  ctx.fillStyle = '#FFFDF7';
  ctx.beginPath(); ctx.roundRect(70, 110, S - 140, S - 230, 40); ctx.fill();

  ctx.textAlign = 'center';
  ctx.fillStyle = '#C8442F'; ctx.font = '600 52px Caveat, cursive';
  ctx.fillText(mine ? 'I gambled on…' : "I'm gambling on…", S / 2, 210);

  ctx.fillStyle = '#4A3226'; ctx.font = '800 72px Fraunces, Georgia, serif';
  const lines = wrap(ctx, recipe.name, S - 260).slice(0, 3);
  let y = 310;
  for (const l of lines) { ctx.fillText(l, S / 2, y); y += 84; }

  ctx.fillStyle = '#7A6553'; ctx.font = '700 34px Nunito, sans-serif';
  const meta = [recipe.cuisine, recipe.vintage?.year ? `from ${recipe.vintage.year}` : ''].filter(Boolean).join(' · ');
  if (meta) { ctx.fillText(meta, S / 2, y + 6); y += 60; }

  y += 40;
  ctx.font = '86px serif';
  if (mine) {
    ctx.fillStyle = '#4A3226'; ctx.font = '700 34px Nunito, sans-serif';
    ctx.fillText('My rating', S / 2, y); y += 96;
    ctx.font = '86px serif'; ctx.textAlign = 'left'; stars(ctx, S / 2 - 240, y, 92, mine); ctx.textAlign = 'center';
    y += 70;
    if (crowd && crowd.count > 1) {
      ctx.fillStyle = '#4A3226'; ctx.font = '700 34px Nunito, sans-serif';
      ctx.fillText(`Everyone else: ${crowd.avg.toFixed(1)} ★ from ${crowd.count} cooks`, S / 2, y); y += 70;
    }
    if (verdict) { ctx.fillStyle = '#C8442F'; ctx.font = '600 60px Caveat, cursive'; ctx.fillText(verdict, S / 2, y + 10); }
  } else {
    ctx.fillStyle = '#D7B46A'; ctx.font = '800 96px Fraunces, serif';
    ctx.fillText('? ? ? ? ?', S / 2, y + 40);
    ctx.fillStyle = '#7A6553'; ctx.font = '700 34px Nunito, sans-serif';
    ctx.fillText('1 star or 5? Find out after I cook it.', S / 2, y + 120);
  }

  ctx.fillStyle = '#9E2F1F'; ctx.font = '800 40px Fraunces, serif';
  ctx.fillText('🍲 Find Your Recipe', S / 2, S - 150);
  ctx.fillStyle = '#7A6553'; ctx.font = '700 28px Nunito, sans-serif';
  ctx.fillText(SITE_URL().replace(/^https?:\/\//, '').replace(/\/$/, ''), S / 2, S - 70);

  return new Promise(resolve => c.toBlob(resolve, 'image/png'));
}

export async function shareResult(recipe, result) {
  const blob = await makeShareImage(recipe, result);
  const file = new File([blob], 'my-recipe-gamble.png', { type: 'image/png' });
  const text = result.mine
    ? `I gambled on ${recipe.name} and gave it ${result.mine}★. Spin the pot yourself:`
    : `I'm gambling on ${recipe.name} tonight. 1 star or 5? Spin the pot yourself:`;
  if (navigator.canShare?.({ files: [file] })) {
    try { await navigator.share({ files: [file], text, url: SITE_URL() }); return 'shared'; }
    catch (e) { if (e.name === 'AbortError') return 'cancelled'; }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = file.name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  try { await navigator.clipboard.writeText(`${text} ${SITE_URL()}`); } catch { /* ignore */ }
  return 'downloaded';
}
