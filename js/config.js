// Paste your Supabase project's URL and anon (public) key here to turn on real accounts.
// Supabase dashboard -> Project Settings -> API. The anon key is safe to publish:
// row level security in supabase/schema.sql protects the data.
// Leave them empty to run in local demo mode (data stays in the browser).
export const SUPABASE_URL = '';
export const SUPABASE_ANON_KEY = '';

export const DAILY_LIMIT = 3;

// Spam protection for sign-up/sign-in: a free Cloudflare Turnstile site key (dash.cloudflare.com -> Turnstile).
// Also turn on "Captcha protection" in Supabase -> Authentication -> Attack Protection with the matching secret key.
export const TURNSTILE_SITE_KEY = '';

// Privacy-friendly visitor counts with GoatCounter (goatcounter.com). Put your code here, e.g. 'findyourrecipe'
// for https://findyourrecipe.goatcounter.com. Leave empty for no analytics.
export const GOATCOUNTER_CODE = '';

// The site's public address. Change this when you move to your own domain.
export const SITE_URL = 'https://findpersonalprojects.github.io/FindYourRecipe/';

// Until Supabase is connected, feedback can't be stored; the form offers a pre-filled GitHub issue here instead.
export const FEEDBACK_ISSUES_URL = 'https://github.com/FindPersonalProjects/FindYourRecipe/issues/new';
