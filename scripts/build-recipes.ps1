<#
  FindYourRecipe recipe harvester.

  Pulls recipes from open sources, normalizes them, and writes:
    data/index.json      - small searchable index used for filtering
    data/r/<id>.json     - one full recipe per file

  Sources (all free to reuse, with attribution):
    - TheMealDB API          https://www.themealdb.com/api.php
    - Wikibooks Cookbook     https://en.wikibooks.org/wiki/Cookbook         (CC BY-SA)
    - based.cooking          https://github.com/LukeSmithxyz/based.cooking    (public domain)
    - Public Domain Recipes  https://github.com/ronaldl29/public-domain-recipes (public domain)
    - Wickham family recipes https://github.com/hadley/recipes                (CC BY 4.0, family recipes only)
    - Project Gutenberg      Boston Cooking-School Cook Book (1896), Mrs Beeton (1861) (public domain)
    - Wikipedia summaries    for the cultural-significance blurbs           (CC BY-SA)

  Sites whose terms forbid scraping (Allrecipes, Yelp, Fandom, ...) are deliberately not crawled.
  Star ratings are NOT harvested: the hidden rating comes from FindYourRecipe cooks.

  Usage (from the repo root):
    powershell -ExecutionPolicy Bypass -File scripts\build-recipes.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-recipes.ps1 -SkipGutenberg -SkipWikipedia
#>
param(
  [int]$WikibooksMax = 5000,
  [switch]$SkipWikibooks,
  [switch]$SkipMarkdown,
  [switch]$SkipGutenberg,
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

# One shared HttpClient: much faster than Invoke-WebRequest in Windows PowerShell.
Add-Type -AssemblyName System.Net.Http
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(40)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd($UA)

function Get-Text([string]$Url) {
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $resp = $Http.GetAsync($Url).GetAwaiter().GetResult()
      if ([int]$resp.StatusCode -eq 404) { return $null }
      if ($resp.IsSuccessStatusCode) {
        return [Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
      }
      if ([int]$resp.StatusCode -eq 429) { Start-Sleep -Seconds (5 * ($i + 1)); continue }
    } catch { }
    Start-Sleep -Seconds (2 * ($i + 1))
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

$SeaWords = @('fish','salmon','tuna','cod','haddock','anchovy','anchovies','prawn','shrimp','crab','lobster','mussel','clam',
  'oyster','scallop','squid','octopus','mackerel','sardine','trout','herring','kipper','monkfish','sea bass','bream','plaice',
  'halibut','tilapia','catfish','carp','eel','caviar','roe','dashi','bonito','worcestershire','crawfish','crayfish',
  'langoustine','calamari','tilefish','swordfish','snapper','whitebait','pollock','hake','cockle','whelk','sole','pilchard',
  'saltfish','bacalao','bacalhau','surimi','katsuobushi')
$LandMeatWords = @('chicken','beef','pork','lamb','mutton','goat','bacon','ham','sausage','chorizo','prosciutto','pancetta',
  'salami','pepperoni','turkey','duck','veal','venison','gelatin','gelatine','lard','suet','meat','steak','mince',
  'brisket','rib','liver','kidney','oxtail','rabbit','pheasant','quail','goose','pigeon','gravy','frankfurter','hot dog',
  'spam','pastrami','jamon','guanciale','andouille','kielbasa','mortadella','snail','escargot','frog','bresaola','biltong',
  'boerewors','merguez','offal','tripe','bone marrow','chicken stock','beef stock','bouillon cube','stock cube','maggi',
  'giblet','sweetbread','tongue','trotter','hock','pâté','pate','foie gras','black pudding','haggis','corned beef','jerky')
$DairyEggWords = @('egg','yolk','milk','butter','cream','cheese','yogurt','yoghurt','honey','ghee','parmesan','mozzarella',
  'cheddar','feta','ricotta','mascarpone','paneer','buttermilk','condensed','custard','mayonnaise','mayo','whey','fraiche',
  'fraîche','gruyere','gruyère','brie','camembert','stilton','gorgonzola','halloumi','pecorino','quark','kefir','lassi','curd',
  'meringue','labneh','skyr','evaporated','ice cream','aioli','hollandaise')
# Phrases that contain an animal word but are plant-based.
$PlantSafe = @('eggplant','butternut','peanut butter','almond butter','cocoa butter','nut butter','cashew butter','coconut milk',
  'almond milk','soy milk','soya milk','oat milk','rice milk','coconut cream','vegan','cream of tartar','butter beans',
  'butterhead','buttercup','cashew cream','plant milk','bean curd','fish-free','mushroom stock','vegetable stock',
  'vegetable bouillon','vegan mayo','oyster mushroom','coconut yogurt','coconut yoghurt','dairy-free','dairy free',
  'egg-free','eggless','beef tomato','mincemeat','minced garlic','minced ginger','minced onion','vegetarian sausage',
  'meat-free','meatless','jackfruit','celery rib','rib of celery','ribs of celery','celery ribs')

function Test-Words([string]$text, [string[]]$words) {
  foreach ($w in $words) { if ($text -match ('\b' + [regex]::Escape($w) + '(s|es)?\b')) { return $true } }
  return $false
}

function Normalize-Ingredients([string[]]$items) {
  return (($items -join ' | ').ToLower()) -replace "goat'?s? (cheese|milk|curd|yogh?urt)", 'cheese' -replace "sheep'?s? (cheese|milk)", 'cheese' -replace "’", "'"
}

function Remove-Phrases([string]$t, [string[]]$phrases) {
  foreach ($p in $phrases) { $t = $t.Replace($p, ' ') }
  return $t
}

# 0 = contains land meat, 1 = pescatarian, 2 = vegetarian, 3 = vegan
function Get-Diet([string[]]$items) {
  $t = Remove-Phrases (Normalize-Ingredients $items) $PlantSafe
  if (Test-Words $t $LandMeatWords) { return 0 }
  if (Test-Words $t $SeaWords) { return 1 }
  if (Test-Words $t $DairyEggWords) { return 2 }
  return 3
}

# Allergen / avoid flags. Bit order must match js/data.js ALLERGENS.
$Allergens = [ordered]@{
  gluten = @{ bit = 1; words = @('flour','wheat','bread','breadcrumb','crumb','pasta','spaghetti','noodle','macaroni','penne',
      'linguine','lasagne','lasagna','fettuccine','tagliatelle','ravioli','tortellini','gnocchi','couscous','bulgur','bulgar',
      'barley','rye','semolina','seitan','soy sauce','beer','malt','pastry','tortilla','pitta','pita','naan','chapati','roti',
      'cracker','biscuit','cake','oat','oatmeal','farro','spelt','orzo','udon','ramen','panko','wonton','filo','phyllo','digestive',
      'croissant','brioche','bun','baguette','ciabatta','focaccia','muffin','self-raising','self raising','vermicelli','cookie',
      'crouton','stuffing','graham','matzo','bran','durum','freekeh','hoisin','sponge','wafer','pretzel','bagel','dumpling wrapper',
      'gyoza wrapper','puff','shortcrust','fregola','pierogi','stout','ale','lager','teriyaki','bisquick')
    except = @('rice flour','corn flour','cornflour','almond flour','coconut flour','chickpea flour','gram flour','tapioca flour',
      'potato flour','buckwheat flour','cassava flour','gluten-free','gluten free','rice noodle','glass noodle','rice vermicelli',
      'rice paper','rice cake','tamari','corn tortilla','oat milk','ginger ale','gluten-free soy sauce','cornbread') }
  dairy = @{ bit = 2; words = @('milk','butter','cream','cheese','yogurt','yoghurt','ghee','whey','buttermilk','condensed',
      'custard','ice cream','paneer','fraiche','fraîche','kefir','lassi','curd','quark','mascarpone','ricotta','parmesan',
      'mozzarella','cheddar','feta','gruyere','gruyère','brie','camembert','stilton','gorgonzola','halloumi','pecorino','labneh',
      'skyr','evaporated','casein','dulce de leche','queso','burrata','emmental','manchego','provolone','ghee','béchamel','bechamel')
    except = @('coconut milk','almond milk','soy milk','soya milk','oat milk','rice milk','coconut cream','peanut butter',
      'almond butter','cocoa butter','nut butter','cashew butter','cream of tartar','butter beans','butterhead','buttercup',
      'butternut','cashew cream','plant milk','bean curd','dairy-free','dairy free','vegan','coconut yogurt','coconut yoghurt','cream crackers') }
  egg = @{ bit = 4; words = @('egg','yolk','mayonnaise','mayo','meringue','aioli','albumen','hollandaise','custard','egg noodle')
    except = @('eggplant','egg-free','eggless','vegan mayo') }
  peanut = @{ bit = 8; words = @('peanut','groundnut','satay','monkey nut'); except = @() }
  treenut = @{ bit = 16; words = @('almond','walnut','pecan','cashew','pistachio','hazelnut','macadamia','brazil nut','pine nut',
      'chestnut','marzipan','praline','nutella','frangipane','amaretti','nut','pignoli','gianduja')
    except = @('nutmeg','butternut','coconut','doughnut','donut','peanut','water chestnut','groundnut','nutritional yeast','monkey nut') }
  fish = @{ bit = 32; words = @('fish','salmon','tuna','cod','haddock','anchovy','anchovies','mackerel','sardine','trout','herring',
      'kipper','monkfish','sea bass','bream','plaice','halibut','tilapia','catfish','carp','eel','caviar','roe','dashi','bonito',
      'worcestershire','tilefish','swordfish','snapper','whitebait','pollock','hake','sole','pilchard','saltfish','bacalao',
      'bacalhau','katsuobushi','surimi')
    except = @('fish-free','shellfish') }
  shellfish = @{ bit = 64; words = @('shrimp','prawn','crab','lobster','crayfish','crawfish','langoustine','mussel','clam','oyster',
      'scallop','squid','octopus','calamari','cockle','whelk','shellfish','seafood','surimi')
    except = @('oyster mushroom') }
  soy = @{ bit = 128; words = @('soy','soya','tofu','tempeh','edamame','miso','tamari','bean curd','natto','tvp','teriyaki','hoisin')
    except = @() }
  sesame = @{ bit = 256; words = @('sesame','tahini','halva','halvah','zaatar',"za'atar",'gomasio','benne'); except = @() }
  pork = @{ bit = 512; words = @('pork','bacon','ham','sausage','chorizo','pancetta','prosciutto','lard','gelatin','gelatine',
      'salami','pepperoni','guanciale','jamon','andouille','kielbasa','mortadella','spam','hot dog','frankfurter','trotter',
      'hock','black pudding','crackling','speck','nduja')
    except = @('vegetarian sausage','vegan sausage','chicken sausage','turkey sausage','beef sausage','lamb sausage','turkey bacon','beef bacon') }
  alcohol = @{ bit = 1024; words = @('wine','beer','rum','vodka','brandy','whisky','whiskey','sherry','sake','mirin','liqueur',
      'cognac','tequila','gin','port','marsala','kirsch','amaretto','bourbon','stout','ale','lager','champagne','prosecco',
      'vermouth','calvados','grand marnier','cointreau','triple sec','shaoxing','madeira','cider','schnapps','grappa','ouzo',
      'raki','baileys','kahlua','limoncello','cachaça','cachaca','pisco','soju','absinthe','bitters')
    except = @('wine vinegar','rice vinegar','cider vinegar','sherry vinegar','malt vinegar','rice wine vinegar','ginger ale','ginger beer','root beer','non-alcoholic','alcohol-free','apple cider vinegar') }
  mustard = @{ bit = 2048; words = @('mustard','dijon'); except = @('mustard greens') }
  celery = @{ bit = 4096; words = @('celery','celeriac','celery salt','celery seed'); except = @() }
  sulfites = @{ bit = 8192; words = @('wine','dried apricot','dried fruit','sultana','raisin','prune','vinegar','molasses','sauerkraut',
      'pickle','pickled','maraschino','grape juice','lemon juice concentrate','sherry','port','vermouth','champagne','prosecco','cider')
    except = @() }
  nightshade = @{ bit = 16384; words = @('tomato','tomatoes','potato','potatoes','pepper','peppers','capsicum','chilli','chili','chile',
      'paprika','cayenne','aubergine','eggplant','jalapeño','jalapeno','pimento','pimiento','tomatillo','goji','harissa','sriracha',
      'tabasco','hot sauce','salsa','ketchup','passata','chipotle','scotch bonnet','habanero','gochujang','berbere','chilli flakes')
    except = @('sweet potato','sweet potatoes','black pepper','white pepper','peppercorn','ground pepper','pepper to taste',
      'salt and pepper','salt & pepper','szechuan pepper','sichuan pepper','pink peppercorn') }
  mushroom = @{ bit = 32768; words = @('mushroom','porcini','shiitake','chanterelle','morel','truffle','enoki','oyster mushroom','portobello','cep','girolle','champignon')
    except = @('chocolate truffle') }
  coconut = @{ bit = 65536; words = @('coconut','copra'); except = @() }
  corn = @{ bit = 131072; words = @('corn','cornmeal','cornflour','corn flour','cornstarch','polenta','maize','masa','grits','hominy','popcorn','tortilla chip','sweetcorn','corn syrup')
    except = @('peppercorn','corned beef','acorn','corn salad','flour tortilla') }
  allium = @{ bit = 262144; words = @('onion','garlic','shallot','leek','chive','scallion','spring onion','green onion','asafoetida','asafetida')
    except = @() }
  spicy = @{ bit = 524288; words = @('chilli','chili','chile','cayenne','jalapeño','jalapeno','habanero','scotch bonnet','chipotle',
      'sriracha','tabasco','hot sauce','harissa','gochujang','sambal','chilli flakes','red pepper flakes','pepper flakes','bird''s eye',
      'piri piri','peri peri','berbere','wasabi','horseradish','curry paste','vindaloo','ghost pepper','serrano')
    except = @('sweet chilli sauce','sweet chili sauce','mild chilli','chili powder (mild)') }
  redmeat = @{ bit = 1048576; words = @('beef','pork','lamb','mutton','goat','veal','venison','steak','mince','brisket','oxtail','bacon','ham',
      'sausage','chorizo','salami','pepperoni','prosciutto','pancetta','rabbit','bison','liver','kidney','oxtail','corned beef','boerewors','merguez')
    except = @('chicken sausage','turkey sausage','vegetarian sausage','vegan sausage','turkey bacon','beef tomato','mincemeat') }
}

function Get-AllergenMask([string[]]$items) {
  $base = Normalize-Ingredients $items
  $mask = 0
  foreach ($a in $Allergens.Values) {
    $t = Remove-Phrases $base $a.except
    if (Test-Words $t $a.words) { $mask = $mask -bor $a.bit }
  }
  return $mask
}

# Lifestyle diets, written as bit flags (index field "y"). Bit order must match js/data.js LIFESTYLES.
# These are ingredient-based approximations ("-friendly"), not certifications.
$HighCarbWords = @('flour','bread','breadcrumb','pasta','spaghetti','noodle','macaroni','rice','potato','potatoes','sugar','honey',
  'syrup','molasses','treacle','oat','oats','oatmeal','corn','cornmeal','polenta','couscous','quinoa','bulgur','barley','tortilla',
  'pita','pitta','naan','cracker','biscuit','cake','pastry','cassava','yam','plantain','banana','semolina','millet','sorghum',
  'teff','fufu','gnocchi','dumpling','bun','roll','bagel','croissant','cereal','granola','jam','marmalade','condensed','dates',
  'raisin','sultana','chocolate chip','cornflakes','tapioca','arrowroot','lasagne','lasagna','ramen','udon','vermicelli','orzo',
  'risotto','arborio','basmati','sago','custard powder','ketchup','juice')
$HighCarbExcept = @('almond flour','coconut flour','cauliflower rice','courgetti','zucchini noodle','shirataki','sugar-free','sugar free',
  'rice vinegar','rice wine vinegar','spring roll wrapper','lime juice','lemon juice','juice of')
$LegumeWords = @('bean','beans','lentil','lentils','chickpea','chickpeas','pea','peas','peanut','soy','soya','tofu','tempeh','edamame',
  'hummus','dal','dhal','gram','miso','black-eyed')
$LegumeExcept = @('green beans','green bean','runner beans','french beans','string beans','snow peas','sugar snap','vanilla bean',
  'coffee bean','cocoa bean','jelly bean','sweet pea','chickpea flour')
$SweetFruitWords = @('apple','banana','mango','pineapple','orange','grape','raisin','date','fig','pear','peach','cherry','cherries',
  'apricot','plum','melon','watermelon','papaya','kiwi','prune','sultana','currant','cranberries','dried fruit')
$AddedSugarWords = @('sugar','honey','syrup','molasses','treacle','condensed milk','jam','marmalade','jaggery','agave','caramel',
  'dulce de leche','icing','frosting','chocolate','candied','glacé','glace','sweetened','marshmallow','nutella','ketchup','sprinkles')
$AddedSugarExcept = @('sugar-free','sugar free','unsweetened','no sugar','dark chocolate 85','sugar snap')

function Get-LifestyleMask([string[]]$items, [int]$allergens, [int]$diet) {
  $base = Normalize-Ingredients $items
  $has = { param($bit) ($allergens -band $bit) -ne 0 }
  $blood = $base -match '\bblood\b|black pudding|blood sausage|dinuguan'
  $nonKosherFish = Test-Words $base @('eel','catfish','monkfish','swordfish','shark','sturgeon','caviar','rabbit','frog','snail','escargot')
  $landMeat = $diet -eq 0
  $dairy = & $has 2
  $highCarb = Test-Words (Remove-Phrases $base $HighCarbExcept) $HighCarbWords
  $legume = Test-Words (Remove-Phrases $base $LegumeExcept) $LegumeWords
  $sweetFruit = Test-Words $base $SweetFruitWords
  $milk = Test-Words (Remove-Phrases $base @('coconut milk','almond milk','oat milk','soy milk','buttermilk')) @('milk','condensed milk','evaporated milk')
  $sugar = Test-Words (Remove-Phrases $base $AddedSugarExcept) $AddedSugarWords
  $grains = (& $has 1) -or (Test-Words (Remove-Phrases $base @('cauliflower rice','rice vinegar','rice wine vinegar')) @('rice','corn','cornmeal','polenta','oat','oats','quinoa','millet','sorghum','teff','buckwheat','couscous','tortilla','maize'))
  $processed = Test-Words $base @('margarine','vegetable oil','canola','soybean oil','sunflower oil','stock cube','bouillon cube','maggi','msg','processed cheese','spam','hot dog')

  $mask = 0
  if (-not (& $has 512) -and -not (& $has 1024) -and -not $blood) { $mask = $mask -bor 1 }                        # halal-friendly
  if (-not (& $has 512) -and -not (& $has 64) -and -not $blood -and -not $nonKosherFish -and -not ($landMeat -and $dairy)) { $mask = $mask -bor 2 }  # kosher-style
  if (-not $highCarb) { $mask = $mask -bor 4 }                                                                       # low-carb
  if (-not $highCarb -and -not $legume -and -not $sweetFruit -and -not $milk -and -not $sugar) { $mask = $mask -bor 8 } # keto-friendly
  $paleo = -not $grains -and -not $legume -and -not $dairy -and -not $sugar -and -not $processed -and -not (& $has 128)
  if ($paleo) { $mask = $mask -bor 16 }                                                                              # paleo-friendly
  if ($paleo -and -not (& $has 1024)) { $mask = $mask -bor 32 }                                                      # whole30-friendly
  if (-not $sugar) { $mask = $mask -bor 64 }                                                                         # no added sugar
  return $mask
}

# ---------------------------------------------------------------- timing

$PassiveRx = '\bmarinat|\bchill|refrigerat|\bfridge|\bfreez|\brest(ing)?\b(?! of)|\bprove\b|\bproof|\brise\b|\brisen\b|\bsoak|' +
             'ferment|leave (it |them |to )?(to )?(stand|set|cool|rest|rise)|until set|stand for|let (it |them )?(stand|cool|sit|rest)|' +
             '\bcool\b|overnight|\bsteep|\binfuse|\bcure\b|\bsettle'
$StorageRx = 'keep(s)? (for|in|up)|\bstore|will last|lasts|make ahead|can be made|in advance|freezes well|airtight|up to \d+ (days?|weeks?|months?)'
$OptionalRx = '^\s*(if|alternatively|optionally|tip|note|for a)\b|\bif you (use|want|prefer|like|have|are)|you can (also )?(use|make|substitute|swap)|to get a more|instead of'
$ParallelRx = '^\s*(meanwhile|while)\b|in the meantime|at the same time'
$CookVerbRx = '\b(bake|fry|boil|simmer|roast|grill|saut[eé]|cook|stew|braise|steam|poach|toast|broil|sear|brown)'
$PassiveNames = [ordered]@{ 'marinat' = 'marinating'; 'proof|prove|rise|risen' = 'rising'; 'soak' = 'soaking';
  'freez' = 'freezing'; 'chill|fridge|refrigerat|until set' = 'chilling'; 'ferment' = 'fermenting'; 'rest|stand|sit' = 'resting';
  'cool' = 'cooling'; 'steep|infuse' = 'steeping'; 'cure' = 'curing' }

$NumberWords = [ordered]@{
  'twenty-five' = 25; 'forty-five' = 45; 'thirty-five' = 35; 'fifteen' = 15; 'twenty' = 20; 'thirty' = 30; 'forty' = 40;
  'fifty' = 50; 'sixty' = 60; 'ninety' = 90; 'eleven' = 11; 'twelve' = 12; 'eighteen' = 18; 'ten' = 10; 'one' = 1; 'two' = 2;
  'three' = 3; 'four' = 4; 'five' = 5; 'six' = 6; 'seven' = 7; 'eight' = 8; 'nine' = 9
}
# Older recipes write times in words: "cook fifteen minutes", "half an hour".
function Convert-NumberWords([string]$s) {
  $s = $s -replace '\b(half an|a half) hour', '30 minutes' -replace '\bquarter of an hour', '15 minutes' -replace '\ban hour\b', '1 hour' -replace '\ba few minutes', '3 minutes'
  $s = [regex]::Replace($s, '\b(one|two|three|four|five|six) and (one-)?half (hours?|minutes?)', {
    param($m) "$($NumberWords[$m.Groups[1].Value] + 0.5) $($m.Groups[3].Value)" })
  foreach ($w in $NumberWords.Keys) {
    $s = [regex]::Replace($s, "\b$w\b(?=\s+((to|or)\s+\w+\s+)?(days?|hours?|minutes?|mins?|seconds?)\b)", [string]$NumberWords[$w])
    $s = [regex]::Replace($s, "\b$w\b(?=\s+(to|or)\s+\d)", [string]$NumberWords[$w])
  }
  return $s
}

function Get-Timing([string[]]$steps, $ingredients) {
  $active = 0.0; $passive = 0.0; $why = New-Object System.Collections.ArrayList
  $rx = '(\d+(?:\.\d+)?)\s*(?:(?:-|–|to|or)\s*(\d+(?:\.\d+)?))?\s*(days?|hours?|hrs?|minutes?|mins?|seconds?|secs?)\b'
  foreach ($step in $steps) {
    $s0 = Convert-NumberWords ($step.ToLower() -replace '½', '.5' -replace '¼', '.25' -replace '¾', '.75' -replace '(\d)\s+\.(\d)', '$1.$2')
    foreach ($s in [regex]::Split($s0, '(?<=[.!?;])\s+')) {
      if ($s -match $StorageRx -or $s -match $OptionalRx) { continue }
      $parallel = $s -match $ParallelRx
      $isPassive = $s -match $PassiveRx
      $found = $false
      foreach ($m in [regex]::Matches($s, $rx)) {
        $before = $s.Substring([Math]::Max(0, $m.Index - 12), [Math]::Min(12, $m.Index))
        if ($before -match '\bevery\b|\beach\b(?! side)') { continue }
        $v = [double]$m.Groups[1].Value
        if ($m.Groups[2].Success) { $v = [double]$m.Groups[2].Value }
        $u = $m.Groups[3].Value
        $mins = if ($u -like 'd*') { $v * 1440 } elseif ($u -like 'h*') { $v * 60 } elseif ($u -like 's*') { $v / 60 } else { $v }
        if ($u -like 'd*' -and -not $isPassive) { continue }
        $after = $s.Substring($m.Index + $m.Length, [Math]::Min(18, $s.Length - $m.Index - $m.Length))
        if ($after -match '^\s*(on |per |a )?(each |a )?side') { $mins *= 2 }
        if ($mins -gt 4320) { continue }   # more than 3 days is almost always storage advice
        $found = $true
        if ($isPassive) { $passive += $mins } elseif (-not $parallel) { $active += $mins }
      }
      if ($isPassive -and -not $found -and $s -match 'overnight') { $passive += 480; $found = $true }
      if ($isPassive -and $found) {
        foreach ($k in $PassiveNames.Keys) { if ($s -match $k) { if (-not $why.Contains($PassiveNames[$k])) { [void]$why.Add($PassiveNames[$k]) }; break } }
      }
    }
  }
  $all = ($steps -join ' ').ToLower()
  if ($active -lt 5 -and $all -match $CookVerbRx) { $active = [Math]::Min(45, 10 + 3 * $steps.Count) }

  $chop = 0
  foreach ($i in $ingredients) { if (("$($i.qty) $($i.item)") -match '(?i)chop|dice|slice|mince|grate|peel|shred|crush|julienne|cube') { $chop++ } }
  $prep = [Math]::Min(50, 5 + 1.5 * $ingredients.Count + 1.5 * $chop)

  return [ordered]@{
    prep    = Round5 $prep
    cook    = if ($active -gt 0) { Round5 $active } else { 0 }
    passive = if ($passive -gt 0) { Round5 $passive } else { 0 }
    passiveWhy = @($why | Select-Object -First 2)
  }
}

function Normalize-Qty([string]$q) {
  $q = Clean-Text $q
  $q = $q -replace '(?i)\b(tblsp|tbls|tbsps|tbs|tbl|tablespoons?)\b\.?', 'tbsp' -replace '(?i)\b(tspn|tsps|teaspoons?)\b\.?', 'tsp'
  $q = $q -replace '(?i)\bhandfull\b', 'handful' -replace '(?i)\bgrams?\b', 'g' -replace '(?i)\b(millilitres?|milliliters?)\b', 'ml'
  $q = $q -replace '(?i)\b(litres?|liters?)\b', 'L' -replace '(?i)\bkilos?\b|\bkilograms?\b', 'kg'
  $q = $q -replace '(?i)\b(\d+(?:\.\d+)?)\s*(?=(g|kg|ml|L|oz|lb)\b)', '$1 '
  return $q.Trim()
}

# ---------------------------------------------------------------- text clean-up

# Misspellings found in the source recipes (whole words, any case).
$Typos = @{
  'tomatos' = 'tomatoes'; 'tomaotes' = 'tomatoes'; 'ptoatoes' = 'potatoes'; 'potatos' = 'potatoes'; 'spinkling' = 'sprinkling';
  'handfull' = 'handful'; 'handfulls' = 'handfuls'; 'skinnless' = 'skinless'; 'seperated' = 'separated'; 'seperate' = 'separate';
  'seperately' = 'separately'; 'yolkes' = 'yolks'; 'hazlenuts' = 'hazelnuts'; 'hazlenut' = 'hazelnut'; 'dessicated' = 'desiccated';
  'cardamon' = 'cardamom'; 'cardemom' = 'cardamom'; 'cheescake' = 'cheesecake'; 'emove' = 'remove'; 'fetta' = 'feta';
  'fryrer' = 'fryer'; 'gilden' = 'golden'; 'grounf' = 'ground'; 'incorperate' = 'incorporate'; 'insterted' = 'inserted';
  'millk' = 'milk'; 'miutes' = 'minutes'; 'mozarella' = 'mozzarella'; 'mozzerella' = 'mozzarella'; 'occassionally' = 'occasionally';
  'ovenight' = 'overnight'; 'pistachos' = 'pistachios'; 'plaintains' = 'plantains'; 'preaheated' = 'preheated';
  'prheated' = 'preheated'; 'ricotto' = 'ricotta'; 'salth' = 'salt'; 'sheeet' = 'sheet'; 'startch' = 'starch'; 'strarts' = 'starts';
  'temperture' = 'temperature'; 'tendir' = 'tender'; 'thickenes' = 'thickens'; 'thinnly' = 'thinly'; 'throughly' = 'thoroughly';
  'untill' = 'until'; 'berberei' = 'berbere'; 'bratwurstf' = 'bratwurst'; 'kneed' = 'knead'; 'kneeding' = 'kneading';
  'abour' = 'about'; 'tblsp' = 'tbsp'; 'cassaba' = 'cassava'; 'brocolli' = 'broccoli'; 'brocoli' = 'broccoli';
  'parmesean' = 'parmesan'; 'parmasan' = 'parmesan'; 'worchestershire' = 'Worcestershire'; 'worcester' = 'Worcestershire';
  'tumeric' = 'turmeric'; 'cinammon' = 'cinnamon'; 'cinamon' = 'cinnamon'; 'vanila' = 'vanilla'; 'zuchini' = 'zucchini';
  'zucchinni' = 'zucchini'; 'cilantro' = 'cilantro'; 'corriander' = 'coriander'; 'chillis' = 'chillies'; 'tablesppon' = 'tablespoon';
  'teaspon' = 'teaspoon'; 'recieve' = 'receive'; 'seasonning' = 'seasoning'; 'definately' = 'definitely'; 'carmelize' = 'caramelize';
  'carmelized' = 'caramelized'; 'saute' = 'sauté'; 'sauteed' = 'sautéed'; 'sauteing' = 'sautéing'; 'yoghourt' = 'yoghurt';
  'aubergines' = 'aubergines'; 'cumberland' = 'Cumberland'; 'gruyere' = 'Gruyère'; 'jalepeno' = 'jalapeño'; 'jalepenos' = 'jalapeños';
  'mayonaise' = 'mayonnaise'; 'pinapple' = 'pineapple'; 'raspberrys' = 'raspberries'; 'strawberrys' = 'strawberries';
  'ea' = 'each'; 'tbls' = 'tbsp'
}
$TyposRx = '\b(' + (($Typos.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'

function Fix-Typos([string]$s) {
  if (-not $s) { return $s }
  return [regex]::Replace($s, $TyposRx, {
    param($m)
    $fix = $Typos[$m.Value.ToLower()]
    if ($m.Value -cmatch '^[A-Z]' -and $fix -cmatch '^[a-z]') { $fix = $fix.Substring(0, 1).ToUpper() + $fix.Substring(1) }
    $fix
  }, 'IgnoreCase')
}

function Fix-Sentence([string]$s) {
  if (-not $s) { return $s }
  $s = Fix-Typos $s
  $s = $s -replace '([a-z\)%])([.!?])([A-Z][a-z])', '$1$2 $3'      # "beef.Slow" -> "beef. Slow"
  $s = $s -replace '\s+([,.;:!?])(?=\s|$)', '$1'                    # "salt , pepper" -> "salt, pepper"
  $s = $s -replace ',(?=[A-Za-z])', ', '                            # "salt,pepper" -> "salt, pepper"
  $s = $s -replace '(\d)\s*[º°]\s*([CF])\b', '$1°$2' -replace '\.{2,}(?!\.)', '.' -replace '\s{2,}', ' '
  $s = $s.Trim()
  if ($s -cmatch '^[a-z]') { $s = $s.Substring(0, 1).ToUpper() + $s.Substring(1) }
  return $s
}

# Words that stay capitalized in ingredient names.
$ProperWords = @('Parmesan','Parmigiano','Reggiano','Worcestershire','Dijon','Greek','Italian','French','Mexican','Thai','Chinese',
  'Japanese','Spanish','English','Scotch','Tabasco','Sriracha','Cajun','Bramley','Maldon','Gruyère','Cheddar',
  'Emmental','Roquefort','Stilton','Camembert','Brie','Kalamata','Medjool','Arborio','Basmati','Szechuan','Sichuan','Kashmiri',
  'Madras','Jamaican','Caribbean','Marmite','Nutella','Maggi','Knorr','Angostura','Cointreau','Marnier','Kahlua',
  'Baileys','Marsala','Madeira','Yorkshire','Cornish','Serrano','Iberico','Parma','Cumberland','Toulouse',
  'Romano','Pecorino','Manchego','Gouda','Edam','Comté','Monterey','Colby','Dutch','Swiss','Turkish','Indian','Asian',
  'Mediterranean','Provence','Philadelphia','Guinness','Thai','Bombay','Persian','Moroccan','Lebanese','Korean','Vietnamese',
  'Puy','Valencia','Seville','Darjeeling','Assam','Oreo','Oreos',
  'Herbes','Mexico','Kenyan','Nigerian','Ghanaian','Ethiopian','Brazilian','Peruvian','Polish','Hungarian','Russian',
  'Ukrainian','German','Danish','Norwegian','Irish','Scottish','Welsh','American','Canadian','Australian','Filipino','Malaysian')
$ProperSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($w in $ProperWords) { [void]$ProperSet.Add($w) }
$ProperMap = @{}; foreach ($w in $ProperWords) { $ProperMap[$w.ToLower()] = $w }

# TheMealDB writes ingredients in Title Case ("Double Cream"); use normal casing ("double cream").
function Fix-ItemCase([string]$item) {
  if (-not $item) { return $item }
  $words = $item -split ' '
  $out = foreach ($w in $words) {
    $core = $w -replace '[^\p{L}]', ''
    if ($core -and $ProperMap.ContainsKey($core.ToLower())) { $w -replace [regex]::Escape($core), $ProperMap[$core.ToLower()] }
    elseif ($w -cmatch '^[A-Z]{2,}$') { $w }                       # acronyms like "BBQ"
    else { $w.ToLower() }
  }
  return ($out -join ' ')
}

# "1 chopped" + "Garlic Clove" -> qty "1", item "garlic clove, chopped"
$PrepWords = 'finely chopped|roughly chopped|coarsely chopped|chopped|thinly sliced|sliced|diced|minced|finely grated|grated|' +
  'crushed|lightly beaten|beaten|melted|softened|peeled|halved|quartered|shredded|cubed|deseeded|seeded|sifted|toasted|juiced|' +
  'zested|drained|rinsed|cooked|boiled|mashed|separated|at room temperature|to taste|to serve|for garnish|to garnish|garnish|' +
  'for frying|for greasing|for dusting|for brushing|optional|torn|trimmed|pitted|crumbled|cut into [^,]+|cut in [^,]+|' +
  'chopped finely|sliced thinly|bashed|bruised|squeezed|ground|freshly ground|warm|cold|room temperature|whisked|dissolved'
$PrepRx = "^(?<amt>.*?)\s*\b(?<prep>(?:$PrepWords)(?:\s*(?:,|and|&)\s*(?:$PrepWords))*)\s*$"

function Split-Qty([string]$qty, [string]$item) {
  if (-not $qty) { return @($qty, $item) }
  $m = [regex]::Match($qty, $PrepRx, 'IgnoreCase')
  if (-not $m.Success) { return @($qty, $item) }
  $amt = $m.Groups['amt'].Value.Trim(' ', ',')
  $prep = $m.Groups['prep'].Value.ToLower()
  return @($amt, "$item, $prep")
}

function Fix-Name([string]$name) {
  $name = Fix-Typos (Clean-Text $name)
  if ($name -cmatch '^[a-z]') {
    $name = ($name -split ' ' | ForEach-Object { if ($_ -cmatch '^[a-z]' -and $_ -notmatch '^(and|or|with|in|of|a|the|de|la|al|e)$') { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } else { $_ } }) -join ' '
  }
  return $name
}

# Steps that are only headings ("Make the sauce:") are merged into the step that follows.
function Fix-Steps([string[]]$steps) {
  $out = New-Object System.Collections.ArrayList
  $pending = ''
  foreach ($s in $steps) {
    $s = Fix-Sentence $s
    if (-not $s) { continue }
    if ($s -match '^[^.!?]{2,60}:$' -or $s -match '^(for the|to make the|make the)\b[^.!?]{0,50}$') {
      $pending = ($s.TrimEnd(':')) + ': '
      continue
    }
    [void]$out.Add($pending + $s)
    $pending = ''
  }
  return @($out)
}

function Fix-Ingredients($ingredients, [bool]$titleCase) {
  $out = foreach ($i in $ingredients) {
    $item = (Fix-Typos (Clean-Text $i.item)) -replace '(?<!\b(oz|lb|lbs|tsp|tbsp|pt|qt|no|approx|etc))\.$', ''
    $qty = Fix-Typos (Clean-Text $i.qty)
    if ($titleCase) { $item = Fix-ItemCase $item }
    $pair = Split-Qty $qty $item
    $q = Normalize-Qty $pair[0]
    if ($q -cmatch '^[A-Z][a-z]+\b' -and $q -notmatch '^(Juice|Zest)\b') { $q = $q.Substring(0, 1).ToLower() + $q.Substring(1) }
    $it = $pair[1]
    # "1" + "red onions" -> "1 red onion"
    if ($q -match '^(1|one)( (large|medium|small|whole|big))?$') {
      $parts = $it -split ',', 2
      $noun = $parts[0]
      if ($noun -notmatch '(?i)(ss|us|is|molasses|greens|oats|lentils|peas|beans|noodles|sprouts|chives|herbs|leaves)$') {
        $noun = $noun -replace '(?i)(tomat|potat|mang)oes$', '$1o' -replace '(?i)([^aeiou])ies$', '$1y' -replace '(?i)([a-z]{3})s$', '$1'
      }
      $it = if ($parts.Count -gt 1) { "$noun,$($parts[1])" } else { $noun }
    }
    [ordered]@{ item = $it; qty = $q }
  }
  return @($out)
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
    'Pasta'   { if ($diet -ge 2) { return 'pasta' } }
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
  if ($diet -ge 2) {
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

# "Thai Green Curry" -> Thai, "Polish Pierogi" -> Polish; '' when the name has no clue.
$CuisineAliases = @{
  'Bavarian' = 'German'; 'Swabian' = 'German'; 'Berliner' = 'German'; 'Tuscan' = 'Italian'; 'Sicilian' = 'Italian';
  'Neapolitan' = 'Italian'; 'Roman' = 'Italian'; 'Venetian' = 'Italian'; 'Milanese' = 'Italian'; 'Genovese' = 'Italian';
  'Provençal' = 'French'; 'Provencal' = 'French'; 'Breton' = 'French'; 'Alsatian' = 'French'; 'Parisian' = 'French';
  'Andalusian' = 'Spanish'; 'Catalan' = 'Spanish'; 'Basque' = 'Spanish'; 'Galician' = 'Spanish'; 'Hunan' = 'Chinese';
  'Szechuan' = 'Chinese'; 'Shanghai' = 'Chinese'; 'Peking' = 'Chinese'; 'Keralan' = 'Indian'; 'Kerala' = 'Indian';
  'Goan' = 'Indian'; 'Mughlai' = 'Indian'; 'Hyderabadi' = 'Indian'; 'Yorkshire' = 'British'; 'Cornish' = 'British';
  'Lancashire' = 'British'; 'Devon' = 'British'; 'Texan' = 'American'; 'New England' = 'American'; 'Boston' = 'American';
  'Philly' = 'American'; 'Southern' = 'American'; 'Viennese' = 'Austrian'; 'Tyrolean' = 'Austrian'; 'Bengal' = 'Bengali';
  'Okinawan' = 'Japanese'; 'Balinese' = 'Indonesian'; 'Javanese' = 'Indonesian'; 'Quebec' = 'Canadian'; 'Québécois' = 'Canadian'
}

function Get-CuisineFromName([string]$name) {
  foreach ($k in ($CuisineAliases.Keys | Sort-Object Length -Descending)) {
    if ($name -match ('\b' + [regex]::Escape($k) + '\b')) { return $CuisineAliases[$k] }
  }
  foreach ($k in ($Regions.Keys | Sort-Object Length -Descending)) {
    if ($name -match ('\b' + [regex]::Escape($k) + '\b')) { return $k }
  }
  foreach ($k in $Demonyms.Keys) { if ($name -match ('\b' + [regex]::Escape($k) + '\b')) { return $Demonyms[$k] } }
  return ''
}

# Intros only count as cultural background when they talk about history or tradition.
$CultureRx = '(?i)\b(tradition|traditional|traditionally|history|historic|originat|national dish|festival|celebrat|holiday|' +
  'culture|cultural|heritage|centur|ancient|staple|ritual|ceremon|wedding|christmas|easter|ramadan|eid|diwali|passover|' +
  'hanukkah|new year|lunar|thanksgiving|street food|named after|introduced|immigrant|colonial|peasant|grandmother|generations)'

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

$script:wikiNew = 0
function Save-WikiCache {
  if ($SkipWikipedia) { return }
  New-Item -ItemType Directory -Force (Split-Path $CacheFile) | Out-Null
  [IO.File]::WriteAllText($CacheFile, ($WikiCache | ConvertTo-Json -Depth 5 -Compress), $Utf8)
}

# Looks up one Wikipedia title. Cached results keep the short description so stricter checks can reuse them.
function Get-WikiSummary([string]$title) {
  $key = $title.ToLower()
  if ($WikiCache.ContainsKey($key)) { return $WikiCache[$key] }
  $j = Get-Json ("https://en.wikipedia.org/api/rest_v1/page/summary/" + [Uri]::EscapeDataString(($title -replace ' ', '_')))
  $result = $null
  if ($j -and $j.type -eq 'standard' -and $j.extract) {
    $desc = ('' + $j.description + ' ' + $j.extract).ToLower()
    if ($desc -match "\b($FoodWords)") {
      $result = [ordered]@{
        text   = Clean-Text $j.extract
        source = [ordered]@{ name = 'Wikipedia'; url = $j.content_urls.desktop.page }
        desc   = ('' + $j.description)
      }
    }
  }
  $WikiCache[$key] = $result
  $script:wikiNew++
  if ($script:wikiNew % 50 -eq 0) { Save-WikiCache }
  return $result
}

# Tries the dish name, then simpler forms of it: "Ginger Snaps" -> "Gingersnap", "Tomato Pizza" -> "Pizza",
# "Semmelknoedel (Bavarian Bread Dumplings)" -> "Bread dumplings". Broad fallbacks must be described as food.
function Get-WikiCulture([string]$name) {
  if ($SkipWikipedia -or -not $name) { return $null }
  $base = ($name -replace '\s*\(.*?\)\s*', ' ' -replace '\s+', ' ').Trim()
  $exact = New-Object System.Collections.Generic.List[string]
  $broad = New-Object System.Collections.Generic.List[string]
  $exact.Add($name); $exact.Add($base)
  if ($name -match '\(([^)]+)\)' -and $Matches[1] -match '\s' -and $Matches[1] -notmatch '(?i)^(vegan|vegetarian|gluten|dairy|easy|quick|spicy|mild|optional)') { $exact.Add($Matches[1]) }
  $sing = $base -replace '(?i)ies$', 'y' -replace '(?i)(?<![su])s$', ''
  $exact.Add($sing); $exact.Add(($sing -replace ' ', ''))
  $words = @($base -split ' ' | Where-Object { $_ -and $_ -notmatch '^(with|and|in|of|a|the|style|recipe|easy|quick|homemade|simple|classic|best|my|mom''s|grandma''s)$' })
  if ($words.Count -ge 3) { $broad.Add(($words[-2..-1] -join ' ')) }
  if ($words.Count -ge 2) { $broad.Add($words[-1]); $broad.Add(($words[-1] -replace '(?i)ies$', 'y' -replace '(?i)(?<![su])s$', '')) }
  $tried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($c in $exact) {
    if (-not $c -or -not $tried.Add($c)) { continue }
    $r = Get-WikiSummary $c
    if ($r -and (Test-DishArticle $r)) { return [ordered]@{ text = $r.text; source = $r.source } }
  }
  foreach ($c in $broad) {
    if (-not $c -or $c.Length -lt 4 -or -not $tried.Add($c)) { continue }
    $r = Get-WikiSummary $c
    # A broad guess must land on an article that shares a word with the guess (no "Traybake" -> "Cookie").
    if ($r -and (Test-DishArticle $r) -and $r.desc -match "(?i)\b($FoodWords)" -and (Test-SharedWord $c (Get-WikiTitle $r))) {
      return [ordered]@{ text = $r.text; source = $r.source }
    }
  }
  return $null
}

function Get-WikiTitle($r) {
  $path = ('' + $r.source.url) -replace '^.*/wiki/', ''
  return ([Uri]::UnescapeDataString($path) -replace '_', ' ')
}

function Test-SharedWord([string]$a, [string]$b) {
  $stem = { param($w) ($w.ToLower() -replace '[^a-z]', '' -replace '(ies|es|s)$', '') }
  $wa = @($a -split '\s+' | ForEach-Object { & $stem $_ } | Where-Object { $_.Length -ge 3 })
  $wb = @($b -split '\s+' | ForEach-Object { & $stem $_ } | Where-Object { $_.Length -ge 3 })
  foreach ($x in $wa) { foreach ($y in $wb) { if ($x -eq $y -or ($x.Length -ge 4 -and $y.StartsWith($x)) -or ($y.Length -ge 4 -and $x.StartsWith($y))) { return $true } } }
  return $false
}

# Rejects lists, cookware, plants, places, companies and the like.
function Test-DishArticle($r) {
  $title = Get-WikiTitle $r
  if ($title -match '^(List|Lists|Outline|Index|Glossary) of\b') { return $false }
  $d = '' + $r.desc
  if ($d -and $d -match '(?i)\b(pan|pot|utensil|tool|cookware|appliance|vessel|container|species|genus|cultivar|plant|tree|family of|company|brand|restaurant|chain|film|song|album|band|novel|town|village|city|county|river|mountain|person|politician|philosophy|movement|diet\b|ideology|practice)\b' -and
      $d -notmatch '(?i)\b(dish|food|dessert|pastry|bread|soup|stew|sauce|cake|snack|beverage|drink|salad|confection)\b') { return $false }
  return $true
}

# ---------------------------------------------------------------- output

$recipes = New-Object System.Collections.ArrayList

$seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$DependsRx = '(?i)\b(make|prepare|proceed) (the )?same\b|\bsame as\b|\bas for\b|\bas directed (for|in)\b|\bsee (recipe|page|cookbook|above|below)\b|\bpage \d+|' +
  '\b(preceding|previous|above|following) recipe\b|\brecipe (above|given)\b|\b(given|described) (above|for)\b|\bno\. \d+\b'

# Every source funnels through here: tidy the text, add lifestyle tags, drop exact duplicates.
function Add-Recipe($r, [bool]$TitleCaseItems = $false) {
  $r.name = Fix-Name $r.name
  $key = ($r.name -replace '[^\p{L}\p{N}]', '') + '|' + $r.source.name
  if (-not $seenNames.Add($key)) { return }
  $r.ingredients = @(Fix-Ingredients $r.ingredients $TitleCaseItems)
  $r.steps = @(Fix-Steps $r.steps)
  if ($r.steps.Count -lt 1 -or $r.ingredients.Count -lt 2) { return }
  # Recipes that only make sense next to another recipe ("Make same as Stuffing I") are dropped.
  $method = $r.steps -join ' '
  if ($method.Length -lt 50 -or $method -match $DependsRx) { return }
  # Ingredients like "Batter I, III, or V" or "Sauce II" point at other numbered recipes in old cookbooks.
  if ($r.ingredients | Where-Object { "$($_.qty) $($_.item)" -cmatch '\b[A-Z][a-z]+(\s[A-Z][a-z]+)?\s(I|II|III|IV|V|VI|VII)\b' }) { return }
  if ($r.culture -and $r.culture.text) { $r.culture.text = Fix-Typos $r.culture.text }
  $items = @($r.ingredients | ForEach-Object { $_.item })
  $r['lifestyle'] = Get-LifestyleMask $items $r.allergens $r.diet
  if (-not $r.Contains('era')) { $r['era'] = 'modern' }
  [void]$recipes.Add($r)
}

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
    $qty  = Normalize-Qty $m."strMeasure$i"
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
  if ($cat -eq 'Vegan') { $diet = 3 } elseif ($cat -eq 'Vegetarian' -and $diet -lt 2) { $diet = 2 }
  $country = Clean-Text $m.strCountry
  $cuisine = Get-Cuisine (Clean-Text $m.strArea) $country

  $timing  = Get-Timing $steps $ingredients
  $minutes = $timing.prep + $timing.cook + $timing.passive

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
    allergens   = Get-AllergenMask $items
    minutes     = $minutes
    time        = $timing
    timeEstimated = $true
    servings    = ''
    difficulty  = Get-Difficulty $ingredients.Count $steps.Count ($timing.prep + $timing.cook)
    ingredients = @($ingredients)
    steps       = @($steps)
    tags        = @((('' + $m.strTags) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    youtube     = '' + $m.strYoutube
    culture     = Get-WikiCulture $m.strMeal
    license     = 'TheMealDB'
  }) $true
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
      if (-not $cuisine) { $cuisine = Get-CuisineFromName ($p.title -replace '^Cookbook:', '') }

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
      # Wiki tables put a row's cells either on one line ("| a || b") or one per line,
      # with rows separated by "|-". Collect cells until the row ends.
      $rowCells = New-Object System.Collections.ArrayList
      $flushRow = {
        $cells = @($rowCells | ForEach-Object { Clean-Wiki $_ } |
          Where-Object { $_ -and $_ -notmatch '^[-–—]$|^n/?a$|%\s*$' })
        $rowCells.Clear()
        if ($cells.Count -ge 1 -and $cells[0] -notmatch '^(total|ingredients?)$') {
          $qty = ''
          if ($cells.Count -gt 1) { $qty = Normalize-Qty ($cells[1..($cells.Count - 1)] -join ' / ') }
          $script:ingredientsOut += ,([ordered]@{ item = $cells[0]; qty = $qty })
        }
      }
      $script:ingredientsOut = @()
      foreach ($line in ($sections[$ingKey] -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^\*+\s*(.+)$') {
          $txt = Normalize-Qty (Clean-Wiki $Matches[1])
          if ($txt.Length -gt 1) { $script:ingredientsOut += ,([ordered]@{ item = $txt; qty = '' }) }
        } elseif ($line -match '^\|[-}]' -or $line -match '^\{\|') {
          if ($rowCells.Count) { & $flushRow }
        } elseif ($line -match '^\|' -and $line -notmatch '^\|\s*$') {
          foreach ($c in ($line.TrimStart('|') -split '\|\|')) { [void]$rowCells.Add($c) }
        }
      }
      if ($rowCells.Count) { & $flushRow }
      $ingredients = $script:ingredientsOut
      $steps = @()
      foreach ($line in ($sections[$stepKey] -split "`n")) {
        if ($line.Trim() -match '^[#*]+\s*(.+)$') {
          $txt = Normalize-Qty (Clean-Wiki $Matches[1])
          if ($txt.Length -gt 3) { $steps += $txt }
        }
      }
      if ($steps.Count -lt 2) {
        # Some pages write the method as plain paragraphs instead of a numbered list.
        $steps = @(($sections[$stepKey] -split "`n") | ForEach-Object { Clean-Wiki $_ } |
          Where-Object { $_.Length -gt 25 -and $_ -notmatch '^[{|!]' })
      }
      if ($ingredients.Count -lt 2 -or $steps.Count -lt 1 -or ($steps -join ' ').Length -lt 60) { continue }

      $name = $p.title -replace '^Cookbook:', ''
      $timing = Get-Timing $steps $ingredients
      $stated = Parse-Minutes (Get-TemplateParam $wt 'time')
      $estimated = $stated -le 0
      if ($estimated) {
        $minutes = $timing.prep + $timing.cook + $timing.passive
      } else {
        # Trust the recipe's own total; fit the estimated breakdown inside it.
        $minutes = Round5 $stated
        $hands = $timing.prep + $timing.cook
        if ($hands -ge $minutes) {
          $timing.prep = [int][Math]::Max(5, [Math]::Round($minutes * $timing.prep / [Math]::Max(1, $hands) / 5) * 5)
          $timing.cook = [int][Math]::Max(0, $minutes - $timing.prep)
          $timing.passive = 0; $timing.passiveWhy = @()
        } else {
          $timing.passive = [int][Math]::Min($timing.passive, $minutes - $hands)
          if ($timing.passive -eq 0) { $timing.passiveWhy = @() }
          $timing.cook = [int]($minutes - $timing.prep - $timing.passive)
        }
      }
      $servings = (Clean-Wiki (Get-TemplateParam $wt 'servings')) -replace '[^\w\s\-–/]', ''

      $diffNum = 0
      [void][int]::TryParse((Get-TemplateParam $wt 'difficulty'), [ref]$diffNum)
      if ($diffNum -ge 1) {
        $difficulty = if ($diffNum -le 2) { 'easy' } elseif ($diffNum -eq 3) { 'medium' } else { 'hard' }
      } else {
        $difficulty = Get-Difficulty $ingredients.Count $steps.Count ($timing.prep + $timing.cook)
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
      $culture = Get-WikiCulture $name
      if (-not $culture -and $introText.Length -gt 80 -and $introText -match $CultureRx) {
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
        allergens   = Get-AllergenMask $items
        minutes     = $minutes
        time        = $timing
        timeEstimated = $estimated
        servings    = $servings
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

# ================================================================= shared helpers for file-based sources

$SrcDir = Join-Path $env:TEMP 'fyr-sources'
New-Item -ItemType Directory -Force $SrcDir | Out-Null

function Get-Repo([string]$repo) {
  $dir = Join-Path $SrcDir ($repo -replace '/', '__')
  if (-not (Test-Path (Join-Path $dir '.git'))) {
    & git clone -q --depth 1 "https://github.com/$repo.git" $dir 2>$null
  }
  if (Test-Path $dir) { return $dir }
  Write-Warning "Could not clone $repo"
  return $null
}

function Get-GutenbergText([int]$id) {
  $file = Join-Path $SrcDir "pg$id.txt"
  if (-not (Test-Path $file)) {
    $t = Get-Text "https://www.gutenberg.org/cache/epub/$id/pg$id.txt"
    if (-not $t) { return $null }
    [IO.File]::WriteAllText($file, $t, $Utf8)
  }
  $text = [IO.File]::ReadAllText($file, $Utf8) -replace "`r", ''
  $start = $text.IndexOf('*** START OF'); $end = $text.IndexOf('*** END OF')
  if ($start -ge 0 -and $end -gt $start) { $text = $text.Substring($start, $end - $start) }
  return $text
}

function Course-FromText([string]$t) {
  if ($t -match '(?i)breakfast|pancake|waffle|muffin|porridge|granola|omelet') { return 'breakfast' }
  if ($t -match '(?i)dessert|cake|cookie|biscuit|pudding|pie\b|tart|sweet|candy|confection|ice cream|brownie|fudge|slice') { return 'dessert' }
  if ($t -match '(?i)soup|chowder|broth|bisque|stew') { return 'soup' }
  if ($t -match '(?i)salad|side|snack|bread|dip|appetizer|starter') { return 'side' }
  return 'main'
}

function New-Recipe([hashtable]$f) {
  $items = @($f.ingredients | ForEach-Object { $_.item })
  $diet = Get-Diet $items
  $timing = if ($f.timing) { $f.timing } else { Get-Timing $f.steps $f.ingredients }
  $minutes = $timing.prep + $timing.cook + $timing.passive
  $estimated = -not $f.statedTime
  if ($f.statedTime) { $minutes = Round5 $f.statedTime }
  $cuisine = if ($f.cuisine) { $f.cuisine } else { Get-CuisineFromName $f.name }
  return [ordered]@{
    id = $f.id; name = $f.name; author = $f.author; source = $f.source; via = $f.via; image = $f.image
    cuisine = $cuisine; country = ''; region = Get-Region $cuisine; course = $f.course
    protein = Get-Protein '' $items $diet $f.name; diet = $diet; allergens = Get-AllergenMask $items
    minutes = $minutes; time = $timing; timeEstimated = $estimated; servings = $f.servings
    difficulty = Get-Difficulty $f.ingredients.Count $f.steps.Count ($timing.prep + $timing.cook)
    ingredients = @($f.ingredients); steps = @($f.steps); tags = @(); youtube = ''
    culture = $f.culture; license = $f.license; era = $(if ($f.era) { $f.era } else { 'modern' }); vintage = $f.vintage
  }
}

function Strip-Markdown([string]$s) {
  $s = $s -replace '!\[[^\]]*\]\([^)]*\)', '' -replace '\[([^\]]+)\]\([^)]*\)', '$1' -replace '\*\*|__', '' -replace '(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)', ''
  return Clean-Text $s
}

# ================================================================= based.cooking + public-domain-recipes (public domain)

function Import-MarkdownSite([string]$repo, [string]$siteName, [string]$siteUrl, [string]$idPrefix) {
  $dir = Get-Repo $repo
  if (-not $dir) { return }
  $kept = 0
  foreach ($file in Get-ChildItem (Join-Path $dir 'content') -Filter *.md) {
    if ($file.Name -like '_*') { continue }
    $text = [IO.File]::ReadAllText($file.FullName, $Utf8) -replace "`r", ''
    $fm = [regex]::Match($text, '^---\n(.*?)\n---\n', 'Singleline')
    if (-not $fm.Success) { continue }
    $front = $fm.Groups[1].Value; $body = $text.Substring($fm.Length)
    $title = ([regex]::Match($front, '(?m)^title:\s*"?(.*?)"?\s*$')).Groups[1].Value
    if (-not $script:mdTitles) { $script:mdTitles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
    if ($title -and -not $script:mdTitles.Add($title)) { continue }
    $author = ([regex]::Match($front, '(?m)^author:\s*"?(.*?)"?\s*$')).Groups[1].Value
    $tags = @([regex]::Matches(([regex]::Match($front, '(?m)^tags:\s*\[(.*)\]')).Groups[1].Value, "'([^']+)'|""([^""]+)""") | ForEach-Object { ($_.Groups[1].Value + $_.Groups[2].Value).ToLower() })
    if (-not $title -or $tags -contains 'drink' -or $tags -contains 'sauce' -or $tags -contains 'spice') { continue }

    $section = 'intro'; $intro = @(); $ingredients = @(); $steps = @(); $prep = 0; $cook = 0; $servings = ''; $image = ''
    foreach ($line in ($body -split "`n")) {
      $l = $line.Trim()
      if ($l -match '^##\s+(.*)$') {
        $h = $Matches[1].ToLower()
        $section = if ($h -match 'ingredient') { 'ing' } elseif ($h -match 'direction|instruction|method|step|preparation') { 'steps' } else { 'other' }
        continue
      }
      if ($l -match '!\[[^\]]*\]\(([^)]+)\)' -and -not $image) { $image = $Matches[1]; if ($image -notmatch '^https?:') { $image = $siteUrl.TrimEnd('/') + '/' + $image.TrimStart('/') } }
      if ($l -match '(?i)prep(aration)? time:\s*(.+)$') { $prep = Parse-Minutes $Matches[2]; continue }
      if ($l -match '(?i)cook(ing)? time:\s*(.+)$') { $cook = Parse-Minutes $Matches[2]; continue }
      if ($l -match '(?i)servings?:\s*(.+)$') { $servings = Strip-Markdown $Matches[1]; continue }
      if ($l -match '^#') { continue }
      switch ($section) {
        'intro' { if ($l.Length -gt 30 -and $l -notmatch '^[-*!]') { $intro += Strip-Markdown $l } }
        'ing'   { if ($l -match '^[-*+]\s+(.+)$') { $ingredients += ,([ordered]@{ item = (Normalize-Qty (Strip-Markdown $Matches[1])); qty = '' }) } }
        'steps' { if ($l -match '^(\d+[.)]|[-*+])\s+(.+)$') { $steps += Strip-Markdown $Matches[2] } elseif ($l.Length -gt 30 -and $l -notmatch '^!') { $steps += Strip-Markdown $l } }
      }
    }
    if ($ingredients.Count -lt 2 -or $steps.Count -lt 1) { continue }

    $slug = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $cuisine = ''
    foreach ($t in $tags) { $c = (Get-Culture).TextInfo.ToTitleCase($t); if ($Regions.ContainsKey($c)) { $cuisine = $c; break } }
    $timing = Get-Timing $steps $ingredients
    $stated = 0
    if ($prep -or $cook) { $timing.prep = [int][Math]::Max(5, (Round5 ([Math]::Max($prep, 5)))); $timing.cook = [int]$(if ($cook) { Round5 $cook } else { 0 }); $stated = $timing.prep + $timing.cook + $timing.passive }
    $culture = Get-WikiCulture $title
    $introText = $intro -join ' '
    if (-not $culture -and $introText -match $CultureRx) { $culture = [ordered]@{ text = $introText; source = [ordered]@{ name = $siteName; url = "$siteUrl/$slug/" } } }
    Add-Recipe (New-Recipe @{
      id = "$idPrefix$slug"; name = $title
      author = $(if ($author) { "$author on $siteName" } else { "$siteName contributors" })
      source = [ordered]@{ name = $siteName; url = "$siteUrl/$slug/" }; via = [ordered]@{ name = $siteName; url = $siteUrl }
      image = $image; cuisine = $cuisine; course = (Course-FromText (($tags -join ' ') + ' ' + $title))
      ingredients = $ingredients; steps = $steps; timing = $timing; statedTime = $stated; servings = $servings
      culture = $culture; license = 'Public domain (Unlicense)'
    })
    $kept++
  }
  Write-Host "  kept $kept recipes from $siteName"
}

if (-not $SkipMarkdown) {
  Write-Host 'Public-domain recipe sites...'
  Import-MarkdownSite 'LukeSmithxyz/based.cooking' 'based.cooking' 'https://based.cooking' 'b'
  Import-MarkdownSite 'ronaldl29/public-domain-recipes' 'Public Domain Recipes' 'https://publicdomainrecipes.com' 'p'

  # ---------------------------------------------------------------- Wickham family recipes (CC BY 4.0)
  # Only the family's own recipes: ones copied from books, magazines or websites are skipped.
  $dir = Get-Repo 'hadley/recipes'
  if ($dir) {
    $kept = 0
    $courseByDir = @{ biscuits = 'dessert'; cakes = 'dessert'; desserts = 'dessert'; slices = 'dessert'; sweets = 'dessert';
      breads = 'side'; 'muffins-scones' = 'breakfast'; entrees = 'side' }
    foreach ($file in Get-ChildItem (Join-Path $dir 'recipes') -Recurse -Filter *.md) {
      $folder = $file.Directory.Name
      if ($folder -in @('sauces', 'misc', 'recipes')) { continue }
      $text = [IO.File]::ReadAllText($file.FullName, $Utf8) -replace "`r", ''
      $src = ([regex]::Match($text, '(?im)^source:\s*(.+)$')).Groups[1].Value
      if ($src -and $src -notmatch '(?i)notebook|grandma|nana|mum|mom|aunt|family|wickham|hadley|jeff|rita|granny') { continue }
      $title = ([regex]::Match($text, '(?m)^#\s+(.+)$')).Groups[1].Value
      if (-not $title) { continue }
      $ingredients = @(); $steps = @()
      foreach ($line in ($text -split "`n")) {
        $l = $line.Trim()
        if ($l -match '^#' -or $l -match '(?i)^source:') { continue }
        if ($l -match '^[-*]\s+(.+)$') {
          $it = Strip-Markdown $Matches[1]
          if ($it -cmatch '^[A-Z ]+:$') { continue }        # "CRUNCHY TOPPING:" sub-headings
          $ingredients += ,([ordered]@{ item = (Normalize-Qty ($it -replace '\b(\d+(?:/\d+)?)\s*t\b', '$1 tsp' -replace '\b(\d+(?:/\d+)?)\s*T\b', '$1 tbsp' -replace '\b(\d+(?:/\d+)?)\s*[Cc]\b', '$1 cup')); qty = '' })
        } elseif ($l.Length -gt 15) {
          foreach ($s in [regex]::Split((Strip-Markdown $l), '(?<=[.!?])\s{1,}(?=[A-Z])')) { if ($s.Length -gt 3) { $steps += $s } }
        }
      }
      if ($ingredients.Count -lt 2 -or $steps.Count -lt 1) { continue }
      $rel = $file.FullName.Substring($dir.Length + 1) -replace '\\', '/'
      $course = if ($courseByDir.ContainsKey($folder)) { $courseByDir[$folder] } else { 'main' }
      $url = "https://github.com/hadley/recipes/blob/main/$rel"
      Add-Recipe (New-Recipe @{
        id = 'h' + ($rel -replace '^recipes/', '' -replace '\.md$', '' -replace '[^a-z0-9]+', '-'); name = $title
        author = 'The Wickham family'; source = [ordered]@{ name = 'Wickham family recipes'; url = $url }
        via = [ordered]@{ name = 'GitHub'; url = 'https://github.com/hadley/recipes' }
        image = ''; cuisine = ''; course = $course; ingredients = $ingredients; steps = $steps; servings = ''
        culture = (Get-WikiCulture $title); license = 'CC BY 4.0'
      })
      $kept++
    }
    Write-Host "  kept $kept Wickham family recipes"
  }
}

# ================================================================= Project Gutenberg (public domain, vintage)

$BookNotes = @{
  boston = [ordered]@{ text = 'From The Boston Cooking-School Cook Book (1896) by Fannie Merritt Farmer. It popularized level, standardized measurements (cups and spoons) in American home kitchens, and stayed one of the best-selling cookbooks in the United States for decades.'; source = [ordered]@{ name = 'Project Gutenberg'; url = 'https://www.gutenberg.org/ebooks/65061' } }
  beeton = [ordered]@{ text = "From Mrs Beeton's Book of Household Management (1861) by Isabella Beeton. It was a Victorian best-seller that shaped how British households cooked and ran their kitchens for generations, and it was one of the first cookbooks to list ingredients before the method."; source = [ordered]@{ name = 'Project Gutenberg'; url = 'https://www.gutenberg.org/ebooks/10136' } }
}

function To-TitleCase([string]$s) {
  $t = (Get-Culture).TextInfo.ToTitleCase($s.ToLower())
  $t = $t -replace "'S\b", "'s"
  $t = [regex]::Replace($t, '\b(And|Or|Of|With|In|A|The|To|For|On|Au|À|La|Le|De|En)\b', { param($m) $m.Value.ToLower() })
  return $t.Substring(0, 1).ToUpper() + $t.Substring(1)
}

$VintageSkip = '(?i)sauce|gravy|pickle|ketchup|catsup|vinegar|\bwine\b|\bbeer\b|\bale\b|punch|cordial|preserv|to keep|clarif|\bjam\b|' +
  'marmalade|liqueur|lemonade|syrup|essence|brandy|negus|posset|invalid|beef tea|gruel|panada|toast.and.water|\bstock\b|' +
  'seasoning|powder|forcemeat|force-meat|dressing|frosting|filling|icing|to cure|to dry|to salt|to pot\b|potted|' +
  'tea\b|coffee|cocoa\b|chocolate$|glaze|garnish|caramel$|to boil (water|rice)$|^to |^how to|general|observations|' +
  '^batter|^(plain |puff |flaky |short |rich )?(paste|pastry|crust|dough)( [ivx]+)?$|^mixture|^(white|brown) roux'

if (-not $SkipGutenberg) {
  Write-Host 'Project Gutenberg: The Boston Cooking-School Cook Book (1896)...'
  $text = Get-GutenbergText 65061
  if ($text) {
    $chapterCourse = [ordered]@{
      'BREAD' = 'side'; 'BISCUITS, BREAKFAST' = 'breakfast'; 'CEREALS' = 'breakfast'; 'EGGS' = 'breakfast'; 'SOUPS' = 'soup';
      'FISH' = 'main'; 'BEEF' = 'main'; 'LAMB' = 'main'; 'VEAL' = 'main'; 'SWEETBREADS' = 'main'; 'PORK' = 'main'; 'POULTRY' = 'main';
      'VEGETABLES' = 'side'; 'POTATOES' = 'side'; 'SALADS' = 'side'; 'ENTRÉES' = 'main'; 'HOT PUDDINGS' = 'dessert';
      'COLD DESSERTS' = 'dessert'; 'ICES' = 'dessert'; 'PASTRY' = 'dessert'; 'PIES' = 'dessert'; 'GINGERBREADS' = 'dessert';
      'CAKE' = 'dessert'; 'FANCY CAKES' = 'dessert'; 'SANDWICHES' = 'side'; 'RECIPES FOR THE CHAFING' = 'main'
    }
    $skipChapters = 'BEVERAGES|SOUP GARNISH|SAUCES|FILLINGS|FRUITS|HINTS|COMBINATIONS|^FOOD$|^COOKERY$'
    $lines = $text -split "`n"
    $chapter = ''; $course = $null; $kept = 0
    $i = 0
    while ($i -lt $lines.Count) {
      $line = $lines[$i]
      if ($line -match '^\s*CHAPTER [IVXLC]+\s*$') {
        $j = $i + 1; while ($j -lt $lines.Count -and -not $lines[$j].Trim()) { $j++ }
        $chapter = $lines[$j].Trim(); $course = $null
        foreach ($k in $chapterCourse.Keys) { if ($chapter.StartsWith($k)) { $course = $chapterCourse[$k]; break } }
        if ($chapter -match $skipChapters) { $course = $null }
        $i = $j + 1; continue
      }
      # A recipe: centred title, blank line, centred ingredient lines, then method paragraphs.
      $isTitle = $line -match '^\s{10,}\S' -and $i -gt 0 -and -not $lines[$i - 1].Trim() -and ($i + 1) -lt $lines.Count -and -not $lines[$i + 1].Trim()
      if ($course -and $isTitle) {
        $title = $line.Trim()
        $j = $i + 2; $ings = @()
        while ($j -lt $lines.Count -and $lines[$j] -match '^\s{10,}\S') { $ings += $lines[$j].Trim(); $j++ }
        $method = @(); $para = ''
        while ($j -lt $lines.Count) {
          $l = $lines[$j]
          if ($l -match '^\s{10,}\S' -or $l -match '^\s*CHAPTER [IVXLC]+\s*$') { break }
          if ($l.Trim()) { $para = ($para + ' ' + $l.Trim()).Trim() } elseif ($para) { $method += $para; $para = '' }
          $j++
        }
        if ($para) { $method += $para }
        $i = $j
        if ($ings.Count -lt 2 -or $method.Count -lt 1 -or $title -match $VintageSkip -or $title.Length -gt 60) { continue }
        $method = @($method | ForEach-Object { $_ -replace '=([^=]+)=', '$1' -replace '_([^_]+)_', '$1' })
        $steps = @(); foreach ($p in $method) { foreach ($s in [regex]::Split($p, '(?<=[.!?])\s+(?=[A-Z])')) { if ($s.Length -gt 3) { $steps += $s } } }
        $ingredients = @($ings | ForEach-Object { ,([ordered]@{ item = (Normalize-Qty $_); qty = '' }) })
        $id = 'g' + ($title.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        Add-Recipe (New-Recipe @{
          id = "${id}-1896"; name = $title; author = 'Fannie Merritt Farmer (1896)'
          source = [ordered]@{ name = 'The Boston Cooking-School Cook Book'; url = 'https://www.gutenberg.org/ebooks/65061' }
          via = [ordered]@{ name = 'Project Gutenberg'; url = 'https://www.gutenberg.org/ebooks/65061' }
          image = ''; cuisine = 'American'; course = $course; ingredients = $ingredients; steps = $steps; servings = ''
          culture = $BookNotes.boston; license = 'Public domain'; era = 'vintage'
          vintage = [ordered]@{ year = 1896; book = 'The Boston Cooking-School Cook Book' }
        })
        $kept++
        continue
      }
      $i++
    }
    Write-Host "  kept $kept recipes"
  }

  Write-Host "Project Gutenberg: Mrs Beeton's Book of Household Management (1861)..."
  $text = Get-GutenbergText 10136
  if ($text) {
    $kept = 0
    # Each recipe: an UPPERCASE title line, then "123. INGREDIENTS.--...", "_Mode_.--...", "_Time_.--...", "_Sufficient_ for ..."
    $rx = '(?ms)^\s*([A-Z][A-Z0-9 ,''\-&()\.À-Ý]{3,80}?)\.?\s*\n\s*\n\s*(\d+)\.\s*INGREDIENTS\.?\s*--\s*(.*?)\n\s*\n\s*_?Mode_?\.?\s*--\s*(.*?)(?=\n\s*\n\s*_?(?:Time|Average cost|Sufficient|Seasonable|Note)_?\b|\n\s*\n\s*[A-Z][A-Z ,''\-]{3,}\.?\s*\n)(.*?)(?=\n\s*\n\s*[A-Z][A-Z0-9 ,''\-&()]{3,80}\.?\s*\n\s*\n\s*\d+\.|\z)'
    foreach ($m in [regex]::Matches($text, $rx)) {
      $title = To-TitleCase ($m.Groups[1].Value.Trim().TrimEnd('.'))
      if ($title -match $VintageSkip -or $title.Length -lt 3) { continue }
      $ingText = Clean-Text ($m.Groups[3].Value -replace '_', '')
      $ingText = $ingText -replace '^(?i)(for|to) [^,;]*?(allow|take|use)\s+', ''
      $ingredients = @([regex]::Split($ingText, '[;,]\s+(?=(?:\d|½|¼|¾|a |an |the |some |sufficient|salt|pepper|[A-Z]|[a-z]+ (?:of|to)\b))') |
        ForEach-Object { ($_ -replace '^(and|with)\s+', '').Trim(' ', '.', ';', ',') } | Where-Object { $_.Length -gt 1 } |
        ForEach-Object { ,([ordered]@{ item = (Normalize-Qty ($_ -replace '\b(oz|lb|lbs|pt|qt)\.', '$1')); qty = '' }) })
      $mode = Clean-Text ($m.Groups[4].Value -replace '_', '')
      $steps = @([regex]::Split($mode, '(?<=[.!?])\s+(?=[A-Z])') | Where-Object { $_.Length -gt 3 })
      $rest = $m.Groups[5].Value
      $stated = Parse-Minutes (([regex]::Match($rest, '(?i)_?Time_?\.?\s*--\s*([^\n_]+)')).Groups[1].Value)
      $servings = ([regex]::Match($rest, '(?i)_?Sufficient_?\s*(?:for)?\s*([^\n_.]+)')).Groups[1].Value.Trim()
      if ($ingredients.Count -lt 2 -or $steps.Count -lt 1) { continue }
      $timing = Get-Timing $steps $ingredients
      if ($stated -gt 0) {
        $hands = $timing.prep + $timing.cook
        if ($hands -ge $stated) { $timing.cook = [int][Math]::Max(0, (Round5 $stated) - $timing.prep); $timing.passive = 0; $timing.passiveWhy = @() }
        else { $timing.passive = [int][Math]::Min($timing.passive, $stated - $hands); $timing.cook = [int]((Round5 $stated) - $timing.prep - $timing.passive) }
        if ($timing.cook -lt 0) { $timing.prep = Round5 $stated; $timing.cook = 0 }
      }
      Add-Recipe (New-Recipe @{
        id = "mb$($m.Groups[2].Value)"; name = $title; author = 'Isabella Beeton (1861)'
        source = [ordered]@{ name = "Mrs Beeton's Book of Household Management"; url = 'https://www.gutenberg.org/ebooks/10136' }
        via = [ordered]@{ name = 'Project Gutenberg'; url = 'https://www.gutenberg.org/ebooks/10136' }
        image = ''; cuisine = 'British'; course = (Course-FromText $title); ingredients = $ingredients; steps = $steps
        timing = $timing; statedTime = $stated; servings = ($servings -replace '(?i)^for\s+', '')
        culture = $BookNotes.beeton; license = 'Public domain'; era = 'vintage'
        vintage = [ordered]@{ year = 1861; book = "Mrs Beeton's Book of Household Management" }
      })
      $kept++
    }
    Write-Host "  kept $kept recipes"
  }
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
    t = $r.minutes; h = $r.time.prep + $r.time.cook; d = $r.difficulty; v = $r.diet; x = $r.allergens
    y = $r.lifestyle; e = $(if ($r.era -eq 'vintage') { 1 } else { 0 })
  })
}
$meta = [ordered]@{ generated = (Get-Date).ToString('yyyy-MM-dd'); count = $index.Count; recipes = @($index) }
[IO.File]::WriteAllText((Join-Path $OutDir 'index.json'), ($meta | ConvertTo-Json -Depth 5 -Compress), $Utf8)

if (-not $SkipWikipedia) {
  New-Item -ItemType Directory -Force (Split-Path $CacheFile) | Out-Null
  [IO.File]::WriteAllText($CacheFile, ($WikiCache | ConvertTo-Json -Depth 5 -Compress), $Utf8)
}

Write-Host "Done: $($index.Count) recipes written to data/"
