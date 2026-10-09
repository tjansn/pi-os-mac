#!/usr/bin/env python3
"""Templated EN/DE training data for the pi-os-intent-v1 questions (laya.md §10).

Every row is one utterance with gold labels for the four sidecar questions:
  intent  calculate | convert | time_date | file_search | app_launch | web_search |
          open_url | system_toggle | dictation | agent_task
  tier    0 none | 1 little | 2 moderate | 3 heavy      (score question, lowest first)
  screen  true when the utterance refers to something visible on screen
  surface browser | native_app | none

Deterministic: the same --seed always produces byte-identical files (selection uses only
random.Random.random(), whose sequence Python guarantees across versions). Calibration rows
come from held-out *templates*, not just held-out slot fills, so thresholds fitted on them
say something about unseen phrasings. Rows whose text equals a frozen test fixture
(fixtures/pi-os-intent-v1.test.jsonl) are dropped.

Pure Python, no torch, no network:
  python3 generate_dataset.py --out-dir data/ [--seed 1729] [--per-template 24]
"""
import argparse
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIXTURES = os.path.join(HERE, "fixtures", "pi-os-intent-v1.test.jsonl")
INTENTS = ["calculate", "convert", "time_date", "file_search", "app_launch", "web_search", "open_url",
           "system_toggle", "dictation", "agent_task"]
SURFACES = ["browser", "native_app", "none"]

EN_NUMBER_WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                   "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "a hundred"]
DE_NUMBER_WORDS = ["eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf",
                   "zwölf", "fünfzehn", "sechzehn", "zwanzig", "dreißig", "fünfzig", "hundert", "tausend"]

SLOTS = {
    "en": {
        "op": ["plus", "minus", "times", "divided by", "multiplied by"],
        "unit": [("kilometers", "miles"), ("miles", "kilometers"), ("pounds", "kilograms"), ("kilograms", "pounds"),
                 ("fahrenheit", "celsius"), ("celsius", "fahrenheit"), ("inches", "centimeters"),
                 ("liters", "gallons"), ("feet", "meters"), ("ounces", "grams")],
        "cur": ["dollars", "euros", "pounds", "yen", "swiss francs", "canadian dollars"],
        "city": ["Tokyo", "New York", "London", "Sydney", "San Francisco", "Berlin", "Singapore", "Paris", "Dubai",
                 "Toronto", "Mumbai", "Mexico City"],
        "holiday": ["Christmas", "New Year's Eve", "Easter", "Halloween", "Thanksgiving", "the end of the month"],
        "weekday": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        "month": ["January", "March", "May", "July", "September", "October", "December"],
        "file": ["PDF", "invoice", "presentation", "spreadsheet", "contract", "screenshot", "keynote", "document"],
        "topic": ["the Q3 budget", "my apartment lease", "project Phoenix", "the tax return", "the team offsite",
                  "the board meeting", "the insurance claim", "the product roadmap"],
        "when": ["last week", "yesterday", "in August", "this morning", "last month", "from 2024"],
        "app": ["Safari", "Mail", "Notes", "Xcode", "Spotify", "Terminal", "Calendar", "Slack", "Figma", "Music",
                "System Settings", "Finder", "Messages", "Pages"],
        "domain": ["github.com", "youtube.com", "wikipedia.org", "apple.com", "news.ycombinator.com", "nytimes.com",
                   "maps.google.com", "bbc.co.uk"],
        "query": ["the best ramen in Berlin", "how to reset AirPods", "the weather tomorrow in Hamburg",
                  "train times to Munich", "a cheap flight to Lisbon", "reviews of the new iPad",
                  "how tall is the Eiffel Tower", "vegan lasagna recipe"],
        "toggle": ["do not disturb", "bluetooth", "wifi", "dark mode", "night shift", "airplane mode"],
        "onoff": ["on", "off"],
        "payload": ["see you tomorrow at nine, thanks!", "the numbers look good, let's ship it",
                    "running ten minutes late, sorry", "happy birthday, have a great day",
                    "can we move the call to Thursday?", "thanks for the quick reply"],
        "country": ["Australia", "Canada", "Brazil", "Japan", "Kenya", "Norway", "Chile"],
        "concept": ["inflation", "a black hole", "compound interest", "machine learning", "the blockchain"],
        "language": ["Spanish", "French", "German", "Japanese", "Italian"],
        "name": ["Lisa", "Tom", "Anna", "Mark", "Priya", "Jonas"],
        "product": ["laptops", "noise cancelling headphones", "e-bikes", "standing desks", "espresso machines"],
        "price": ["500 euros", "1500 euros", "300 dollars", "2000 dollars"],
        "cuisine": ["Italian", "Thai", "Japanese", "Indian", "Greek"],
    },
    "de": {
        "op": ["plus", "minus", "mal", "geteilt durch", "hoch"],
        "unit": [("Kilometer", "Meilen"), ("Meilen", "Kilometer"), ("Kilo", "Pfund"), ("Pfund", "Kilo"),
                 ("Grad Fahrenheit", "Grad Celsius"), ("Grad Celsius", "Grad Fahrenheit"), ("Zoll", "Zentimeter"),
                 ("Liter", "Gallonen"), ("Fuß", "Meter"), ("Unzen", "Gramm")],
        "cur": ["Dollar", "Euro", "Pfund", "Yen", "Franken", "Kronen"],
        "city": ["Tokio", "New York", "London", "Sydney", "San Francisco", "Berlin", "Singapur", "Paris", "Dubai",
                 "Toronto", "Wien", "Mexiko-Stadt"],
        "holiday": ["Weihnachten", "Silvester", "Ostern", "Pfingsten", "Monatsende", "meinem Geburtstag"],
        "weekday": ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"],
        "month": ["Januar", "März", "Mai", "Juli", "September", "Oktober", "Dezember"],
        "file": ["PDF", "Rechnung", "Präsentation", "Tabelle", "Vertrag", "Screenshot", "Datei", "Dokument"],
        "topic": ["das Q3-Budget", "den Mietvertrag", "Projekt Phoenix", "die Steuererklärung", "das Teamevent",
                  "die Vorstandssitzung", "den Versicherungsfall", "die Produkt-Roadmap"],
        "when": ["von letzter Woche", "von gestern", "aus dem August", "von heute Morgen", "vom letzten Monat",
                 "aus 2024"],
        "app": ["Safari", "Mail", "Notizen", "Xcode", "Spotify", "Terminal", "Kalender", "Slack", "Figma", "Musik",
                "Systemeinstellungen", "Finder", "Nachrichten", "Pages"],
        "domain": ["github.com", "youtube.com", "wikipedia.org", "spiegel.de", "heise.de", "zeit.de", "tagesschau.de",
                   "bahn.de"],
        "query": ["den Öffnungszeiten vom Bürgeramt", "dem Wetter am Wochenende in Hamburg",
                  "einem günstigen Flug nach Lissabon", "Zugverbindungen nach München", "einem Rezept für Linsensuppe",
                  "Testberichten zum neuen iPad"],
        "toggle": ["Nicht stören", "Bluetooth", "WLAN", "den Dunkelmodus", "Night Shift", "den Flugmodus"],
        "onoff": ["an", "aus"],
        "payload": ["Ich komme heute etwas später, sorry", "Vielen Dank für die schnelle Antwort",
                    "Bis morgen um neun", "Alles Gute zum Geburtstag", "Können wir das Meeting verschieben?",
                    "Die Zahlen sehen gut aus"],
        "country": ["Australien", "Kanada", "Brasilien", "Japan", "Kenia", "Norwegen", "Chile"],
        "concept": ["Inflation", "ein schwarzes Loch", "den Zinseszins", "maschinelles Lernen", "die Blockchain"],
        "language": ["Englische", "Französische", "Spanische", "Italienische", "Japanische"],
        "name": ["Lisa", "Tom", "Anna", "Markus", "Priya", "Jonas"],
        "product": ["Laptops", "Kopfhörer mit Noise Cancelling", "E-Bikes", "Stehschreibtische", "Siebträgermaschinen"],
        "price": ["500 Euro", "1500 Euro", "300 Euro", "2000 Euro"],
        "cuisine": ["italienisches", "thailändisches", "japanisches", "indisches", "griechisches"],
    },
}

# (template id, lang, intent, tier, screen, surface, pattern). {n}/{m}: digits; {nw}: number word.
TEMPLATES = [
    ("calc.en.1", "en", "calculate", 0, False, "none", "what's {n} {op} {m}"),
    ("calc.en.2", "en", "calculate", 0, False, "none", "what is {n} percent of {m}"),
    ("calc.en.3", "en", "calculate", 0, False, "none", "calculate {nw} {op} {nw2}"),
    ("calc.en.4", "en", "calculate", 0, False, "none", "square root of {m}"),
    ("calc.en.5", "en", "calculate", 0, False, "none", "{n} {op} {m} please"),
    ("calc.de.1", "de", "calculate", 0, False, "none", "wie viel ist {n} {op} {m}"),
    ("calc.de.2", "de", "calculate", 0, False, "none", "was sind {n} Prozent von {m}"),
    ("calc.de.3", "de", "calculate", 0, False, "none", "was ergibt {nw} {op} {nw2}"),
    ("calc.de.4", "de", "calculate", 0, False, "none", "Wurzel aus {m}"),
    ("calc.de.5", "de", "calculate", 0, False, "none", "rechne {n} {op} {m}"),
    ("conv.en.1", "en", "convert", 0, False, "none", "convert {n} {unit_from} to {unit_to}"),
    ("conv.en.2", "en", "convert", 0, False, "none", "how many {cur2} is {n} {cur}"),
    ("conv.en.3", "en", "convert", 0, False, "none", "{n} {unit_from} in {unit_to}"),
    ("conv.en.4", "en", "convert", 0, False, "none", "what are {n} {cur} in {cur2}"),
    ("conv.de.1", "de", "convert", 0, False, "none", "rechne {n} {unit_from} in {unit_to} um"),
    ("conv.de.2", "de", "convert", 0, False, "none", "wie viel sind {n} {cur} in {cur2}"),
    ("conv.de.3", "de", "convert", 0, False, "none", "{n} {unit_from} in {unit_to}"),
    ("conv.de.4", "de", "convert", 0, False, "none", "wie viele {unit_to} sind {n} {unit_from}"),
    ("time.en.1", "en", "time_date", 0, False, "none", "what time is it in {city}"),
    ("time.en.2", "en", "time_date", 0, False, "none", "how many days until {holiday}"),
    ("time.en.3", "en", "time_date", 0, False, "none", "what day of the week is {month} {d}"),
    ("time.en.4", "en", "time_date", 0, False, "none", "what's the date {n} days from now"),
    ("time.de.1", "de", "time_date", 0, False, "none", "wie spät ist es in {city}"),
    ("time.de.2", "de", "time_date", 0, False, "none", "wie viele Tage sind es noch bis {holiday}"),
    ("time.de.3", "de", "time_date", 0, False, "none", "welcher Wochentag ist der {d}. {month}"),
    ("time.de.4", "de", "time_date", 0, False, "none", "welches Datum ist in {n} Tagen"),
    ("file.en.1", "en", "file_search", 0, False, "none", "find the {file} about {topic}"),
    ("file.en.2", "en", "file_search", 0, False, "none", "where is the {file} I saved {when}"),
    ("file.en.3", "en", "file_search", 0, False, "none", "search my files for {topic}"),
    ("file.en.4", "en", "file_search", 0, False, "none", "find my {file} from {when2}"),
    ("file.de.1", "de", "file_search", 0, False, "none", "finde die {file} über {topic}"),
    ("file.de.2", "de", "file_search", 0, False, "none", "wo ist die {file} {when}"),
    ("file.de.3", "de", "file_search", 0, False, "none", "such in meinen Dateien nach {topic}"),
    ("file.de.4", "de", "file_search", 0, False, "none", "zeig mir die {file} {when}"),
    ("app.en.1", "en", "app_launch", 0, False, "native_app", "open {app}"),
    ("app.en.2", "en", "app_launch", 0, False, "native_app", "switch to {app}"),
    ("app.en.3", "en", "app_launch", 0, False, "native_app", "launch {app}"),
    ("app.en.4", "en", "app_launch", 0, False, "native_app", "bring up {app}"),
    ("app.de.1", "de", "app_launch", 0, False, "native_app", "öffne {app}"),
    ("app.de.2", "de", "app_launch", 0, False, "native_app", "wechsle zu {app}"),
    ("app.de.3", "de", "app_launch", 0, False, "native_app", "starte {app}"),
    ("app.de.4", "de", "app_launch", 0, False, "native_app", "mach {app} auf"),
    ("web.en.1", "en", "web_search", 0, False, "browser", "search the web for {query}"),
    ("web.en.2", "en", "web_search", 0, False, "browser", "google {query}"),
    ("web.en.3", "en", "web_search", 0, False, "browser", "look up {query} online"),
    ("web.de.1", "de", "web_search", 0, False, "browser", "such im Internet nach {query}"),
    ("web.de.2", "de", "web_search", 0, False, "browser", "google mal nach {query}"),
    ("web.de.3", "de", "web_search", 0, False, "browser", "recherchier online nach {query}"),
    ("url.en.1", "en", "open_url", 0, False, "browser", "open {domain}"),
    ("url.en.2", "en", "open_url", 0, False, "browser", "go to {domain}"),
    ("url.en.3", "en", "open_url", 0, False, "browser", "visit {domain}"),
    ("url.de.1", "de", "open_url", 0, False, "browser", "öffne {domain}"),
    ("url.de.2", "de", "open_url", 0, False, "browser", "geh auf {domain}"),
    ("url.de.3", "de", "open_url", 0, False, "browser", "ruf {domain} auf"),
    ("sys.en.1", "en", "system_toggle", 0, False, "none", "turn {onoff} {toggle}"),
    ("sys.en.2", "en", "system_toggle", 0, False, "none", "set the volume to {pct} percent"),
    ("sys.en.3", "en", "system_toggle", 0, False, "none", "switch {toggle} {onoff}"),
    ("sys.en.4", "en", "system_toggle", 0, False, "none", "mute the sound"),
    ("sys.de.1", "de", "system_toggle", 0, False, "none", "schalte {toggle} {onoff}"),
    ("sys.de.2", "de", "system_toggle", 0, False, "none", "stell die Lautstärke auf {pct} Prozent"),
    ("sys.de.3", "de", "system_toggle", 0, False, "none", "mach {toggle} {onoff}"),
    ("sys.de.4", "de", "system_toggle", 0, False, "none", "Ton stumm schalten"),
    ("dict.en.1", "en", "dictation", 0, False, "native_app", "type: {payload}"),
    ("dict.en.2", "en", "dictation", 0, False, "native_app", "dictate: {payload}"),
    ("dict.en.3", "en", "dictation", 0, False, "native_app", "write exactly: {payload}"),
    ("dict.de.1", "de", "dictation", 0, False, "native_app", "schreib: {payload}"),
    ("dict.de.2", "de", "dictation", 0, False, "native_app", "tippe ein: {payload}"),
    ("dict.de.3", "de", "dictation", 0, False, "native_app", "diktiere: {payload}"),
    ("task.en.1", "en", "agent_task", 1, False, "none", "what's the capital of {country}"),
    ("task.en.2", "en", "agent_task", 1, False, "none", "explain {concept} in simple words"),
    ("task.en.3", "en", "agent_task", 1, True, "browser", "summarize this article in {nw} bullet points"),
    ("task.en.4", "en", "agent_task", 1, True, "native_app", "what does this error mean"),
    ("task.en.5", "en", "agent_task", 1, True, "native_app", "translate the selected text into {language}"),
    ("task.en.6", "en", "agent_task", 2, True, "native_app", "reply to this email and tell {name} {weekday} works"),
    ("task.en.7", "en", "agent_task", 2, False, "browser", "book a table for {nw} at an {cuisine} place on {weekday}"),
    ("task.en.8", "en", "agent_task", 2, False, "native_app", "write a short email to {name} that I'm running late"),
    ("task.en.9", "en", "agent_task", 2, True, "native_app", "add the meeting from this mail to my calendar"),
    ("task.en.10", "en", "agent_task", 3, True, "native_app", "refactor this function and add unit tests"),
    ("task.en.11", "en", "agent_task", 3, False, "browser", "research the best {product} under {price} and compare them"),
    ("task.en.12", "en", "agent_task", 3, True, "native_app", "compare the offers in this folder and build a price table"),
    ("task.de.1", "de", "agent_task", 1, False, "none", "was ist die Hauptstadt von {country}"),
    ("task.de.2", "de", "agent_task", 1, False, "none", "erklär mir {concept} in einfachen Worten"),
    ("task.de.3", "de", "agent_task", 1, True, "browser", "fasse diesen Artikel in {nw} Punkten zusammen"),
    ("task.de.4", "de", "agent_task", 1, True, "native_app", "was bedeutet diese Fehlermeldung"),
    ("task.de.5", "de", "agent_task", 1, True, "native_app", "übersetze den markierten Text ins {language}"),
    ("task.de.6", "de", "agent_task", 2, True, "native_app", "antworte auf diese Mail, dass {weekday} passt"),
    ("task.de.7", "de", "agent_task", 2, False, "browser", "reservier einen Tisch für {nw} in einem {cuisine} Restaurant"),
    ("task.de.8", "de", "agent_task", 2, False, "native_app", "schreib eine kurze Mail an {name}, dass ich später komme"),
    ("task.de.9", "de", "agent_task", 2, True, "native_app", "trag den Termin aus dieser Mail in meinen Kalender ein"),
    ("task.de.10", "de", "agent_task", 3, True, "native_app", "refaktoriere diese Funktion und schreib Tests dazu"),
    ("task.de.11", "de", "agent_task", 3, False, "browser", "recherchiere die besten {product} unter {price} und vergleiche sie"),
    ("task.de.12", "de", "agent_task", 3, True, "native_app", "vergleiche die Angebote in diesem Ordner und erstelle eine Tabelle"),
]


def pick(rng, values):
    """Version-stable choice: only Random.random() is guaranteed identical across Python versions."""
    return values[min(len(values) - 1, int(rng.random() * len(values)))]


def fill(rng, lang, pattern):
    slots = SLOTS[lang]
    words = EN_NUMBER_WORDS if lang == "en" else DE_NUMBER_WORDS
    unit_from, unit_to = pick(rng, slots["unit"])
    cur = pick(rng, slots["cur"])
    cur2 = pick(rng, [c for c in slots["cur"] if c != cur])
    when = pick(rng, slots["when"])
    values = {
        "n": str(1 + int(rng.random() * 999)), "m": str(2 + int(rng.random() * 9998)),
        "d": str(1 + int(rng.random() * 28)), "pct": str(5 * (1 + int(rng.random() * 20))),
        "nw": pick(rng, words), "nw2": pick(rng, words),
        "unit_from": unit_from, "unit_to": unit_to, "cur": cur, "cur2": cur2,
        "when": when, "when2": when.replace("in ", "").replace("from ", ""),
    }
    for name, options in slots.items():
        if name not in ("unit", "cur", "when") and isinstance(options[0], str):
            values.setdefault(name, pick(rng, options))
    return pattern.format(**values)


def normalize(text):
    return " ".join(text.lower().split())


def load_fixture_texts(path):
    if not path or not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as handle:
        return {normalize(json.loads(line)["utterance"]) for line in handle if line.strip()}


def calib_templates():
    """Every third template of each (intent, lang) group with at least three templates is held out."""
    groups, held = {}, set()
    for template in TEMPLATES:
        groups.setdefault((template[2], template[1]), []).append(template[0])
    for ids in groups.values():
        if len(ids) >= 3:
            held.update(ids[2::3])
    return held


def generate(seed, per_template, exclude):
    rng = random.Random(seed)
    held = calib_templates()
    rows, seen = [], set(exclude)
    for template_id, lang, intent, tier, screen, surface, pattern in TEMPLATES:
        attempts = 0
        made = 0
        while made < per_template and attempts < per_template * 8:
            attempts += 1
            text = fill(rng, lang, pattern)
            key = normalize(text)
            if key in seen:
                continue
            seen.add(key)
            made += 1
            rows.append({
                "id": "gen-%05d" % len(rows), "lang": lang, "utterance": text,
                "labels": {"intent": intent, "tier": tier, "screen": screen, "surface": surface},
                "template": template_id, "split": "calib" if template_id in held else "train",
            })
    return rows


def validate(rows):
    for row in rows:
        labels = row["labels"]
        assert labels["intent"] in INTENTS, row["id"]
        assert labels["tier"] in (0, 1, 2, 3), row["id"]
        assert isinstance(labels["screen"], bool), row["id"]
        assert labels["surface"] in SURFACES, row["id"]
        assert 0 < len(row["utterance"]) <= 500, row["id"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--seed", type=int, default=1729)
    parser.add_argument("--per-template", type=int, default=24)
    parser.add_argument("--exclude-fixtures", default=DEFAULT_FIXTURES,
                        help="JSONL whose utterances must never appear in train/calib (frozen test set)")
    args = parser.parse_args(argv)
    if not 1 <= args.per_template <= 500:
        parser.error("--per-template must be 1..500")
    rows = generate(args.seed, args.per_template, load_fixture_texts(args.exclude_fixtures))
    validate(rows)
    os.makedirs(args.out_dir, exist_ok=True)
    counts = {}
    for split in ("train", "calib"):
        with open(os.path.join(args.out_dir, split + ".jsonl"), "w", encoding="utf-8", newline="\n") as handle:
            for row in rows:
                if row["split"] == split:
                    handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
                    counts[split] = counts.get(split, 0) + 1
    per_intent = {}
    for row in rows:
        per_intent[row["labels"]["intent"]] = per_intent.get(row["labels"]["intent"], 0) + 1
    # Counts only: utterances never go to the console.
    print(json.dumps({"seed": args.seed, "rows": len(rows), "splits": counts, "intents": per_intent}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
