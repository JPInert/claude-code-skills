#!/usr/bin/env python3
"""Read and write your FatSecret food diary from the command line.

Thin subcommands over the legacy `server.api` endpoint, meant to be driven by
the `ate` skill: Claude turns "two eggs and a whopper jr" into search terms,
picks foods and servings, and calls `log`. Nothing here guesses at a match --
that judgement lives in the skill, so the same commands stay useful by hand.

    ./fs_log.py search "scrambled eggs"
    ./fs_log.py barcode 049000006346
    ./fs_log.py log --food-id 39866 --serving-id 40472 --units 1
    ./fs_log.py day
    ./fs_log.py delete 24693532101
    ./fs_log.py create --name ... --dry-run   # custom food

Search uses the Premier `foods.search.v3` method (Premier Free tier), which
returns each food's full serving list inline -- one call, not search-then-get.

Every call is OAuth 1 signed with the stored access token. Credentials are
never printed. Writes go straight to fatsecret.com, which the phone app syncs
from within seconds -- there is no Health Connect lag on this path.
"""

import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fs_auth import load_env, oauth_call  # noqa: E402

API = "https://platform.fatsecret.com/rest/server.api"

# Optional: a status line (or anything else) can read today's totals from here
# rather than making a signed call on every redraw. `day` writes it (the fetch
# it already did), and any write to the diary drops it, since a write is the
# one event that is certain to make it wrong. Set FS_DAY_CACHE to move it.
CACHE = os.path.expanduser(os.environ.get("FS_DAY_CACHE", "~/.cache/fatsecret_day.json"))

# FatSecret's own labels; anything else is rejected server-side.
MEALS = ["Breakfast", "Lunch", "Dinner", "Other"]

# food.create.v2's brand_type. The docs call it required; the first custom food
# was created without it and still got a 200, so the server has a default --
# send it anyway rather than depending on an undocumented one.
BRAND_TYPES = ["manufacturer", "restaurant", "supermarket"]

# The optional half of food.create.v2's nutrition panel, in label order, with
# the unit the API wants (which is not always the unit on the label -- vitamin
# A is micrograms here, %DV on the box). Anything left out is simply absent
# from the food; only the four macros are required.
EXTRA_NUTRIENTS = [
    ("calories_from_fat", "kcal"), ("saturated_fat", "g"),
    ("polyunsaturated_fat", "g"), ("monounsaturated_fat", "g"),
    ("trans_fat", "g"), ("cholesterol", "mg"), ("sodium", "mg"),
    ("potassium", "mg"), ("fiber", "g"), ("sugar", "g"),
    ("added_sugars", "g"), ("vitamin_d", "mcg"), ("vitamin_a", "mcg"),
    ("vitamin_c", "mg"), ("calcium", "mg"), ("iron", "mg"),
]


def api(env, method, **params):
    """One signed call. Returns parsed JSON, or exits on an API error object."""
    body = oauth_call(
        API,
        env["FATSECRET_CONSUMER_KEY"], env["FATSECRET_CONSUMER_SECRET"],
        token=env["FATSECRET_ACCESS_TOKEN"],
        token_secret=env["FATSECRET_ACCESS_SECRET"],
        extra={"format": "json", "method": method, **params},
        raw=True, raise_on_error=False,
    )
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        sys.exit(f"{method}: non-JSON response\n{body[:500]}")
    if "error" in data:
        e = data["error"]
        sys.exit(f"{method}: API error {e.get('code')} -- {e.get('message')}")
    return data


def cache_write(payload):
    """Refresh the statusline cache from a fetch that already happened."""
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, CACHE)
    except OSError:
        pass  # a statusline nicety must never break a diary command


def cache_drop():
    """Invalidate after a write, so the next redraw refetches immediately.

    The stamp goes too: it rate-limits refresh ATTEMPTS, so leaving it behind
    would suppress the respawn for the rest of the TTL -- the statusline would
    keep rendering a number it knows nothing arrived to replace.
    """
    for path in (CACHE, CACHE + ".stamp"):
        try:
            os.remove(path)
        except OSError:
            pass


def today_int():
    """date_int is days since epoch, computed from the LOCAL date.

    Using UTC here rolls the day over at 20:00 EDT and files the evening's
    dinner under tomorrow."""
    return (datetime.date.today() - datetime.date(1970, 1, 1)).days


def parse_date(s):
    """Accept a date_int, an ISO date, or the words today/yesterday."""
    if s is None or s == "today":
        return today_int()
    if s == "yesterday":
        return today_int() - 1
    if s.isdigit() and len(s) <= 6:
        return int(s)
    d = datetime.date.fromisoformat(s)
    return (d - datetime.date(1970, 1, 1)).days


def as_list(x):
    """FatSecret collapses a one-element list into a bare object.

    Callers must reach the container with `(d.get(k) or {})`: a day with
    nothing logged comes back as an explicit `"food_entries": null`, not as a
    missing key, and an empty day is a fact to report -- never an error."""
    if x is None:
        return []
    return x if isinstance(x, list) else [x]


def default_meal():
    """Meal from the clock, so the common case needs no flag."""
    h = datetime.datetime.now().hour
    if h < 11:
        return "Breakfast"
    if h < 16:
        return "Lunch"
    if h < 22:
        return "Dinner"
    return "Other"


def fmt_serving(sv, indent="    "):
    return (f"{indent}{sv['serving_id']:>11}  "
            f"{float(sv.get('calories', 0)):>6.0f} "
            f"{float(sv.get('carbohydrate', 0)):>6.1f} "
            f"{float(sv.get('protein', 0)):>6.1f} "
            f"{float(sv.get('fat', 0)):>6.1f}  "
            f"{sv.get('serving_description', '')}")


SERVING_HEAD = f"    {'serving_id':>11}  {'kcal':>6} {'carb':>6} {'prot':>6} {'fat':>6}  description"


def show_food(f):
    """One food plus every serving it has -- enough to log from, no second call."""
    brand = f.get("brand_name")
    print(f"{f['food_id']:>10}  {f['food_name']}"
          + (f" [{brand}]" if brand else "")
          + f"  ({f.get('food_type', '')})")
    print(SERVING_HEAD)
    for sv in as_list((f.get("servings") or {}).get("serving")):
        print(fmt_serving(sv))


def cmd_search(env, a):
    """Premier `foods.search.v3` carries the full serving list inline, so a
    match and its serving_ids come back in ONE call -- `get` is only needed
    when starting from a bare food_id."""
    d = api(env, "foods.search.v3", search_expression=a.term,
            max_results=str(a.max_results), region="US")
    foods = as_list(((d.get("foods_search") or {}).get("results") or {}).get("food"))
    if not foods:
        print("(no matches)")
        return
    for f in foods:
        show_food(f)


def cmd_barcode(env, a):
    """UPC/EAN -> food. FatSecret wants GTIN-13, so a 12-digit UPC-A needs a
    leading zero; without it the lookup silently finds nothing."""
    code = a.code.strip().zfill(13)
    d = api(env, "food.find_id_for_barcode", barcode=code)
    fid = (d.get("food_id") or {}).get("value")
    if not fid or fid == "0":
        print(f"(no food for barcode {code})")
        return
    show_food(api(env, "food.get.v2", food_id=fid)["food"])


def cmd_get(env, a):
    show_food(api(env, "food.get.v2", food_id=a.food_id)["food"])


def cmd_log(env, a):
    params = {
        "food_id": a.food_id,
        "serving_id": a.serving_id,
        "number_of_units": str(a.units),
        "meal": a.meal or default_meal(),
        "date": str(parse_date(a.date)),
    }
    if params["meal"] not in MEALS:
        sys.exit(f"meal must be one of {', '.join(MEALS)}")
    # food_entry_name is required by the API on every create -- when it is
    # left out the call fails with error 101, so fall back to the food's own
    # name rather than making the caller repeat it.
    params["food_entry_name"] = a.name or api(
        env, "food.get.v2", food_id=a.food_id)["food"]["food_name"]
    d = api(env, "food_entry.create", **params)
    entry_id = d["food_entry_id"]["value"]
    cache_drop()
    print(f"logged food_entry_id={entry_id}  {params['food_entry_name']} "
          f"({params['number_of_units']} x serving {a.serving_id}, "
          f"{params['meal']}, date_int {params['date']})")


def find_existing(env, brand, name):
    """An already-created food with this exact brand and name, or None.

    The match is on the whole name so near-misses ("Cinnamon Almonds" vs
    "Roasted Cinnamon Almonds") still get created -- this catches re-running
    the same create, not similar foods."""
    d = api(env, "foods.search.v3", search_expression=f"{brand} {name}",
            max_results="10", region="US")
    wanted = {name.strip().lower(), f"{brand} {name}".strip().lower()}
    for f in as_list(((d.get("foods_search") or {}).get("results") or {}).get("food")):
        if (f.get("brand_name", "").strip().lower() == brand.strip().lower()
                and f.get("food_name", "").strip().lower() in wanted):
            return f
    return None


def cmd_create(env, a):
    """Create a custom food, for a label with no match in the database.

    THIS CANNOT BE UNDONE. The API has `food.create` but no `food.delete` and
    no `food.edit` (checked against the method list), so a typo or
    a duplicate is permanent and shows up in every future search. Hence
    --dry-run, which sends nothing, and the duplicate check below."""
    if a.brand_type not in BRAND_TYPES:
        sys.exit(f"--brand-type must be one of {', '.join(BRAND_TYPES)}")

    params = {
        "brand_type": a.brand_type,
        "brand_name": a.brand,
        # food_name EXCLUDES the brand -- FatSecret joins the two for display.
        # The one food created before this subcommand existed passed the brand
        # in both slots and now reads "Jonny Almond Nut Company Cinnamon
        # Almonds [Jonny Almond Nut Company]" forever. Don't repeat that.
        "food_name": a.name,
        "serving_size": a.serving_size,
        "calories": str(a.calories),
        "fat": str(a.fat),
        "carbohydrate": str(a.carbohydrate),
        "protein": str(a.protein),
        "region": "US",
    }
    # The metric weight of one serving. The documented names are these; the
    # first create sent `metric_serving_amount`/`metric_serving_unit` (v1-era)
    # and the stored record carries NEITHER field -- they were dropped in
    # silence, and only the grams inside the serving_size TEXT survived.
    if a.serving_amount is not None:
        params["serving_amount"] = str(a.serving_amount)
        params["serving_amount_unit"] = a.serving_amount_unit
    for key, _unit in EXTRA_NUTRIENTS:
        v = getattr(a, key)
        if v is not None:
            params[key] = str(v)

    if a.dry_run:
        print("dry run -- would send food.create.v2 (nothing sent):")
        for k in sorted(params):
            print(f"  {k:<22} {params[k]}")
        return

    if not a.force:
        hit = find_existing(env, a.brand, a.name)
        if hit:
            print("already created -- log against this instead "
                  "(--force to create a second copy anyway):")
            show_food(hit)
            sys.exit(1)

    d = api(env, "food.create.v2", **params)
    fid = (d.get("food_id") or {}).get("value")
    if not fid:
        sys.exit(f"food.create.v2 returned no food_id: {json.dumps(d)[:300]}")
    print(f"created food_id={fid}  {a.name} [{a.brand}]")
    try:
        f = api(env, "food.get.v2", food_id=fid)["food"]
    except SystemExit:
        # The food exists either way; losing the read-back must not lose the id.
        print(f"  (read-back failed -- run `get {fid}` for its serving_id)")
        return
    show_food(f)
    # Whether serving_amount survives is UNPROVEN -- its v1-era spelling was
    # dropped in silence, and the serving table above looks identical either
    # way. Say which it was, so the first real create settles it.
    sv = (as_list((f.get("servings") or {}).get("serving")) or [{}])[0]
    if sv.get("metric_serving_amount"):
        print(f"    metric serving: {sv['metric_serving_amount']} "
              f"{sv.get('metric_serving_unit', '')}")
    elif a.serving_amount is not None:
        print("    (no metric serving stored -- serving_amount was dropped too)")


def cmd_day(env, a):
    date_int = parse_date(a.date)
    when = datetime.date(1970, 1, 1) + datetime.timedelta(days=date_int)
    d = api(env, "food_entries.get.v2", date=str(date_int))
    entries = as_list((d.get("food_entries") or {}).get("food_entry"))
    tot = {"calories": 0.0, "carbohydrate": 0.0, "protein": 0.0, "fat": 0.0}
    for e in entries:
        for k in tot:
            tot[k] += float(e.get(k, 0) or 0)

    # An empty day is 0 kcal, which is a fact -- neither the cache nor a caller
    # may read a missing total as a failed fetch.
    totals = {
        "date_int": date_int, "date": when.isoformat(),
        "entries": len(entries), "kcal": round(tot["calories"]),
        "carb": round(tot["carbohydrate"], 1),
        "prot": round(tot["protein"], 1), "fat": round(tot["fat"], 1),
    }
    if date_int == today_int():
        cache_write(totals)

    if a.json:
        print(json.dumps(totals))
        return

    print(f"{when.isoformat()}  (date_int {date_int})")
    if not entries:
        print("  (nothing logged)")
        return
    print(f"  {'entry_id':>11}  {'meal':<9} {'kcal':>6} {'carb':>6} {'prot':>6} {'fat':>6}  name")
    for e in entries:
        print(f"  {e['food_entry_id']:>11}  {e.get('meal', ''):<9} "
              f"{float(e.get('calories', 0)):>6.0f} "
              f"{float(e.get('carbohydrate', 0)):>6.1f} "
              f"{float(e.get('protein', 0)):>6.1f} "
              f"{float(e.get('fat', 0)):>6.1f}  "
              f"{e.get('food_entry_name', '')}")
    print(f"  {'':>11}  {'TOTAL':<9} "
          f"{tot['calories']:>6.0f} {tot['carbohydrate']:>6.1f} "
          f"{tot['protein']:>6.1f} {tot['fat']:>6.1f}")


def cmd_delete(env, a):
    api(env, "food_entry.delete", food_entry_id=a.entry_id)
    cache_drop()
    print(f"deleted food_entry_id={a.entry_id}")


KG_PER_LB = 0.45359237


def cmd_profile(env, a):
    """Goal, last recorded weight, and how stale that reading is."""
    pr = api(env, "profile.get")["profile"]
    unit = pr.get("weight_measure", "Lb")
    div = KG_PER_LB if unit == "Lb" else 1.0

    def w(kg):
        return f"{float(kg) / div:.1f} {unit.lower()}"

    # profile.get's last_weight_date_int is NOT updated by weight.update --
    # after a write, last_weight_kg is current while the date still points at
    # the previous weigh-in. Pairing them reports a fresh weight as months old,
    # so take the date from the weigh-in history and only fall back to the
    # profile field when this month has no entry.
    last_di = int(pr["last_weight_date_int"])
    first = datetime.date.today().replace(day=1)
    m = api(env, "weights.get_month",
            date=str((first - datetime.date(1970, 1, 1)).days)).get("month") or {}
    seen = [int(e["date_int"]) for e in as_list(m.get("day"))]
    if seen:
        last_di = max(last_di, max(seen))
    when = datetime.date(1970, 1, 1) + datetime.timedelta(days=last_di)
    age = today_int() - last_di
    gap = (float(pr["last_weight_kg"]) - float(pr["goal_weight_kg"])) / div

    print(f"  height        {float(pr['height_cm']):.1f} cm")
    print(f"  goal          {w(pr['goal_weight_kg'])}")
    print(f"  last weight   {w(pr['last_weight_kg'])}   "
          f"({when.isoformat()}, {age} days ago)")
    print(f"  to goal       {gap:+.1f} {unit.lower()}")


def cmd_weight(env, a):
    """History, or -- with --set -- a new reading.

    The number is read in the unit the profile is configured for (Lb here), so
    a value is never silently taken as kilograms. Both are echoed on a write."""
    pr = api(env, "profile.get")["profile"]
    unit = pr.get("weight_measure", "Lb")
    div = KG_PER_LB if unit == "Lb" else 1.0

    if a.set is not None:
        kg = a.set * div
        params = {"current_weight_kg": f"{kg:.4f}", "date": str(parse_date(a.date))}
        # Both are required on a first-ever write and harmless afterwards;
        # sending the stored values keeps an existing goal from being cleared.
        params["goal_weight_kg"] = pr["goal_weight_kg"]
        params["current_height_cm"] = pr["height_cm"]
        api(env, "weight.update", **params)
        print(f"recorded {a.set:.1f} {unit.lower()} ({kg:.1f} kg) for "
              f"{datetime.date(1970,1,1) + datetime.timedelta(days=parse_date(a.date))}")
        return

    # weights.get_month is per calendar month, so history costs one call each --
    # keep the default window short and let the caller widen it deliberately.
    print(f"{'date':<12} {unit.lower():>8}")
    d = datetime.date.today().replace(day=1)
    rows = []
    for _ in range(a.months):
        di = (d - datetime.date(1970, 1, 1)).days
        m = api(env, "weights.get_month", date=str(di)).get("month") or {}
        for e in as_list(m.get("day")):
            rows.append((int(e["date_int"]), float(e["weight_kg"]) / div))
        d = (d - datetime.timedelta(days=1)).replace(day=1)
    for di, val in sorted(rows):
        when = datetime.date(1970, 1, 1) + datetime.timedelta(days=di)
        print(f"{when.isoformat():<12} {val:>8.1f}")
    if not rows:
        print(f"(no weigh-ins in the last {a.months} months)")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="find foods by name, with servings inline")
    s.add_argument("term")
    s.add_argument("-n", "--max-results", type=int, default=3)
    s.set_defaults(fn=cmd_search)

    s = sub.add_parser("barcode", help="find a food by UPC/EAN")
    s.add_argument("code")
    s.set_defaults(fn=cmd_barcode)

    s = sub.add_parser("get", help="servings for a known food_id")
    s.add_argument("food_id")
    s.set_defaults(fn=cmd_get)

    s = sub.add_parser("log", help="add a diary entry")
    s.add_argument("--food-id", required=True)
    s.add_argument("--serving-id", required=True)
    s.add_argument("--units", required=True,
                   help="how many of that serving, e.g. 1 or 1.5")
    s.add_argument("--meal", help=f"one of {', '.join(MEALS)} (default: by clock)")
    s.add_argument("--date", help="date_int, YYYY-MM-DD, today, yesterday")
    s.add_argument("--name", help="diary label (default: the food's own name)")
    s.set_defaults(fn=cmd_log)

    s = sub.add_parser("create", help="create a custom food (PERMANENT)")
    s.add_argument("--name", required=True,
                   help="item name WITHOUT the brand, e.g. 'Cinnamon Almonds'")
    s.add_argument("--brand", required=True, help="brand / restaurant name")
    s.add_argument("--serving-size", required=True,
                   help="how one serving reads, e.g. '1 oz (30 g)'")
    s.add_argument("--calories", type=float, required=True, help="kcal")
    s.add_argument("--fat", type=float, required=True, help="g")
    s.add_argument("--carbs", dest="carbohydrate", type=float, required=True,
                   help="g")
    s.add_argument("--protein", type=float, required=True, help="g")
    s.add_argument("--brand-type", default="manufacturer",
                   help=f"one of {', '.join(BRAND_TYPES)} (default: %(default)s)")
    s.add_argument("--serving-amount", type=float,
                   help="metric weight of one serving, e.g. 30")
    s.add_argument("--serving-amount-unit", default="g",
                   choices=["g", "ml", "oz"], help="unit for --serving-amount")
    for key, unit in EXTRA_NUTRIENTS:
        s.add_argument(f"--{key.replace('_', '-')}", type=float, help=unit)
    s.add_argument("--dry-run", action="store_true",
                   help="print the exact call and send nothing")
    s.add_argument("--force", action="store_true",
                   help="create even if this brand+name already exists")
    s.set_defaults(fn=cmd_create)

    s = sub.add_parser("day", help="show a day's entries with their ids")
    s.add_argument("date", nargs="?", help="date_int, YYYY-MM-DD, today, yesterday")
    s.add_argument("--json", action="store_true",
                   help="one JSON line of the day's totals (statusline cache)")
    s.set_defaults(fn=cmd_day)

    s = sub.add_parser("profile", help="goal weight, last weigh-in, how stale")
    s.set_defaults(fn=cmd_profile)

    s = sub.add_parser("weight", help="weigh-in history, or record one")
    s.add_argument("--set", type=float,
                   help="record this weight, in the profile's unit")
    s.add_argument("--date", help="date_int, YYYY-MM-DD, today, yesterday")
    s.add_argument("-m", "--months", type=int, default=12,
                   help="how many months of history (one API call each)")
    s.set_defaults(fn=cmd_weight)

    s = sub.add_parser("delete", help="remove a diary entry by id")
    s.add_argument("entry_id")
    s.set_defaults(fn=cmd_delete)

    a = p.parse_args()
    env, _ = load_env()
    if not env.get("FATSECRET_ACCESS_TOKEN"):
        sys.exit("No access token -- run fs_auth.py first.")
    a.fn(env, a)


if __name__ == "__main__":
    main()
