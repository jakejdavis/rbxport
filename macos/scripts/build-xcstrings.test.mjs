// Run with: node --test macos/scripts/build-xcstrings.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { HARDWARE_LABELS, APPLE_LOCALES, buildCatalog, convertPlaceholders, loadLocales, serialize, swiftLiterals } from "./build-xcstrings.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const locales = loadLocales();
const used = swiftLiterals(join(root, "macos", "App"));
const catalog = buildCatalog(locales, used);
const full = buildCatalog(locales, null);

test("placeholders become %@ or positional specifiers", () => {
  assert.equal(convertPlaceholders("{count} minutes ago"), "%@ minutes ago");
  assert.equal(convertPlaceholders("Creating backup: {percent}% — {copied} of {total}"), "Creating backup: %1$@%% — %2$@ of %3$@");
  assert.equal(convertPlaceholders("{a} then {b}, then {a}"), "%1$@ then %2$@, then %1$@");
  assert.equal(convertPlaceholders("No placeholders, 100%"), "No placeholders, 100%");
});

test("a translation may reorder the placeholders", () => {
  const out = buildCatalog({ de: { "{a} of {b}": "{b} von {a}" } });
  assert.equal(out.strings["%1$@ of %2$@"].localizations.de.stringUnit.value, "%2$@ von %1$@");
});

test("a placeholder mismatch fails the build", () => {
  assert.throws(() => buildCatalog({ de: { "{a} of {b}": "{a} von" } }), /placeholder mismatch/);
});

test("values identical to the key are skipped, and keys with no translation are dropped", () => {
  const out = buildCatalog({ de: { Same: "Same", Other: "Anders" }, fr: { Same: "Same", None: "None" } });
  assert.deepEqual(Object.keys(out.strings), ["Other"]);
  assert.deepEqual(Object.keys(out.strings.Other.localizations), ["de"]);
});

test("locale codes map to Apple's", () => {
  assert.equal(APPLE_LOCALES["zh-CN"], "zh-Hans");
  assert.equal(APPLE_LOCALES["zh-TW"], "zh-Hant");
  const out = buildCatalog({ "zh-CN": { Rename: "重命名" }, "zh-TW": { Rename: "重新命名" } });
  assert.deepEqual(Object.keys(out.strings.Rename.localizations), ["zh-Hans", "zh-Hant"]);
  assert.equal(out.strings.Rename.localizations["zh-Hans"].stringUnit.value, "重命名");
});

test("the real catalog is English-sourced, covers 17 languages and the used keys", () => {
  assert.equal(catalog.sourceLanguage, "en");
  const languages = new Set();
  for (const entry of Object.values(catalog.strings)) for (const l of Object.keys(entry.localizations)) languages.add(l);
  assert.deepEqual([...languages].sort(), Object.values(APPLE_LOCALES).sort());
  const count = Object.keys(catalog.strings).length;
  assert.ok(count > 300 && count < Object.keys(full.strings).length, `used-only count ${count}`);
  assert.ok(Object.keys(full.strings).length > 1400);
  assert.equal(catalog.strings.Rename.localizations.de.stringUnit.value, "Umbenennen");
  // Every key Swift calls with a template is in the catalog in its converted form.
  assert.ok(catalog.strings["%@ minutes ago"], "template key present");
  for (const value of Object.values(catalog.strings).flatMap((e) => Object.values(e.localizations))) {
    assert.notEqual(value.stringUnit.value.trim(), "");
  }
});

test("the checked-in catalog is what the script produces now", () => {
  const onDisk = readFileSync(join(root, "macos", "App", "Localizable.xcstrings"), "utf8");
  assert.equal(onDisk, serialize(catalog) + "\n");
});

test("deck hardware labels are never in the catalog, and values are trimmed", () => {
  for (const label of HARDWARE_LABELS) {
    assert.equal(full.strings[label], undefined, label);
  }
  for (const label of ["CUE", "OUT", "MEMORY", "GRID", "Q", "RESET"]) assert.ok(HARDWARE_LABELS.has(label));
  assert.equal(catalog.strings.Key.localizations.de.stringUnit.value, "Tonart");
  for (const entry of Object.values(full.strings)) {
    for (const u of Object.values(entry.localizations)) assert.equal(u.stringUnit.value, u.stringUnit.value.trim());
  }
});
