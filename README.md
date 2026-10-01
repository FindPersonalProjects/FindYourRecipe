# 🍲 Find Your Recipe

Bored and hungry? Stir the pot and get a **random recipe from around the world**. It might be a 5-star feast or a 1-star flop, and you won't know which until you've **cooked it and rated it yourself**. Only then is the real rating revealed.

## How it works

- **Start cooking**: the pot boils, the ladle stirs, the pot drops to the bottom of the screen and a mystery recipe pops up.
- **3 stirs per day** per account, so nobody can reroll until they find something safe.
- **Full gamble** mode uses every recipe. **Picky eater** mode filters by region, culture, time until it's on the table, meal, diet, difficulty and main ingredient.
- Every recipe shows the **name, author, full ingredient list and method**, a **cultural-significance note**, and a **link to the original source** so you can review it there too.
- **Hidden rating**: stars stay a mystery until you rate the dish. Then you see the community rating, how you compare, and a verdict (Jackpot! / Brave soul / ...).
- **My Cookbook**: dishes waiting to be rated, saved favorites, and your cooked-and-rated history with stats.
- Extras: ingredient checklist, **cook mode** (one step at a time, keeps the screen awake), tap-to-start **kitchen timers** on any time in the steps, copy shopping list, print.

## Where the recipes come from

`scripts/build-recipes.ps1` harvests recipes from open sources and writes `data/index.json` and `data/r/<id>.json`:

| Source | What it gives | License |
|---|---|---|
| [TheMealDB](https://www.themealdb.com/) | ~790 recipes with cuisine, ingredients, method, photos and the original source link | Free API |
| [Wikibooks Cookbook](https://en.wikibooks.org/wiki/Cookbook) | Hundreds more recipes tagged by country | CC BY-SA 4.0 |
| [Wikipedia](https://en.wikipedia.org/) | Cultural-significance summaries for dishes | CC BY-SA 4.0 |

Sites whose terms forbid scraping (Allrecipes, Yelp, ...) are **not** crawled. Star ratings are not copied from anywhere: the hidden rating is the average from FindYourRecipe cooks, and it fills in as people cook and rate.

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
