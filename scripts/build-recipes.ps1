<#
  FindYourRecipe recipe harvester.

  Pulls recipes from open sources, normalizes them, and writes:
    data/index.json      - small searchable index used for filtering
    data/r/<id>.json     - one full recipe per file

  Sources (all free to reuse, with attribution):
    - TheMealDB API        https://www.themealdb.com/api.php
    - Wikibooks Cookbook   https://en.wikibooks.org/wiki/Cookbook  (CC BY-SA)
    - Wikipedia summaries  for the cultural-significance blurbs     (CC BY-SA)

  Sites whose terms forbid scraping (Allrecipes, Yelp, ...) are deliberately not crawled.
  Star ratings are NOT harvested: the hidden rating comes from FindYourRecipe cooks.

  Usage (from the repo root):
    powershell -ExecutionPolicy Bypass -File scripts\build-recipes.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-recipes.ps1 -WikibooksMax 300 -SkipWikipedia
#>
param(
  [int]$WikibooksMax = 700,
  [switch]$SkipWikibooks,
  [switch]$SkipWikipedia
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UA      = 'FindYourRecipe/1.0 (https://github.com/FindPersonalProjects/FindYourRecipe)'
$Root    = Split-Path -Parent $PSScriptRoot
$OutDir  = Join-Path $Root 'data'
$RecDir  = Join-Path $OutDir 'r'
$Utf8    = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- http helpers

function Get-Text([string]$Url) {
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri $Url -TimeoutSec 40
      return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
      $code = $null
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -eq 404) { return $null }
      Start-Sleep -Seconds (2 * ($i + 1))
    }
  }
  Write-Warning "Giving up on $Url"
  return $null
}

function Get-Json([string]$Url) {
  $t = Get-Text $Url
  if ($t) { return ($t | ConvertFrom-Json) }
  return $null
}

# ---------------------------------------------------------------- text helpers

function Clean-Text([string]$s) {
  if (-not $s) { return '' }
  $s = [Net.WebUtility]::HtmlDecode($s)
  $s = $s -replace '\s+', ' '
  return $s.Trim()
}

function Round5([double]$m) { return [int]([Math]::Max(5, [Math]::Round($m / 5) * 5)) }

# Sums every duration mentioned in a string ("1 hr 30 min", "2-3 hours", "overnight").
function Parse-Minutes([string]$text) {
  if (-not $text) { return 0 }
  $t = $text.ToLower() -replace '½', '.5' -replace '¼', '.25' -replace '¾', '.75'
  $total = 0.0
  $rx = '(\d+(?:\.\d+)?)\s*(?:(?:-|–|to)\s*(\d+(?:\.\d+)?))?\s*(days?|hours?|hrs?|h\b|minutes?|mins?|m\b)'
  foreach ($m in [regex]::Matches($t, $rx)) {
    $a = [double]$m.Groups[1].Value
    if ($m.Groups[2].Success) { $a = [double]$m.Groups[2].Value }
    $u = $m.Groups[3].Value
    if ($u -like 'd*') { $total += $a * 1440 }
    elseif ($u -like 'h*') { $total += $a * 60 }
    else { $total += $a }
  }
  if ($t -match 'overnight') { $total += 480 }
  return $total
}

# ---------------------------------------------------------------- classification

$MeatWords = @('chicken','beef','pork','lamb','mutton','goat','bacon','ham','sausage','chorizo','prosciutto','pancetta',
  'salami','pepperoni','turkey','duck','veal','venison','fish','salmon','tuna','cod','haddock','anchovy','anchovies','prawn','shrimp',
  'crab','lobster','mussel','clam','oyster','scallop','squid','octopus','gelatin','gelatine','lard','suet','meat','steak',
  'brisket','rib','liver','kidney','oxtail','rabbit','pheasant','quail','goose','pigeon','mackerel','sardine','trout',
  'herring','kipper','monkfish','sea bass','bream','plaice','halibut','tilapia','catfish','carp','eel','caviar','roe',
  'dashi','bonito','worcestershire','chicken stock','beef stock','gravy','frankfurter','hot dog','spam','pastrami',
  'jamon','guanciale','andouille','kielbasa','mortadella','snail','frog','crawfish','crayfish','langoustine','calamari',
  'tilefish','swordfish','snapper','whitebait','pollock','hake','bresaola','biltong','boerewors','merguez','offal','tripe')
$AnimalWords = @('egg','milk','butter','cream','cheese','yogurt','yoghurt','honey','ghee','parmesan','mozzarella','cheddar',
  'feta','ricotta','mascarpone','paneer','buttermilk','condensed','custard','mayonnaise','whey','fraiche','fraîche',
  'gruyere','gruyère','brie','camembert','stilton','gorgonzola','halloumi','pecorino','quark','kefir','lassi','curd')
$PlantSafe = @('eggplant','butternut','peanut butter','almond butter','cocoa butter','nut butter','coconut milk','almond milk',
  'soy milk','soya milk','oat milk','rice milk','coconut cream','vegan','cream of tartar','butter beans','butterhead',
  'buttercup','cashew cream','plant milk','bean curd','fish-free')

function Test-Words([string]$text, [string[]]$words) {
  foreach ($w in $words) { if ($text -match ('\b' + [regex]::Escape($w) + '(s|es)?\b')) { return $true } }
  return $false
}

function Get-Diet([string[]]$items) {
  $t = (($items -join ' | ').ToLower()) -replace "goat'?s? (cheese|milk|curd|yogh?urt)", 'cheese' -replace "sheep'?s? (cheese|milk)", 'cheese' -replace 'beef tomato', 'tomato'
  foreach ($p in $PlantSafe) { $t = $t.Replace($p, ' ') }
  if (Test-Words $t $MeatWords) { return 0 }
  if (Test-Words $t $AnimalWords) { return 1 }
  return 2
}

function Get-Protein([string]$category, [string[]]$items, [int]$diet, [string]$name) {
  $t = (((@($name) + $items) -join ' | ').ToLower()) -replace "goat'?s? (cheese|milk|curd|yogh?urt)", 'cheese' -replace 'beef tomato', 'tomato'
  switch ($category) {
    'Seafood' { return 'seafood' }
    'Chicken' { return 'poultry' }
    'Beef'    { return 'beef' }
    'Pork'    { return 'pork' }
    'Lamb'    { return 'lamb' }
    'Goat'    { return 'lamb' }
    'Pasta'   { if ($diet -gt 0) { return 'pasta' } }
  }
  $groups = [ordered]@{
    seafood = @('fish','salmon','tuna','cod','haddock','prawn','shrimp','crab','lobster','mussel','clam','oyster','scallop','squid','octopus','mackerel','sardine','trout','anchovy','anchovies','calamari','snapper','hake')
    poultry = @('chicken','turkey','duck','goose','quail','pheasant')
    beef    = @('beef','steak','brisket','veal','oxtail')
    pork    = @('pork','bacon','ham','sausage','chorizo','pancetta','prosciutto')
    lamb    = @('lamb','mutton','goat')
  }
  # The dish name, then ingredients in recipe order (main ingredients usually come first).
  # Flavorings like fish sauce or chicken stock only count if nothing else matches.
  $parts = @($t -split ' \| ')
  foreach ($pass in 1, 2) {
    foreach ($part in $parts) {
      if ($pass -eq 1 -and $part -match '\b(stock|broth|sauce|paste|bouillon|cube|powder|dripping|gelatine?)s?\b') { continue }
      foreach ($g in $groups.Keys) { if (Test-Words $part $groups[$g]) { return $g } }
    }
  }
  if ($diet -gt 0) {
    if (Test-Words $t @('pasta','spaghetti','noodle','macaroni','penne','linguine','lasagne','lasagna','fettuccine','tagliatelle','ravioli','gnocchi')) { return 'pasta' }
    return 'veggie'
  }
  return 'other'
}

function Get-Difficulty([int]$ingredients, [int]$steps, [int]$minutes) {
  $score = $ingredients + 1.5 * $steps + [Math]::Min($minutes, 600) / 20
  if ($score -lt 20) { return 'easy' }
  if ($score -lt 34) { return 'medium' }
  return 'hard'
}

# Cuisine name -> region used by the "Culture" filter.
$Regions = @{
  'American'='Americas'; 'Canadian'='Americas'; 'Mexican'='Americas'; 'Jamaican'='Americas'; 'Cuban'='Americas';
  'Brazilian'='Americas'; 'Argentinian'='Americas'; 'Argentine'='Americas'; 'Peruvian'='Americas'; 'Venezulan'='Americas';
  'Venezuelan'='Americas'; 'Colombian'='Americas'; 'Chilean'='Americas'; 'Puerto Rican'='Americas'; 'Trinidadian'='Americas';
  'Haitian'='Americas'; 'Dominican'='Americas'; 'Caribbean'='Americas'; 'Cajun'='Americas'; 'Creole'='Americas';
  'Southern US'='Americas'; 'Native American'='Americas'; 'Salvadoran'='Americas'; 'Guatemalan'='Americas'; 'Ecuadorian'='Americas';
  'Bolivian'='Americas'; 'Uruguayan'='Americas'; 'Latin American'='Americas'; 'Hawaiian'='Americas'; 'Tex-Mex'='Americas';
  'British'='Europe'; 'English'='Europe'; 'Scottish'='Europe'; 'Welsh'='Europe'; 'Irish'='Europe'; 'French'='Europe';
  'Italian'='Europe'; 'Spanish'='Europe'; 'Portuguese'='Europe'; 'Greek'='Europe'; 'Dutch'='Europe'; 'Belgian'='Europe';
  'German'='Europe'; 'Austrian'='Europe'; 'Swiss'='Europe'; 'Polish'='Europe'; 'Russian'='Europe'; 'Ukrainian'='Europe';
  'Croatian'='Europe'; 'Serbian'='Europe'; 'Hungarian'='Europe'; 'Czech'='Europe'; 'Slovak'='Europe'; 'Romanian'='Europe';
  'Bulgarian'='Europe'; 'Norwegian'='Europe'; 'Swedish'='Europe'; 'Danish'='Europe'; 'Finnish'='Europe'; 'Icelandic'='Europe';
  'Slovakian'='Europe'; 'Slovenian'='Europe'; 'Bosnian'='Europe'; 'Albanian'='Europe'; 'Lithuanian'='Europe'; 'Latvian'='Europe';
  'Estonian'='Europe'; 'Belarusian'='Europe'; 'Maltese'='Europe'; 'Cypriot'='Europe'; 'Scandinavian'='Europe'; 'Jewish'='Middle East';
  'Turkish'='Middle East'; 'Lebanese'='Middle East'; 'Syrian'='Middle East'; 'Israeli'='Middle East'; 'Iranian'='Middle East';
  'Persian'='Middle East'; 'Iraqi'='Middle East'; 'Saudi Arabian'='Middle East'; 'Arab'='Middle East'; 'Palestinian'='Middle East';
  'Jordanian'='Middle East'; 'Yemeni'='Middle East'; 'Armenian'='Middle East'; 'Georgian'='Middle East'; 'Azerbaijani'='Middle East';
  'Afghan'='Middle East'; 'Middle Eastern'='Middle East'; 'Egyptian'='Africa'; 'Moroccan'='Africa'; 'Tunisian'='Africa';
  'Algerian'='Africa'; 'Libyan'='Africa'; 'Nigerian'='Africa'; 'Ghanaian'='Africa'; 'Kenyan'='Africa'; 'Ethiopian'='Africa';
  'Eritrean'='Africa'; 'Somali'='Africa'; 'South African'='Africa'; 'Senegalese'='Africa'; 'Cameroonian'='Africa';
  'Ugandan'='Africa'; 'Tanzanian'='Africa'; 'Zimbabwean'='Africa'; 'Congolese'='Africa'; 'Ivorian'='Africa'; 'Sudanese'='Africa';
  'Malagasy'='Africa'; 'Mozambican'='Africa'; 'Zambian'='Africa'; 'Sierra Leonean'='Africa'; 'Liberian'='Africa';
  'West African'='Africa'; 'East African'='Africa'; 'North African'='Africa'; 'African'='Africa';
  'Chinese'='East Asia'; 'Japanese'='East Asia'; 'Korean'='East Asia'; 'Taiwanese'='East Asia'; 'Mongolian'='East Asia';
  'Cantonese'='East Asia'; 'Sichuan'='East Asia'; 'Hong Kong'='East Asia'; 'Tibetan'='East Asia';
  'Thai'='Southeast Asia'; 'Vietnamese'='Southeast Asia'; 'Malaysian'='Southeast Asia'; 'Filipino'='Southeast Asia';
  'Indonesian'='Southeast Asia'; 'Singaporean'='Southeast Asia'; 'Cambodian'='Southeast Asia'; 'Laotian'='Southeast Asia';
  'Burmese'='Southeast Asia'; 'Myanmar'='Southeast Asia'; 'Indian'='South Asia'; 'Pakistani'='South Asia';
  'Bangladeshi'='South Asia'; 'Sri Lankan'='South Asia'; 'Nepalese'='South Asia'; 'Nepali'='South Asia'; 'Bengali'='South Asia';
  'Punjabi'='South Asia'; 'Goan'='South Asia'; 'Australian'='Oceania'; 'New Zealand'='Oceania'; 'Polynesian'='Oceania';
  'Fijian'='Oceania'; 'Samoan'='Oceania'; 'Uzbek'='Central Asia'; 'Kazakh'='Central Asia'; 'Kyrgyz'='Central Asia'; 'Tajik'='Central Asia'
}


# Country name (as TheMealDB reports it) -> cuisine name.
$Demonyms = @{
  'Afghanistan'='Afghan'; 'Albania'='Albanian'; 'Algeria'='Algerian'; 'Andorra'='Andorran'; 'Angola'='Angolan';
  'Antigua and Barbuda'='Antiguan'; 'Argentina'='Argentinian'; 'Armenia'='Armenian'; 'Aruba'='Aruban'; 'Australia'='Australian';
  'Austria'='Austrian'; 'Azerbaijan'='Azerbaijani'; 'Bahamas'='Bahamian'; 'Bangladesh'='Bangladeshi'; 'Barbados'='Barbadian';
  'Belgium'='Belgian'; 'Botswana'='Botswanan'; 'Brazil'='Brazilian'; 'Bulgaria'='Bulgarian'; 'Cambodia'='Cambodian';
  'Canada'='Canadian'; 'Cayman Islands'='Caymanian'; 'Chile'='Chilean'; 'China'='Chinese'; 'Colombia'='Colombian';
  'Costa Rica'='Costa Rican'; 'Croatia'='Croatian'; 'Cuba'='Cuban'; 'Denmark'='Danish'; 'Dominica'='Dominican'; 'Egypt'='Egyptian';
  'Estonia'='Estonian'; 'France'='French'; 'Greece'='Greek'; 'India'='Indian'; 'Ireland'='Irish'; 'Italy'='Italian';
  'Jamaica'='Jamaican'; 'Japan'='Japanese'; 'Kenya'='Kenyan'; 'Laos'='Laotian'; 'Malaysia'='Malaysian'; 'Mexico'='Mexican';
  'Morocco'='Moroccan'; 'Netherlands'='Dutch'; 'Norway'='Norwegian'; 'Philippines'='Filipino'; 'Poland'='Polish';
  'Portugal'='Portuguese'; 'Russia'='Russian'; 'Saudi Arabia'='Saudi Arabian'; 'Slovakia'='Slovak'; 'Spain'='Spanish';
  'Syria'='Syrian'; 'Thailand'='Thai'; 'Tunisia'='Tunisian'; 'Turkey'='Turkish'; 'Ukraine'='Ukrainian';
  'United Kingdom'='British'; 'United States'='American'; 'Uruguay'='Uruguayan'; 'Venezuela'='Venezuelan'; 'Vietnam'='Vietnamese'
}
foreach ($k in @('Andorran')) { $Regions[$k] = 'Europe' }
foreach ($k in @('Angolan','Botswanan')) { $Regions[$k] = 'Africa' }
foreach ($k in @('Antiguan','Aruban','Bahamian','Barbadian','Caymanian','Costa Rican')) { $Regions[$k] = 'Americas' }

function Get-Cuisine([string]$area, [string]$country) {
  if ($country -and $Demonyms.ContainsKey($country)) { return $Demonyms[$country] }
  if ($area -and $Demonyms.ContainsKey($area)) { return $Demonyms[$area] }
  if ($area -and $area -ne 'Unknown') { return $area }
  return ''
}

function Get-Region([string]$cuisine) {
  if ($cuisine -and $Regions.ContainsKey($cuisine)) { return $Regions[$cuisine] }
  return 'Global'
}

# ---------------------------------------------------------------- Wikipedia culture blurbs

$FoodWords = 'dish|food|cuisine|bread|soup|stew|cake|dessert|pastry|sauce|salad|snack|cooked|dumpling|noodle|pie|curry|' +
             'sandwich|pudding|cookie|biscuit|meal|porridge|rice|confection|sweet|delicacy|recipe|fried|baked|flatbread|' +
             'casserole|tart|pancake|sausage|condiment|appetizer|breakfast|kebab|pasta|roast|dip|spread|chowder|broth|biryani|pilaf'
$WikiCache = @{}
$CacheFile = Join-Path $PSScriptRoot '.cache\wikipedia.json'
if (Test-Path $CacheFile) {
  $cached = [IO.File]::ReadAllText($CacheFile, $Utf8) | ConvertFrom-Json
  foreach ($p in $cached.PSObject.Properties) { $WikiCache[$p.Name] = $p.Value }
  Write-Host "Loaded $($WikiCache.Count) cached Wikipedia lookups"
}

function Get-WikiCulture([string]$name) {
  if ($SkipWikipedia -or -not $name) { return $null }
  $key = $name.ToLower()
  if ($WikiCache.ContainsKey($key)) { return $WikiCache[$key] }
  $title = [Uri]::EscapeDataString(($name -replace ' ', '_'))
  $j = Get-Json "https://en.wikipedia.org/api/rest_v1/page/summary/$title"
  $result = $null
  if ($j -and $j.type -eq 'standard' -and $j.extract) {
    $desc = ('' + $j.description + ' ' + $j.extract).ToLower()
    if ($desc -match "\b($FoodWords)") {
      $result = [ordered]@{
        text   = Clean-Text $j.extract
        source = [ordered]@{ name = 'Wikipedia'; url = $j.content_urls.desktop.page }
      }
    }
  }
  $WikiCache[$key] = $result
  return $result
}

# ---------------------------------------------------------------- output

$recipes = New-Object System.Collections.ArrayList

function Add-Recipe($r) { [void]$recipes.Add($r) }

# ================================================================= TheMealDB

Write-Host 'TheMealDB: fetching every meal (a-z)...'
$meals = @{}
foreach ($c in [char[]]'abcdefghijklmnopqrstuvwxyz0123456789') {
  $j = Get-Json "https://www.themealdb.com/api/json/v1/1/search.php?f=$c"
  if ($j -and $j.meals) { foreach ($m in $j.meals) { $meals[$m.idMeal] = $m } }
}
Write-Host "  $($meals.Count) meals"

$n = 0
foreach ($m in $meals.Values) {
  $n++
  if ($n % 50 -eq 0) { Write-Host "  processed $n / $($meals.Count)" }

  $ingredients = @()
  for ($i = 1; $i -le 20; $i++) {
    $item = Clean-Text $m."strIngredient$i"
    $qty  = Clean-Text $m."strMeasure$i"
    if ($item) { $ingredients += ,([ordered]@{ item = $item; qty = $qty }) }
  }
  if ($ingredients.Count -lt 2) { continue }

  # Instructions come as one blob; split into numbered steps.
  $raw = [Net.WebUtility]::HtmlDecode('' + $m.strInstructions) -replace "`r", ''
  $lines = $raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $steps = @()
  foreach ($l in $lines) {
    $l = $l -replace '^(step\s*\d+[:.)]?|\d+[.)]|\d+\s*-|▢|•|-)\s*', ''
    $l = $l.Trim()
    if ($l -match '^(step\s*\d+|\d+)$' -or $l.Length -lt 3) { continue }
    $steps += $l
  }
  if ($steps.Count -eq 1 -and $steps[0].Length -gt 400) {
    # One giant paragraph: break it into ~2-sentence steps.
    $sentences = [regex]::Split($steps[0], '(?<=[.!?])\s+(?=[A-Z])')
    $steps = @(); $buf = ''
    foreach ($s in $sentences) {
      $buf = ($buf + ' ' + $s).Trim()
      if ($buf.Length -gt 160) { $steps += $buf; $buf = '' }
    }
    if ($buf) { $steps += $buf }
  }
  if ($steps.Count -lt 1) { continue }

  $items   = $ingredients | ForEach-Object { $_.item }
  $diet    = Get-Diet $items
  $cat     = '' + $m.strCategory
  $course  = switch ($cat) { 'Breakfast' { 'breakfast' } 'Dessert' { 'dessert' } 'Side' { 'side' } 'Starter' { 'side' } default { 'main' } }
  if ($course -eq 'main' -and $m.strMeal -match '(?i)\b(soup|chowder|broth|bisque|ramen|pho|gazpacho|borscht)\b') { $course = 'soup' }
  if ($cat -eq 'Vegan') { $diet = 2 } elseif ($cat -eq 'Vegetarian' -and $diet -eq 0) { $diet = 1 }
  $country = Clean-Text $m.strCountry
  $cuisine = Get-Cuisine (Clean-Text $m.strArea) $country

  $cook    = Parse-Minutes $raw
  $minutes = Round5 (10 + 2 * $ingredients.Count + $cook)

  $sourceUrl = ('' + $m.strSource).Trim()
  $mealPage  = "https://www.themealdb.com/meal/$($m.idMeal)"
  if ($sourceUrl -match '^https?://') {
    $host_ = ([Uri]$sourceUrl).Host -replace '^www\.', ''
    $author = $host_
    $source = [ordered]@{ name = $host_; url = $sourceUrl }
  } else {
    $author = 'TheMealDB community'
    $source = [ordered]@{ name = 'TheMealDB'; url = $mealPage }
  }

  Add-Recipe ([ordered]@{
    id          = "m$($m.idMeal)"
    name        = Clean-Text $m.strMeal
    author      = $author
    source      = $source
    via         = [ordered]@{ name = 'TheMealDB'; url = $mealPage }
    image       = '' + $m.strMealThumb
    cuisine     = $cuisine
    country     = $country
    region      = Get-Region $cuisine
    course      = $course
    protein     = Get-Protein $cat $items $diet $m.strMeal
    diet        = $diet
    minutes     = $minutes
    timeEstimated = $true
    difficulty  = Get-Difficulty $ingredients.Count $steps.Count $minutes
    ingredients = @($ingredients)
    steps       = @($steps)
    tags        = @((('' + $m.strTags) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    youtube     = '' + $m.strYoutube
    culture     = Get-WikiCulture $m.strMeal
    license     = 'TheMealDB'
  })
}
Write-Host "  kept $($recipes.Count) TheMealDB recipes"

# ================================================================= Wikibooks Cookbook

function Remove-Templates([string]$s) {
  # Strip {{...}} including nested ones.
  $prev = $null
  while ($prev -ne $s) { $prev = $s; $s = [regex]::Replace($s, '\{\{[^{}]*\}\}', '') }
  return $s
}

function Clean-Wiki([string]$s) {
  $s = [regex]::Replace($s, '\{\{\s*frac\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\}\}', '$1 $2/$3', 'IgnoreCase')
  $s = [regex]::Replace($s, '\{\{\s*frac\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\}\}', '$1/$2', 'IgnoreCase')
  $s = [regex]::Replace($s, '\{\{\s*convert\s*\|\s*([\d./-]+)\s*\|\s*([^|}]+)[^}]*\}\}', '$1 $2', 'IgnoreCase')
  $s = [regex]::Replace($s, '\{\{\s*(?:w|wikipedia)\s*\|\s*([^|}]+)(?:\|([^}]+))?\}\}', { param($m) if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[1].Value } }, 'IgnoreCase')
  $s = Remove-Templates $s
  $s = [regex]::Replace($s, '<ref[^>]*/>|<ref[^>]*>.*?</ref>', '', 'IgnoreCase')
  $s = [regex]::Replace($s, '<[^>]+>', '')
  $s = [regex]::Replace($s, '\[\[(?:File|Image):[^\]]*\]\]', '', 'IgnoreCase')
  $s = [regex]::Replace($s, '\[\[https?://\S+\s+([^\]]+)\]\]', '$1')
  $s = [regex]::Replace($s, '\[\[[^\]|]*\|([^\]]+)\]\]', '$1')
  $s = [regex]::Replace($s, '\[\[([^\]]+)\]\]', '$1')
  $s = [regex]::Replace($s, '\[https?://\S+\s+([^\]]+)\]', '$1')
  $s = [regex]::Replace($s, '\[https?://\S+\]', '')
  $s = $s -replace "'{2,}", ''
  $s = $s -replace 'Cookbook:', ''
  return Clean-Text $s
}

function Get-TemplateParam([string]$wikitext, [string]$name) {
  $m = [regex]::Match($wikitext, '\|\s*' + $name + '\s*=\s*([^|\n}]*)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

$SkipCats = 'Beverage|Drink|Cocktail|Sauce|Condiment|Spice mix|Seasoning|Dressing|Marinade|Pickle|Preserve|Jam|' +
            'Infant|Baby food|Pet|Dog|Cat food|Liqueur|Wine|Beer|Tea|Coffee|Smoothie|Ingredient'

if (-not $SkipWikibooks) {
  Write-Host 'Wikibooks Cookbook: listing recipes...'
  $titles = New-Object System.Collections.ArrayList
  $cont = ''
  do {
    $j = Get-Json ("https://en.wikibooks.org/w/api.php?action=query&list=categorymembers&cmtitle=Category:Recipes&cmlimit=500&cmnamespace=102&format=json" + $cont)
    if (-not $j) { break }
    foreach ($p in $j.query.categorymembers) { [void]$titles.Add($p.title) }
    $cont = ''
    if ($j.continue) { $cont = '&cmcontinue=' + [Uri]::EscapeDataString($j.continue.cmcontinue) }
  } while ($cont)
  Write-Host "  $($titles.Count) recipe pages"

  $kept = 0
  for ($b = 0; $b -lt $titles.Count -and $kept -lt $WikibooksMax; $b += 50) {
    $batch = $titles[$b..([Math]::Min($b + 49, $titles.Count - 1))]
    $tq = ($batch | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '|'
    $j = Get-Json "https://en.wikibooks.org/w/api.php?action=query&prop=revisions|categories&rvprop=content&rvslots=main&cllimit=max&clshow=!hidden&format=json&formatversion=2&titles=$tq"
    if (-not $j) { continue }
    Write-Host "  batch $([int]($b / 50) + 1): kept $kept so far"

    foreach ($p in $j.query.pages) {
      if ($kept -ge $WikibooksMax) { break }
      if (-not $p.revisions) { continue }
      $wt = '' + $p.revisions[0].slots.main.content
      if ($wt -match '^\s*#REDIRECT') { continue }
      $cats = @($p.categories | ForEach-Object { $_.title -replace '^Category:', '' })
      if ($cats | Where-Object { $_ -match "($SkipCats)" }) { continue }

      # Cuisine from "<X> cuisine" / "<X> recipes" categories, preferring known, most specific names.
      $cuisine = ''
      $generic = @('African','West African','East African','North African','Caribbean','Latin American','Scandinavian','Middle Eastern')
      foreach ($c in $cats) {
        $mm = [regex]::Match($c, '^(.+?) (cuisine|recipes)$')
        if ($mm.Success -and $Regions.ContainsKey($mm.Groups[1].Value)) {
          $cand = $mm.Groups[1].Value
          if (-not $cuisine -or ($cuisine -in $generic -and $cand -notin $generic)) { $cuisine = $cand }
        }
      }
      if (-not $cuisine) { continue }   # keep only recipes with a known culture

      # Split into sections.
      $sections = @{}; $intro = ''; $current = '__intro'
      foreach ($line in ($wt -split "`n")) {
        $h = [regex]::Match($line, '^\s*==+\s*(.+?)\s*==+\s*$')
        if ($h.Success) { $current = $h.Groups[1].Value.ToLower(); $sections[$current] = ''; continue }
        if ($current -eq '__intro') { $intro += $line + "`n" } else { $sections[$current] += $line + "`n" }
      }
      $ingKey  = $sections.Keys | Where-Object { $_ -match 'ingredient' } | Select-Object -First 1
      $stepKey = $sections.Keys | Where-Object { $_ -match 'procedure|method|direction|instruction|preparation|steps' } | Select-Object -First 1
      if (-not $ingKey -or -not $stepKey) { continue }

      $ingredients = @()
      foreach ($line in ($sections[$ingKey] -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^\*+\s*(.+)$') {
          $txt = Clean-Wiki $Matches[1]
          if ($txt.Length -gt 1) { $ingredients += ,([ordered]@{ item = $txt; qty = '' }) }
        } elseif ($line -match '^\|(?![-}])' -and $line -notmatch '^\|\s*$') {
          $cells = ($line.TrimStart('|') -split '\|\|') | ForEach-Object { Clean-Wiki $_ }
          $cells = @($cells | Where-Object { $_ -and $_ -notmatch '^[-–—]$' })
          if ($cells.Count -ge 1) {
            $qty = ''
            if ($cells.Count -gt 1) { $qty = ($cells[1..($cells.Count - 1)] -join ' / ') }
            $ingredients += ,([ordered]@{ item = $cells[0]; qty = $qty })
          }
        }
      }
      $steps = @()
      foreach ($line in ($sections[$stepKey] -split "`n")) {
        if ($line.Trim() -match '^[#*]+\s*(.+)$') {
          $txt = Clean-Wiki $Matches[1]
          if ($txt.Length -gt 3) { $steps += $txt }
        }
      }
      if ($ingredients.Count -lt 3 -or $steps.Count -lt 2) { continue }

      $name = $p.title -replace '^Cookbook:', ''
      $timeStr = Get-TemplateParam $wt 'time'
      $minutes = Parse-Minutes $timeStr
      $estimated = $false
      if ($minutes -le 0) { $minutes = 10 + 2 * $ingredients.Count + (Parse-Minutes ($steps -join ' ')); $estimated = $true }
      $minutes = Round5 $minutes

      $diffNum = 0
      [void][int]::TryParse((Get-TemplateParam $wt 'difficulty'), [ref]$diffNum)
      if ($diffNum -ge 1) {
        $difficulty = if ($diffNum -le 2) { 'easy' } elseif ($diffNum -eq 3) { 'medium' } else { 'hard' }
      } else {
        $difficulty = Get-Difficulty $ingredients.Count $steps.Count $minutes
      }

      $catText = ($cats -join ' | ')
      $course = 'main'
      if ($catText -match 'Breakfast') { $course = 'breakfast' }
      elseif ($catText -match 'Dessert|Cake|Cookie|Biscuit|Sweet|Candy|Confection|Pudding|Pastr') { $course = 'dessert' }
      elseif ($catText -match 'Soup|Stew' -or $name -match '(?i)soup|chowder|broth') { $course = 'soup' }
      elseif ($catText -match 'Salad|Side dish|Appetizer|Snack|Bread|Starter|Dip') { $course = 'side' }

      $image = Get-TemplateParam $wt 'image'
      $image = ($image -replace '^\[\[(?:File|Image):', '' -replace '\|.*$', '' -replace '\]\]$', '').Trim()
      if ($image) { $image = 'https://commons.wikimedia.org/wiki/Special:FilePath/' + [Uri]::EscapeDataString($image) + '?width=640' }

      # Intro paragraph often carries the cultural story.
      $url = "https://en.wikibooks.org/wiki/" + ($p.title -replace ' ', '_')
      $introText = (($intro -split "`n") | ForEach-Object { Clean-Wiki $_ } |
        Where-Object { $_.Length -gt 60 -and $_ -notmatch '\|' }) -join ' '
      $culture = Get-WikiCulture ($name -replace '\s*\(.*\)$', '')
      if (-not $culture -and $introText.Length -gt 80) {
        $culture = [ordered]@{ text = $introText; source = [ordered]@{ name = 'Wikibooks Cookbook'; url = $url } }
      }

      $items = $ingredients | ForEach-Object { $_.item }
      $diet = Get-Diet $items
      Add-Recipe ([ordered]@{
        id          = "w$($p.pageid)"
        name        = $name
        author      = 'Wikibooks Cookbook contributors'
        source      = [ordered]@{ name = 'Wikibooks Cookbook'; url = $url }
        via         = [ordered]@{ name = 'Wikibooks'; url = $url }
        image       = $image
        cuisine     = $cuisine
        country     = ''
        region      = Get-Region $cuisine
        course      = $course
        protein     = Get-Protein '' $items $diet $name
        diet        = $diet
        minutes     = $minutes
        timeEstimated = $estimated
        difficulty  = $difficulty
        ingredients = @($ingredients)
        steps       = @($steps)
        tags        = @()
        youtube     = ''
        culture     = $culture
        license     = 'CC BY-SA 4.0'
      })
      $kept++
    }
  }
  Write-Host "  kept $kept Wikibooks recipes"
}

# ================================================================= write files

if (Test-Path $RecDir) { Remove-Item -Recurse -Force $RecDir }
New-Item -ItemType Directory -Force $RecDir | Out-Null

$index = New-Object System.Collections.ArrayList
foreach ($r in $recipes) {
  $json = $r | ConvertTo-Json -Depth 8 -Compress
  [IO.File]::WriteAllText((Join-Path $RecDir "$($r.id).json"), $json, $Utf8)
  [void]$index.Add([ordered]@{
    id = $r.id; n = $r.name; c = $r.cuisine; g = $r.region; k = $r.course; p = $r.protein
    t = $r.minutes; d = $r.difficulty; v = $r.diet
  })
}
$meta = [ordered]@{ generated = (Get-Date).ToString('yyyy-MM-dd'); count = $index.Count; recipes = @($index) }
[IO.File]::WriteAllText((Join-Path $OutDir 'index.json'), ($meta | ConvertTo-Json -Depth 5 -Compress), $Utf8)

if (-not $SkipWikipedia) {
  New-Item -ItemType Directory -Force (Split-Path $CacheFile) | Out-Null
  [IO.File]::WriteAllText($CacheFile, ($WikiCache | ConvertTo-Json -Depth 5 -Compress), $Utf8)
}

Write-Host "Done: $($index.Count) recipes written to data/"
