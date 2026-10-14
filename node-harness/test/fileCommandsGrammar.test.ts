import assert from "node:assert/strict";
import { test } from "node:test";
import { cleanName, fileCommandLanguage, fileCommandOf, matchFileCommand, phraseLike, type FileCommand } from "../src/instant/grammar/fileCommands.js";
import { parseInstant } from "../src/instant/grammar/index.js";
import { normalize } from "../src/instant/normalize.js";

/*
 * File-command grammar (DESIGN6 §2 with BUILD6): closed EN/DE forms of delete, create, copy, duplicate, move, rename and
 * close/quit, one row per form, and the policy cases that stay today's (compounds, deixis, the Trash, paths, wildcards,
 * quantifiers, text edits, questions). Pure: no dispatcher, no host, no file system.
 */

const parse = (text: string, locale = "de-DE", voice = false): FileCommand | null => matchFileCommand(normalize(text, locale), voice ? { voice: true } : {});

const ROWS: readonly (readonly [text: string, locale: string, expected: FileCommand])[] = [
  // delete
  ["lösche test", "de-DE", { op: "delete", name: "test" }],
  ["Lösch test", "de-DE", { op: "delete", name: "test" }],
  ["loesche test", "de-DE", { op: "delete", name: "test" }],
  ["entferne test", "de-DE", { op: "delete", name: "test" }],
  ["test löschen", "de-DE", { op: "delete", name: "test" }],
  ["Test entfernen.", "de-DE", { op: "delete", name: "Test" }],
  ["Lösche den Ordner Radfotos.", "de-DE", { op: "delete", name: "den Ordner Radfotos" }],
  ["lösche bitte mal Radfotos", "de-DE", { op: "delete", name: "Radfotos" }],
  ["delete test", "en-US", { op: "delete", name: "test" }],
  ["remove test", "en-US", { op: "delete", name: "test" }],
  ["delete the file notes.txt", "en-US", { op: "delete", name: "the file notes.txt" }],
  ["Delete Rad-Tour 2026.pdf", "en-US", { op: "delete", name: "Rad-Tour 2026.pdf" }],
  // create (the noun decides folder or file)
  ["erstelle Ordner test", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["Erstelle einen neuen Ordner Projekte", "de-DE", { op: "create", name: "Projekte", kind: "folder" }],
  ["neuer Ordner test", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["lege einen Ordner test an", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["Ordner test anlegen", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["neue Datei notes.txt", "de-DE", { op: "create", name: "notes.txt", kind: "file" }],
  ["neue Datei Einkauf erstellen", "de-DE", { op: "create", name: "Einkauf", kind: "file" }],
  ["erstelle eine Datei namens Plan", "de-DE", { op: "create", name: "Plan", kind: "file" }],
  ["create folder test", "en-US", { op: "create", name: "test", kind: "folder" }],
  ["create a new file called notes.txt", "en-US", { op: "create", name: "notes.txt", kind: "file" }],
  ["new folder test", "en-US", { op: "create", name: "test", kind: "folder" }],
  ["make a folder Archive", "en-US", { op: "create", name: "Archive", kind: "folder" }],
  // create: the name before the noun, definite articles, a text file by its extension, a standard folder to create in
  ["create teast folder", "en-US", { op: "create", name: "teast", kind: "folder" }],
  ["make a test folder", "en-US", { op: "create", name: "test", kind: "folder" }],
  ["new teast file", "en-US", { op: "create", name: "teast", kind: "file" }],
  ["create the folder Plans", "en-US", { op: "create", name: "Plans", kind: "folder" }],
  ["erstelle einen test Ordner", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["erstelle den Ordner Plans", "de-DE", { op: "create", name: "Plans", kind: "folder" }],
  ["neuer test Ordner", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["test Ordner anlegen", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["lege einen test Ordner an", "de-DE", { op: "create", name: "test", kind: "folder" }],
  ["erstelle notes.txt", "de-DE", { op: "create", name: "notes.txt", kind: "file" }],
  ["create todo.md", "en-US", { op: "create", name: "todo.md", kind: "file" }],
  ["notes.txt anlegen", "de-DE", { op: "create", name: "notes.txt", kind: "file" }],
  ["erstelle Ordner Belege in Dokumente", "de-DE", { op: "create", name: "Belege", kind: "folder", place: "Dokumente" }],
  ["erstelle einen test Ordner in Dokumente", "de-DE", { op: "create", name: "test", kind: "folder", place: "Dokumente" }],
  // a standard folder as the object's place
  ["lösche test in Downloads", "de-DE", { op: "delete", name: "test", place: "Downloads", whole: "test in Downloads" }],
  ["lösche test aus dem Ordner Dokumente", "de-DE", { op: "delete", name: "test", place: "Dokumente", whole: "test aus dem Ordner Dokumente" }],
  ["Lösche Radfotos auf dem Schreibtisch.", "de-DE", { op: "delete", name: "Radfotos", place: "Schreibtisch", whole: "Radfotos auf dem Schreibtisch" }],
  ["lösche test im Downloads-Ordner", "de-DE", { op: "delete", name: "test", place: "Downloads", whole: "test im Downloads-Ordner" }],
  ["delete test from my Downloads", "en-US", { op: "delete", name: "test", place: "Downloads", whole: "test from my Downloads" }],
  ["dupliziere test in Downloads", "de-DE", { op: "duplicate", name: "test", place: "Downloads", whole: "test in Downloads" }],
  ["kopiere Rechnung aus Downloads nach Dokumente", "de-DE",
    { op: "copy", splits: [{ name: "Rechnung", place: "Downloads", whole: "Rechnung aus Downloads", dest: "Dokumente" }] }],
  ["kopiere test aus Downloads", "de-DE", { op: "copy", splits: [{ name: "test", place: "Downloads", whole: "test aus Downloads", dest: "" }] }],
  ["verschiebe test vom Schreibtisch nach Dokumente", "de-DE",
    { op: "move", splits: [{ name: "test", place: "Schreibtisch", whole: "test vom Schreibtisch", dest: "Dokumente" }] }],
  // any folder by name (DESIGN8 A1): 1–3 words after the last place preposition
  ["lösche test in Projekte", "de-DE", { op: "delete", name: "test", place: "Projekte", whole: "test in Projekte" }],
  ["lösche test aus dem Ordner Rechnungen 2026", "de-DE", { op: "delete", name: "test", place: "Rechnungen 2026", whole: "test aus dem Ordner Rechnungen 2026" }],
  ["lösche Fotos in Rom in Projekte", "de-DE", { op: "delete", name: "Fotos in Rom", place: "Projekte", whole: "Fotos in Rom in Projekte" }],
  ["delete test from my Archive folder", "en-US", { op: "delete", name: "test", place: "Archive", whole: "test from my Archive folder" }],
  ["erstelle Ordner Belege in Projekte", "de-DE", { op: "create", name: "Belege", kind: "folder", place: "Projekte" }],
  // several names (DESIGN8 B1): delete, copy and move; the whole object stays the name
  ["lösche test und tiest", "de-DE", { op: "delete", name: "test und tiest", names: ["test", "tiest"] }],
  ["lösche Rechnung, Angebot und Notizen", "de-DE", { op: "delete", name: "Rechnung, Angebot und Notizen", names: ["Rechnung", "Angebot", "Notizen"] }],
  ["delete Plan, Notes, and Budget", "en-US", { op: "delete", name: "Plan, Notes, and Budget", names: ["Plan", "Notes", "Budget"] }],
  ["lösche test und tiest in Downloads", "de-DE", { op: "delete", name: "test und tiest", names: ["test", "tiest"], place: "Downloads", whole: "test und tiest in Downloads" }],
  ["copy Plan and Notes to Dokumente", "en-US", { op: "copy", splits: [{ name: "Plan and Notes", names: ["Plan", "Notes"], dest: "Dokumente" }] }],
  ["dupliziere test und tiest", "de-DE", { op: "duplicate", name: "test und tiest" }],
  ["lösche test und Test", "de-DE", { op: "delete", name: "test und Test" }],
  // an article alone is never a name, in a list too: one name
  ["lösche a und b", "de-DE", { op: "delete", name: "a und b" }],
  // undo (DESIGN8 C1): the whole line
  ["rückgängig", "de-DE", { op: "undo" }],
  ["Mach das rückgängig.", "de-DE", { op: "undo" }],
  ["das rückgängig machen", "de-DE", { op: "undo" }],
  ["undo", "en-US", { op: "undo" }],
  ["Undo that.", "en-US", { op: "undo" }],
  ["undo the last change", "en-US", { op: "undo" }],
  // copy (every preposition is a reading, the last one first) and duplicate
  ["kopiere test nach Dokumente", "de-DE", { op: "copy", splits: [{ name: "test", dest: "Dokumente" }] }],
  ["kopiere test in den Ordner Archiv", "de-DE", { op: "copy", splits: [{ name: "test", dest: "den Ordner Archiv" }] }],
  ["test nach Downloads kopieren", "de-DE", { op: "copy", splits: [{ name: "test", dest: "Downloads" }] }],
  ["kopiere test hierher", "de-DE", { op: "copy", splits: [{ name: "test", dest: "hierher" }] }],
  ["kopiere test", "de-DE", { op: "copy", splits: [{ name: "test", dest: "" }] }],
  // Any folder by name is a place (DESIGN8 A1); the lane tries the whole object ("Fotos in Rom") first.
  ["kopiere Fotos in Rom nach Archiv", "de-DE",
    { op: "copy", splits: [{ name: "Fotos", place: "Rom", whole: "Fotos in Rom", dest: "Archiv" }, { name: "Fotos", dest: "Rom nach Archiv" }] }],
  ["copy test to Downloads", "en-US", { op: "copy", splits: [{ name: "test", dest: "Downloads" }] }],
  ["copy test to ~/Projects", "en-US", { op: "copy", splits: [{ name: "test", dest: "~/Projects" }] }],
  ["dupliziere test", "de-DE", { op: "duplicate", name: "test" }],
  ["test duplizieren", "de-DE", { op: "duplicate", name: "test" }],
  ["duplicate test", "en-US", { op: "duplicate", name: "test" }],
  // move
  ["verschiebe test nach Dokumente", "de-DE", { op: "move", splits: [{ name: "test", dest: "Dokumente" }] }],
  ["test nach Downloads verschieben", "de-DE", { op: "move", splits: [{ name: "test", dest: "Downloads" }] }],
  ["verschiebe test", "de-DE", { op: "move", splits: [{ name: "test", dest: "" }] }],
  ["move test into Archive", "en-US", { op: "move", splits: [{ name: "test", dest: "Archive" }] }],
  ["move test to the Desktop", "en-US", { op: "move", splits: [{ name: "test", dest: "the Desktop" }] }],
  // rename
  ["benenne test in test-alt um", "de-DE", { op: "rename", name: "test", newName: "test-alt" }],
  ["nenne test in test-alt um", "de-DE", { op: "rename", name: "test", newName: "test-alt" }],
  ["benenne test um in Test Alt", "de-DE", { op: "rename", name: "test", newName: "Test Alt" }],
  ["test in test-alt umbenennen", "de-DE", { op: "rename", name: "test", newName: "test-alt" }],
  ["rename test to test-alt", "en-US", { op: "rename", name: "test", newName: "test-alt" }],
  // close / quit (window nouns and articles are not the name)
  ["schließe Downloads", "de-DE", { op: "close", name: "Downloads", quit: false }],
  ["schliesse Downloads", "de-DE", { op: "close", name: "Downloads", quit: false }],
  // A window or folder noun names a window (`window`): the lane never quits an app for it.
  ["schließe das Downloads-Fenster", "de-DE", { op: "close", name: "Downloads", quit: false, window: true }],
  ["schließe das Fenster Downloads", "de-DE", { op: "close", name: "Downloads", quit: false, window: true }],
  ["schließe den Ordner Downloads", "de-DE", { op: "close", name: "Downloads", quit: false, window: true }],
  ["schließe den Downloads-Ordner", "de-DE", { op: "close", name: "Downloads-Ordner", quit: false, window: true }],
  ["Downloads schließen", "de-DE", { op: "close", name: "Downloads", quit: false }],
  ["close the Downloads window", "en-US", { op: "close", name: "Downloads", quit: false, window: true }],
  ["close the Safari window", "en-US", { op: "close", name: "Safari", quit: false, window: true }],
  ["schließe die Safari-App", "de-DE", { op: "close", name: "Safari", quit: false }],
  ["beende Safari", "de-DE", { op: "close", name: "Safari", quit: true }],
  ["Safari beenden", "de-DE", { op: "close", name: "Safari", quit: true }],
  ["quit Safari", "en-US", { op: "close", name: "Safari", quit: true }],
];

test("file-command grammar: one row per EN/DE form and op, names in their original case", () => {
  for (const [text, locale, expected] of ROWS) {
    assert.deepEqual(parse(text, locale), expected, text);
    // The spoken grammar reads every typed form the same way.
    assert.deepEqual(parse(text, locale, true), expected, `voice: ${text}`);
  }
});

test("file-command grammar: the spoken core drops fillers and wrappers before the name", () => {
  assert.deepEqual(parse("Äh, kannst du test löschen?", "de-DE", true), { op: "delete", name: "test" });
  assert.deepEqual(parse("Okay, lösche Test.", "de-DE", true), { op: "delete", name: "Test" });
  assert.deepEqual(parse("ich will Radfotos löschen", "de-DE", true), { op: "delete", name: "Radfotos" });
  assert.deepEqual(parse("um, delete test for me", "en-US", true), { op: "delete", name: "test" });
  // The core keeps the case and the commas that part several names; an ASR comma after the verb still reads as none.
  assert.deepEqual(parse("Äh, lösche Rechnung, Angebot und Notizen.", "de-DE", true),
    { op: "delete", name: "Rechnung, Angebot und Notizen", names: ["Rechnung", "Angebot", "Notizen"] });
  assert.deepEqual(parse("Lösche, Rechnung und Angebot.", "de-DE", true), { op: "delete", name: "Rechnung und Angebot", names: ["Rechnung", "Angebot"] });
  assert.deepEqual(parse("Kopiere, Plan nach Dokumente", "de-DE", true), { op: "copy", splits: [{ name: "Plan", dest: "Dokumente" }] });
  // Typed text gets no core: a subject at the head of a verb-final form is no name.
  assert.equal(parse("ich will Radfotos löschen", "de-DE"), null);
});

test("file-command grammar: policy first — today's handling for the Trash, compounds, deixis, sets, paths, text edits and questions", () => {
  const NOT_FILE_COMMANDS: readonly [string, string][] = [
    // Deixis and bare edits.
    ["lösche das", "de-DE"], ["lösch das alles", "de-DE"], ["delete it", "en-US"], ["delete this", "en-US"], ["lösche diese Datei", "de-DE"],
    ["delete that file", "en-US"], ["lösche die markierten Dateien", "de-DE"], ["close this", "en-US"], ["schließe das Fenster", "de-DE"],
    ["kopiere das nach Dokumente", "de-DE"], ["copy that", "en-US"],
    // Sets, quantifiers, age words.
    ["lösche alles", "de-DE"], ["delete everything", "en-US"], ["lösche alle Dateien", "de-DE"], ["delete all my photos", "en-US"],
    ["lösche die alten Downloads", "de-DE"], ["delete the old screenshots", "en-US"], ["close all windows", "en-US"], ["schließe alle Fenster", "de-DE"],
    // The Trash (there is no trash op) and uninstalling.
    ["move test to the trash", "en-US"], ["lege test in den Papierkorb", "de-DE"], ["test in den Papierkorb", "de-DE"], ["verschiebe test in den Müll", "de-DE"],
    ["Papierkorb leeren", "de-DE"], ["empty the trash", "en-US"], ["remove Zoom from my Mac", "en-US"], ["entferne Zoom vom Mac", "de-DE"],
    // Paths, wildcards, shell commands.
    ["Lösche den Ordner ~/pi-os-dcg-probe", "de-DE"], ["delete ~/Downloads/x.zip", "en-US"], ["delete *.pdf", "en-US"], ["rm -rf ~", "en-US"],
    ["rm -r ~/x", "en-US"], ["lösche /tmp/x", "de-DE"],
    // Compounds.
    ["lösche test und dann öffne Safari", "de-DE"], ["delete test and then open Notes", "en-US"], ["kopiere test und verschiebe Radfotos", "de-DE"],
    // A comma before "and" may end a list of names, never hide a second command.
    ["delete test, and open Safari", "en-US"], ["delete Plan, and then Notes", "en-US"], ["lösche test, und dann Safari", "de-DE"],
    // Text and in-app edits, UI objects, the clipboard.
    ["delete the last sentence", "en-US"], ["Lösche den letzten Satz.", "de-DE"], ["Entferne das Wort.", "de-DE"], ["remove the second paragraph", "en-US"],
    ["copy the link", "en-US"], ["copy test to clipboard", "en-US"], ["kopiere test in die Zwischenablage", "de-DE"], ["move the window to the left", "en-US"],
    ["move to the next field", "en-US"],
    // Questions and requests to pi.
    ["wie kann ich test löschen", "de-DE"], ["how do I delete test", "en-US"], ["frag pi lösche test", "de-DE"],
    // New names that are prose, and forms without a name.
    ["erstelle eine Datei mit einer Einkaufsliste", "de-DE"], ["create a file for my notes", "en-US"], ["neuer Ordner", "de-DE"], ["create a folder", "en-US"],
    ["neue Datei erstellen", "de-DE"],
    // Name-first forms that name no folder: articles and "new" only, plain adjectives, phrases, possessives; no empty zip.
    ["create a new folder", "en-US"], ["make a new file", "en-US"], ["erstelle einen neuen Ordner", "de-DE"], ["erstelle einen leeren Ordner", "de-DE"],
    ["make a backup of the folder", "en-US"], ["erstelle eine Kopie vom Ordner", "de-DE"], ["create my project folder", "en-US"], ["create archive.zip", "en-US"],
    // Undo is the whole line, never an app's undo of something named.
    ["mach den letzten Schritt in Pages rückgängig", "de-DE"], ["undo the typing in Notes", "en-US"],
    // A place never turns an in-app edit into a file command: the whole object passes the same checks.
    ["delete the intro from the presentation", "en-US"], ["delete the second slide from the presentation", "en-US"],
    // Nothing to do with files.
    ["öffne test", "de-DE"], ["open Radfotos", "en-US"], ["Albert Einstein", "de-DE"], ["15% of 340", "en-US"], ["wie spät ist es in Tokio", "de-DE"],
  ];
  for (const [text, locale] of NOT_FILE_COMMANDS) {
    assert.equal(parse(text, locale), null, text);
    assert.equal(parse(text, locale, true), null, `voice: ${text}`);
  }
});

test("file-command grammar: the deletion policy still sees what it saw (the lane, not the grammar, decides which wins)", () => {
  const ctx = { now: new Date(2026, 9, 12), locale: "de-DE", webSearchTemplate: "https://duckduckgo.com/?q=%s" };
  // A file noun is the policy's refusal; a bare object its app check. Both are also file commands for the lane.
  assert.equal(parseInstant(normalize("Lösche den Ordner Radfotos", "de-DE"), ctx)?.kind, "refuse");
  assert.equal(parseInstant(normalize("lösche test", "de-DE"), ctx)?.kind, "delete_target");
  assert.ok(parse("Lösche den Ordner Radfotos") && parse("lösche test"));
});

test("file-command helpers: names lose wrapping quotes and trailing punctuation; phrase-like names; raw-text parsing never throws", () => {
  assert.equal(cleanName("„Mein Projekt“."), "Mein Projekt");
  assert.equal(cleanName("  \"notes.txt\"  "), "notes.txt");
  assert.equal(cleanName("test!"), "test");
  assert.equal(cleanName("notes.txt"), "notes.txt");
  assert.deepEqual(parse("erstelle Ordner „Mein Projekt“"), { op: "create", name: "Mein Projekt", kind: "folder" });
  assert.equal(phraseLike("test in Downloads"), true);
  assert.equal(phraseLike("Radfotos"), false);
  assert.deepEqual(fileCommandOf("lösche test", "de-DE"), { op: "delete", name: "test" });
  assert.equal(fileCommandOf("x".repeat(400)), null);
  assert.equal(fileCommandOf(""), null);
});

test("file-command language: the verb decides, whatever the name reads like; mixed or no verbs leave it to the text", () => {
  const lang = (text: string, locale = "de-DE") => fileCommandLanguage(normalize(text, locale));
  assert.equal(lang("erstelle Ordner a/b"), "de");
  assert.equal(lang("lösche the report"), "de");
  assert.equal(lang("Ordner Plans erstellen"), "de");
  assert.equal(lang("neuer Ordner Projects"), "de");
  assert.equal(lang("create folder Bilder", "en-US"), "en");
  assert.equal(lang("delete Entwurf", "en-US"), "en");
  assert.equal(lang("schließe Safari"), "de");
  assert.equal(lang("quit Safari", "en-US"), "en");
  assert.equal(lang("lösche move"), null);
  assert.equal(lang("Radfotos"), null);
});
