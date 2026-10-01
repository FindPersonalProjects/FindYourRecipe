# 🍲 Find Your Recipe

Bored and hungry? Stir the pot and get a **random recipe from around the world**. It might be a 5-star feast or a 1-star flop, and you won't know which until you've **cooked it and rated it yourself**. Only then is the real rating revealed.

## How it works

- **Start cooking**: the pot boils, the ladle stirs, the pot drops to the bottom of the screen and a mystery recipe pops up.
- **3 stirs per day** per account, so nobody can reroll until they find something safe.
- **Full gamble** mode uses every recipe. **Picky eater** mode filters by region, culture, total time, hands-on time, meal, diet (pescatarian / vegetarian / vegan), lifestyle (halal-friendly, kosher-style, low-carb, keto, paleo, Whole30, no added sugar), allergies (gluten, dairy, eggs, peanuts, tree nuts, fish, shellfish, soy, sesame, mustard, celery, sulfites), other things to avoid (pork, red meat, alcohol, spicy heat, nightshades, onion & garlic, mushrooms, coconut, corn), recipe age (modern or vintage), difficulty and main ingredient. Diet and allergen tags are worked out from ingredient names, so they are approximations, not certifications.
- **Timing** is split into prep, cook and hands-off time (marinating, chilling, rising...), estimated from each step when the source doesn't give a time.
- **US / Metric toggle** converts grams, ml, cups, ounces and oven temperatures (common baking ingredients go to cups and spoons by weight), plus a ½× to 3× batch scaler.
- Every recipe shows the **name, author, full ingredient list and method**, a **cultural-significance note**, and a **link to the original source** so you can review it there too.
- **Hidden rating**: stars stay a mystery until you rate the dish. Then you see the community rating, how you compare, and a verdict (Jackpot! / Brave soul / ...).
- **My Cookbook**: dishes waiting to be rated, saved favorites, and your cooked-and-rated history with stats.
- Extras: ingredient checklist, **cook mode** (one step at a time, keeps the screen awake), tap-to-start **kitchen timers** on any time in the steps, copy shopping list, print.

## Where the recipes come from

`scripts/build-recipes.ps1` harvests recipes from open sources and writes `data/index.json` and `data/r/<id>.json`:

| Source | What it gives | License |
|---|---|---|
| [TheMealDB](https://www.themealdb.com/) | ~790 recipes with cuisine, photos and the original source link | Free API |
| [Wikibooks Cookbook](https://en.wikibooks.org/wiki/Cookbook) | ~2,500 recipes from around the world | CC BY-SA 4.0 |
| [based.cooking](https://github.com/LukeSmithxyz/based.cooking) / [Public Domain Recipes](https://github.com/ronaldl29/public-domain-recipes) | ~390 community recipes | Public domain (Unlicense) |
| [Wickham family recipes](https://github.com/hadley/recipes) | ~90 family recipes (ones copied from books or websites are skipped) | CC BY 4.0 |
| [Project Gutenberg](https://www.gutenberg.org/) | ~950 vintage recipes from *The Boston Cooking-School Cook Book* (1896) and *Mrs Beeton's Book of Household Management* (1861) | Public domain |
| [Wikipedia](https://en.wikipedia.org/) | Cultural-significance summaries for dishes | CC BY-SA 4.0 |

The harvester also cleans the text: it fixes common misspellings, missing spaces after periods, "1 chopped Garlic Clove" style ingredient order, heading-only steps, and drops recipes that only say "make same as the recipe above".

Sites whose terms forbid scraping (Allrecipes, Yelp, Fandom, ...) are **not** crawled. Star ratings are not copied from anywhere: the hidden rating is the average from FindYourRecipe cooks, and it fills in as people cook and rate.

TheMealDB asks public apps to [support the project](https://www.themealdb.com/api.php) if they use it in production.

To refresh or grow the recipe collection (Windows PowerShell, from the repo root):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-recipes.ps1
# options: -WikibooksMax 1500   -SkipWikibooks   -SkipWikipedia
```

## Turning on real accounts (Supabase)

Without keys the site runs in **demo mode**: accounts, saves and ratings live in the visitor's browser. To get real accounts that work on any device, with the 3-per-day limit enforced on the server:

1. Create a free project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste in all of [`supabase/schema.sql`](supabase/schema.sql) and click **Run**.
3. Under **Authentication → URL Configuration**, set the **Site URL** to your GitHub Pages address (e.g. `https://findpersonalprojects.github.io/FindYourRecipe/`).
4. Under **Project Settings → API**, copy the **Project URL** and the **anon public** key into [`js/config.js`](js/config.js). The anon key is meant to be public; row-level security protects the data.
5. Commit and push.

## Run it locally

```powershell
powershell -ExecutionPolicy Bypass -File scripts\serve.ps1
```

Then open http://localhost:8080.

## Deploying

Pushing to `main` deploys to GitHub Pages through `.github/workflows/jekyll-gh-pages.yml`. In the repo's **Settings → Pages**, set **Source** to **GitHub Actions**.

## Reading feedback

The **Feedback** page (and the "Report a problem with this recipe" link on every card) saves messages to the `feedback` table once Supabase is connected: open your Supabase project → **Table Editor** → `feedback`. Visitors can send feedback but can't read anyone else's.

Until Supabase is connected, the form offers visitors a pre-filled GitHub issue on this repo instead (their email is left out because issues are public).
