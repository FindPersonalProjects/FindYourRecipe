// Illustrated stand-ins for recipes that have no photo, one per meal type.

const SCENES = {
  breakfast: { bg: '#FCE7B6', bg2: '#F6D38A', label: 'Breakfast', art: `
    <ellipse cx="160" cy="150" rx="92" ry="18" fill="#fff" opacity=".9"/>
    <ellipse cx="160" cy="138" rx="70" ry="14" fill="#D99A4E"/><rect x="90" y="124" width="140" height="14" fill="#E8AE62"/>
    <ellipse cx="160" cy="124" rx="70" ry="14" fill="#EDB86E"/>
    <ellipse cx="160" cy="112" rx="66" ry="13" fill="#D99A4E"/><rect x="94" y="99" width="132" height="13" fill="#E8AE62"/>
    <ellipse cx="160" cy="99" rx="66" ry="13" fill="#F2C47F"/>
    <path d="M128 96 q14 -8 30 -2 q12 4 6 14 q-10 10 -30 6 q-14 -6 -6 -18z" fill="#C8442F" opacity=".85"/>
    <rect x="150" y="84" width="22" height="14" rx="3" fill="#FFF3C4"/>` },
  main: { bg: '#F6D9D0', bg2: '#EDB9A9', label: 'Main dish', art: `
    <ellipse cx="160" cy="132" rx="96" ry="30" fill="#fff"/><ellipse cx="160" cy="128" rx="70" ry="20" fill="#F3EEE4"/>
    <path d="M118 126 q20 -26 50 -16 q24 8 22 22 q-24 12 -56 6 q-22 -4 -16 -12z" fill="#A65A33"/>
    <circle cx="186" cy="122" r="9" fill="#4F7A3A"/><circle cx="198" cy="128" r="7" fill="#6E9E57"/>
    <path d="M58 92 v62 M52 92 v18 q6 8 12 0 v-18" stroke="#9AA3A8" stroke-width="5" fill="none" stroke-linecap="round"/>
    <path d="M262 92 q12 18 0 34 v28" stroke="#9AA3A8" stroke-width="5" fill="none" stroke-linecap="round"/>` },
  soup: { bg: '#E2EDD7', bg2: '#C6DAB5', label: 'Soup & stew', art: `
    <path d="M86 108 h148 q-6 56 -74 58 q-68 -2 -74 -58z" fill="#C8442F"/>
    <ellipse cx="160" cy="108" rx="74" ry="14" fill="#F6A53B"/>
    <circle cx="136" cy="106" r="5" fill="#FBD38A"/><circle cx="172" cy="110" r="4" fill="#FBD38A"/><circle cx="190" cy="104" r="3" fill="#4F7A3A"/>
    <path d="M128 84 q-8 -12 0 -24 q8 -12 0 -24 M160 82 q-8 -12 0 -24 q8 -12 0 -24 M192 84 q-8 -12 0 -24 q8 -12 0 -24"
      stroke="#fff" stroke-width="6" fill="none" stroke-linecap="round" opacity=".85"/>` },
  side: { bg: '#E6F0DA', bg2: '#CFE2BC', label: 'Side or snack', art: `
    <path d="M90 112 h140 q-8 46 -70 48 q-62 -2 -70 -48z" fill="#F3EEE4"/>
    <circle cx="124" cy="104" r="16" fill="#6E9E57"/><circle cx="150" cy="96" r="18" fill="#4F7A3A"/><circle cx="178" cy="100" r="17" fill="#6E9E57"/>
    <circle cx="200" cy="106" r="13" fill="#4F7A3A"/><circle cx="140" cy="108" r="7" fill="#C8442F"/><circle cx="186" cy="110" r="6" fill="#C8442F"/>
    <circle cx="164" cy="104" r="5" fill="#F2C14E"/>` },
  dessert: { bg: '#F9DCE4', bg2: '#F1BCCB', label: 'Dessert', art: `
    <ellipse cx="160" cy="156" rx="86" ry="14" fill="#fff" opacity=".9"/>
    <path d="M104 150 v-46 l112 -24 v70z" fill="#F2D7A6"/><path d="M104 104 l112 -24 v16 l-112 24z" fill="#fff"/>
    <path d="M104 130 l112 -24 v10 l-112 24z" fill="#C8442F" opacity=".8"/>
    <circle cx="190" cy="74" r="11" fill="#C8442F"/><path d="M190 64 q4 -10 12 -12" stroke="#4F7A3A" stroke-width="3" fill="none"/>` }
};

let uid = 0;
const prefix = Math.random().toString(36).slice(2, 7);

export function placeholderSVG(course, { label = true } = {}) {
  const s = SCENES[course] || SCENES.main;
  const gid = `pg-${prefix}-${++uid}`;   // unique per copy: a gradient inside a hidden copy would not paint
  return `<svg class="placeholder-art" viewBox="0 0 320 200" preserveAspectRatio="xMidYMid slice" role="img" aria-label="${s.label} illustration">
    <defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${s.bg}"/><stop offset="1" stop-color="${s.bg2}"/></linearGradient></defs>
    <rect width="320" height="200" fill="url(#${gid})"/>
    <g opacity=".18" fill="#fff">${Array.from({ length: 12 }, (_, i) => `<circle cx="${(i * 53) % 320}" cy="${(i * 37) % 200}" r="${6 + (i % 3) * 4}"/>`).join('')}</g>
    ${s.art}
    ${label ? `<text x="160" y="190" text-anchor="middle" font-family="Caveat, cursive" font-size="18" fill="#4A3226" opacity=".7">no photo, just vibes</text>` : ''}
  </svg>`;
}
