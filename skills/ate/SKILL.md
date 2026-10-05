---
name: ate
description: Log food to your FatSecret diary from a plain-English sentence, and show the day's running totals. Use when the user says /ate, "log <food>", "I ate <food>", "add <food> to my diary", asks what they've eaten today, wants a diary entry removed, or wants a custom food created from a nutrition label, or asks how many calories are in a food they have not eaten yet ("how many calories in a slice of X"). Argument = what they ate, e.g. /ate two eggs and a whopper jr.
---
<!-- needs: a fatsecret.com account, a FatSecret Platform API app (consumer key + OAuth 1 secret) with Premier Free access for foods.search.v3, Python 3. -->
<!-- one-time: python3 fs_auth.py (browser + PIN) stores the access token. No hardware. -->

# Log food to FatSecret

Turn a sentence into diary entries. The API has **no freehand calorie form**:
every entry is a `food_id` + a `serving_id` + a number of units, so the whole
job is resolving words to those ids and getting the serving right.

All calls go through `fs_log.py` next to this file. Writes land on
fatsecret.com, which the phone app reads within seconds. **Never** hand-roll a
signed request; never print credentials.

## Setup (once)

1. Register an app at platform.fatsecret.com. Note the **Consumer Key** and the
   **OAuth 1.0 Shared Secret**. The OAuth 2 Client Secret on the same page is a
   different value and will not work here.
2. Put them in the environment, or in `~/.config/fatsecret.env` (mode 600):
   `FATSECRET_CONSUMER_KEY=...` and `FATSECRET_CONSUMER_SECRET=...`
   (`FS_ENV_FILE` overrides that path.)
3. Run `python3 fs_auth.py` in a terminal. Approve in the browser, paste the
   PIN. It appends the access token and secret to that file. Nothing secret is
   printed.

**If every call says "Invalid signature", fingerprint the stored values before
debugging the protocol.** Two days went into OAuth signing once; the real cause
was the Consumer Key pasted into the secret slot (both are 32 lower-hex and sit
next to each other on the dashboard). Compare lengths and a hash prefix of the
two values, never the values themselves.

## The loop, per item

1. **`search "<term>"`**: search the words the user used. This is Premier
   `foods.search.v3`: it returns each food's **full serving list inline**, so
   one call gives the `food_id`, every `serving_id`, and per-serving macros.
   There is normally no second lookup. Brand named ("whopper jr"): expect a
   `[Brand]` hit. No brand: prefer a `Generic` result; those are USDA and have
   sane natural-unit servings.
2. **Pick the serving that matches how they said it.** "two eggs" against a
   `2 eggs` serving is 1 unit, not 2. Against a `1 egg` serving it is 2 units.
   Getting this backwards doubles or halves the day and is the easiest mistake
   here; restate the arithmetic to yourself before logging. **A serving is
   not a slice or a piece:** a medium Domino's pizza is served as `1/5 pizza`
   but cut into 8. Read the `description` column every time; never assume the
   count they said maps to units 1:1.
3. **`log --food-id X --serving-id Y --units N`**: add `--meal` only if they
   named one, `--date yesterday` if they said so. Meal otherwise comes from the
   clock (Breakfast <11, Lunch <16, Dinner <22, else Other).

Then run **`day`** once at the end and report the new total, not each entry.

**`barcode <code>`** replaces step 1 when the user reads out or scans a
UPC/EAN: same output shape, straight to the food. A 12-digit UPC-A is
zero-padded to GTIN-13 for you.

⚠ **A wrong barcode returns a wrong food, not an error.** `0000000000000`
answers with a Greek yogurt, confidently. So always say which food the code
resolved to *before* logging it, and if it does not plausibly match what they
were holding, treat it as a miss and ask. A digit misread off a can is the
normal case, and this is the one path where a silent wrong match looks exactly
like a right one.

⚠ **A gram serving's unit is ONE GRAM, not the serving.** Check the serving's
own `number_of_units` before computing: `100 g` on a USDA food usually carries
`number_of_units: 100`, so `--units 1.69` writes **1.69 grams**, not 169 g.
It logged 4 kcal instead of 439 and looked like a normal entry in `day`.
Prefer an `oz` or natural-unit serving (`number_of_units: 1`), where one unit
really is one serving; if you must use the gram serving, pass the gram count.

**`get <food_id>`** is only for starting from a bare id (one from a previous
day's entry, say). Don't call it after a search: the servings are already
in hand, and never reuse a `serving_id` across foods.

## Calorie checks: answering without writing

"How many calories in X?" is a question, not a log. Search, report, stop, and
offer to log in one line. The user names a quantity when they want it written.

Report in **the unit they asked about**, not the unit the database happens to
use, and show the conversion when they differ; that arithmetic *is* the
answer. Per slice on a medium Domino's is `420 × 5 ÷ 8 = 262`, because the
serving is `1/5 pizza` and the pie is cut into 8.

**Name the product the number came from whenever it is not the one they asked
about.** The only live Domino's pepperoni entry is *Ultimate* Pepperoni, the
double-pepperoni pie; quoting it for a plain pepperoni overstates by about 20%.

## When nothing matches: creating a food

`create` adds a custom food, which is then searchable and loggable forever. Use
it for a packaged item the database does not have, when **the user has the
label**.

⚠ **Only ever create from numbers the user supplies**: a panel they read out,
a photo of the box, values they type. **Never from your own estimate of what a
food probably contains.** An invented food is worse than an unlogged meal: it
is a wrong number written into the diary *and* permanent pollution of the
user's food search, and afterwards it is indistinguishable from a real entry.
If there is no label, log the closest generic match instead and say that is
what you did.

⚠ **There is no delete and no edit.** `food.create` exists; `food.delete` and
`food.edit` do not. A typo in the name, or a duplicate, is there for good.

**Work the ladder before concluding the database lacks it:**

1. **Re-search in the brand's own naming pattern.** Chains are entered to a
   fixed template (`Ultimate Pepperoni Pizza - Hand Tossed - Medium`), so
   search `<brand> <crust> <size>` with `-n 20` and read the whole list. What
   looks like a missing food is usually a missing spelling.
2. **Web-search the chain's published figure.** It settles the number, and a
   `create` would need it anyway.
3. **Then create**, if there is a label.

⚠ **Archived foods exist, and the API cannot see them.** A web search will
sometimes surface a fatsecret.com page for a food `foods.search.v3` refuses to
return; those listings are archived ("outdated or no longer available").
Treat the number as a cross-check only: it has no `food_id` you can log, and
it describes a product that may not be sold any more.

So the sequence is always:

1. **`create ... --dry-run`** first: it sends nothing and prints the exact
   call. Read the values back to the user against the label before the real run.
2. **`create ...`** for real. It refuses if that brand + name already exists
   and shows the existing food instead, which is the one to log against.
3. It prints the new `food_id` and its `serving_id`; **`log`** with those.

`--name` is the item name **without** the brand ("Cinnamon Almonds", not
"Acme Nut Company Cinnamon Almonds"); FatSecret joins the two itself.
Required: `--name --brand --serving-size --calories --fat --carbs --protein`.
`--serving-size` is how one serving reads on the box ("1 oz (30 g)", "2 bars").
Add `--serving-amount 30` for the metric weight of that serving, and whatever
else the panel gives (`--sodium --fiber --sugar --added-sugars --saturated-fat
--cholesterol --calcium --iron` …, `--help` lists them with their units; note
they are API units, e.g. vitamin A in mcg, not the label's %DV). Leave out
anything the label does not show; only the four macros are required.

Restaurant items take `--brand-type restaurant`, store brands `supermarket`;
the default is `manufacturer`.

## When to just do it, and when to ask

Log without asking when the match is unambiguous: they named a brand and the
brand result is exact, or it is a plain generic food with an obvious serving.
Report what you logged in one line per item, with the kcal you actually wrote.
That number is the real safety net: a serving-arithmetic slip shows up there,
so never report a rounded or remembered figure, only what `log` echoed back.

**When it is a genuine choice, use `AskUserQuestion`** rather than a paragraph
of candidates. Two cases deserve it:

- **Which food**: several plausible hits ("whopper jr" vs "whopper jr with
  cheese", or four brands of the same thing). One option per candidate, up to
  4, labelled with the food name and brand; put the per-serving kcal in the
  description so the choice is decidable at a glance.
- **Which serving**: the food resolved but the amount did not map cleanly
  ("a bowl of chili" against `1 cup` / `100 g` servings). Options are the
  servings, described with their kcal and the units that would be written.

Don't ask about a food you already resolved cleanly, and don't ask twice for
one item. Ask in prose instead when there is nothing to choose *between*.

Undo is cheap and that is what makes logging-without-asking safe: `day` lists
every `entry_id`, and `delete <entry_id>` removes one. Offer it if a number
looks off.

## Catalog lessons that each cost a re-log

**A serving is not a piece. Read the `description` column every time.**

- **Wingstop's `1 serving` is ONE WING**, not the order. A 10 pc is 10 units,
  and flavour matters: a 40 kcal/wing spread is 400 across the order.
- **Domino's medium is served as `1/5 pizza` but cut into 8.** Their New York
  Style is cut into **6**, not 8; using an 8-slice number undercounts a half
  pizza by a quarter. A **14" is the Large**; a **12" is the Medium**.
- **Draft vs bottled is the SAME LIQUID.** Only volume matters, so a tap pour
  scales off a bottle entry. If the DB's `1 bottle` is 11.2 oz and the pour is
  12 oz, scale the units by 12/11.2. A pint is 16 oz: **ask which**.
- **Takeout containers: a pint is 2 cups, a quart is 4.** People think in
  containers, so convert out loud.

**ISOLATE A COMPONENT BY SUBTRACTING TWO PUBLISHED ITEMS FROM THE SAME SOURCE.**
This is the highest-value trick in this skill and it replaces guessing entirely.
When the user removes or swaps one part of a composed item, find two figures
from ONE publisher that differ only in that part; the difference IS the part.

- **Jersey Mike's #14 Veggie**: Regular 950 − Bowl (no bread) 640 = **white roll
  310**. Their GF regular roll is published at 240, so going gluten-free saves
  70. Nothing estimated.
- **McDonald's Sausage McMuffin** 400: the published *no cheese* variant is 320
  (cheese **80**) and the *no butter* variant 380 (butter **20**), so no-cheese
  no-butter = **300**.
- **Burger King**: `Whopper Jr.` 340 and `Whopper Jr. with Cheese` 380, so
  "whopper jr no cheese" needs NO adjustment. Check for a with-cheese sibling
  before deducting anything.

The same-source rule matters: a delta taken across two publishers measures their
methodology difference, not the ingredient.

⚠ **A published figure that equals the Atwater sum of its own macros is DERIVED,
not measured.** Five Guys' Cheeseburger is quoted at 840 across many trackers
and at **980** on fiveguys.com. 55f x 9 + 40c x 4 + 47p x 4 = **843**: the 840
is just arithmetic on the macro panel, which is why so many sites agree on it.
**Run the 4/4/9 check whenever two sources disagree**; the one that is NOT the
Atwater sum is the real published number.

**When a package or a chain states its own calories, that beats the database
entry.** Scale units to hit the stated number and say the macros are the
entry's ratio.

**Duplicate brand listings exist and disagree silently.** Burger King's
`Original Chicken Sandwich` has two entries, 660 and 680, same name. Ask which
the user wants once, then stay consistent with that choice.

**Chains publish only their specialty items.** Domino's entire FatSecret set is
specialty pizzas: there is no plain cheese or plain pepperoni, because
build-your-own does not exist in their own nutrition data. For a build-your-own,
searching harder never works: sum the chain's published per-component figures
(crust + sauce + cheese + topping) from their nutrition guide. That is sourced
data, not an estimate, and creating a food from it is legitimate.

**A chain's own live menu beats every third-party tracker.** One chain's site
listed a side at 300 kcal while three trackers and an old FatSecret entry all
said 100; they traced to one stale licensed feed. A chain's own ranges can be
internally inconsistent too, so **quote the range for the size actually
ordered**, not a scaled smaller one.

**Sauces and dips are invisible and large.** 2 oz of blue cheese dressing is
about 286 kcal and 29 g fat. Log them; they never feel like food.

## Reuse, and why a near-duplicate food is worse than odd units

**Keep a private ledger** (e.g. `LEDGER.md` beside this skill, not committed
anywhere public) of every food you resolve: `food_id`, `serving_id`, and the
unit arithmetic you settled. Most of what people eat repeats, and some foods
take several web fetches to settle against a chain's own menu. Check it before
searching and add to it every time.

**When a figure needs correcting, scale units against the EXISTING food rather
than creating a corrected one.** There is no `food.delete` and no `food.edit`,
so a second near-identical entry pollutes the search forever. A recipe whose
honey was corrected from 2 tbsp to 5 tsp gets logged as `0.9406` of the
existing jar, not as a new food. The diary line looks odd and the calories are
right, which is the correct trade. Say the macros are the entry's ratio when
you do this.

**A "helping" is not a serving.** Ask which, or offer the cup and the USDA
serving as options; on a casserole they can differ by 80 kcal each. **A
"handful" of small candy needs a count.**

## Two traps that are about the CLOCK, not the food

⚠ **The local date can roll over mid-conversation.** A question left open past
midnight means the default date is now tomorrow. **Run `date` before logging**
whenever a turn has been sitting, and pass `--date yesterday --meal Dinner`
explicitly for the meal that has already happened. This has bitten twice.

⚠ **A network timeout on `log` may or may not have written.** The API call can
fail at the TLS handshake (nothing sent) or after the write. **Always run `day`
before retrying**; never retry blind, or a slow day becomes a doubled entry.

## Rules

- **Local dates only.** The script computes `date_int` from the local date.
  Never pass a UTC-derived day: in US Eastern time, after 20:00 that files
  dinner under tomorrow.
- **Multiple items = multiple `log` calls.** One entry per food, the way the
  app does it, so each is separately deletable.
- **Restaurant items are `Brand` foods** and usually have a single
  `1 serving` serving. That is normal, not a search failure.
- **Don't invent a food.** See "When nothing matches", above.
- **Search depends on the Premier Free tier.** `foods.search.v3`, barcode
  lookup and autocomplete all need it. If search starts failing with an API
  error, suspect the tier before suspecting the query.
- Read-only questions about the DIARY ("what have I eaten today?") are just
  `day` / `day yesterday`. No writes.
- Read-only questions about a FOOD are a search; see "Calorie checks". Still
  no writes.

## Commands

```
fs_log.py search "<term>" [-n 3]      # servings included
fs_log.py barcode <upc/ean>
fs_log.py get <food_id>               # only from a bare id
fs_log.py log --food-id X --serving-id Y --units N \
      [--meal Breakfast|Lunch|Dinner|Other] [--date today|yesterday|YYYY-MM-DD] [--name "label"]
fs_log.py day [today|yesterday|YYYY-MM-DD|<date_int>] [--json]
fs_log.py delete <food_entry_id>
fs_log.py create --name "<item, no brand>" --brand "<brand>" \
      --serving-size "1 oz (30 g)" --calories N --fat N --carbs N --protein N \
      [--serving-amount 30] [--brand-type manufacturer|restaurant|supermarket] \
      [--sodium N --fiber N --sugar N ...] --dry-run   # drop --dry-run to write
fs_log.py profile                     # goal, last weigh-in, how stale
fs_log.py weight [--set N]            # weigh-in history, or record one
```
