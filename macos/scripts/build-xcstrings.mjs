#!/usr/bin/env node
// Builds macos/App/Localizable.xcstrings from public/locales/*.json (the React app's catalogs,
// keyed by the English source string). Repo files only; no network.
//
//   node macos/scripts/build-xcstrings.mjs            # keys the Swift UI uses (default)
//   node macos/scripts/build-xcstrings.mjs --all      # every key in the locale files
//   node macos/scripts/build-xcstrings.mjs --out path # write somewhere else
//
// A key is "used" when its text appears as a string literal in macos/App/**/*.swift (Mock*.swift
// and tests excluded). Placeholders `{name}` become `%@` (one placeholder) or `%1$@`, `%2$@`
// (several), in order of first appearance; a literal `%` becomes `%%`. Swift's L10n helper builds
// the same key from the same template (App/L10n.swift), so the two must stay in step.
// Values equal to their key are skipped (no real translation). Locale codes map to Apple's.
// Hardware labels (CUE, LOOP, ...) are never included; see HARDWARE_LABELS. Output is sorted and stable, so re-running changes nothing unless the inputs changed.

import { readFileSync, readdirSync, writeFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** React locale code -> Apple language code. */
export const APPLE_LOCALES = {
  fr: "fr", de: "de", es: "es", it: "it", nl: "nl", ru: "ru", pt: "pt", sv: "sv", da: "da",
  tr: "tr", el: "el", hu: "hu", cs: "cs", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", ko: "ko", ja: "ja",
};

const PLACEHOLDER = /\{([A-Za-z_][A-Za-z0-9_]*)\}/g;

/** Placeholder names of a template, in order of first appearance. */
export function placeholderNames(text) {
  const names = [];
  for (const m of text.matchAll(PLACEHOLDER)) if (!names.includes(m[1])) names.push(m[1]);
  return names;
}

/** `{name}` -> `%@` / `%1$@` (order given by `names`); literal `%` -> `%%`. */
export function convertPlaceholders(text, names = placeholderNames(text)) {
  if (names.length === 0) return text;
  const spec = (name) => (names.length === 1 ? "%@" : `%${names.indexOf(name) + 1}$@`);
  return text
    .split(PLACEHOLDER)
    .map((part, i) => (i % 2 === 1 ? spec(part) : part.replaceAll("%", "%%")))
    .join("");
}

/**
 * Deck, transport and mixer labels that stay English in every language, as on a CDJ and in rekordbox.
 * They are left out of the catalog, so nothing (a SwiftUI literal or L10n.t) can translate them.
 * Their tooltips are other keys and stay translated.
 */
export const HARDWARE_LABELS = new Set([
  "CUE", "PLAY", "IN", "OUT", "RELOOP", "EXIT", "LOOP", "MEMORY", "SET", "DEL", "GRID", "MARK", "TAP", "Q",
  "MASTER TEMPO", "RESET", "BEAT SYNC", "SYNC", "MASTER", "KEY", "TRIM", "LOW", "MID", "HIGH", "KILL",
  "DUAL CONTROL", "BARS", "Beats", "4Beats", "8Beats", "16Beats", "8Bars", "16Bars", "32Bars",
]);

/** Every string literal in the Swift UI sources, unescaped. */
export function swiftLiterals(dir) {
  const found = new Set();
  const visit = (d) => {
    for (const name of readdirSync(d).sort()) {
      const path = join(d, name);
      if (statSync(path).isDirectory()) visit(path);
      else if (name.endsWith(".swift") && !name.startsWith("Mock")) {
        const source = readFileSync(path, "utf8");
        for (const m of source.matchAll(/"((?:[^"\\\n]|\\.)*)"/g)) {
          const text = unescapeSwift(m[1]);
          found.add(text);
          // A menu title with an ellipsis borrows the words of the key without one (L10n.t).
          if (text.endsWith("\u2026")) found.add(text.slice(0, -1));
        }
      }
    }
  };
  visit(dir);
  return found;
}

function unescapeSwift(text) {
  return text
    .replace(/\\u\{([0-9A-Fa-f]+)\}/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/\\(["\\nt'])/g, (_, c) => ({ n: "\n", t: "\t" })[c] ?? c);
}

/** Build the catalog object. `locales` maps React code -> { english: translated }. */
export function buildCatalog(locales, usedKeys = null) {
  const keys = new Set();
  for (const table of Object.values(locales)) for (const key of Object.keys(table)) keys.add(key);
  const strings = {};
  for (const key of [...keys].sort()) {
    if (usedKeys && !usedKeys.has(key)) continue;
    if (HARDWARE_LABELS.has(key)) continue;
    const names = placeholderNames(key);
    const localizations = {};
    for (const code of Object.keys(APPLE_LOCALES)) {
      let value = locales[code]?.[key];
      // Some catalog values carry a stray newline or space the source key does not have.
      if (value !== undefined && key.trim() === key) value = value.trim();
      if (value === undefined || value === key || value.trim() === "") continue;
      const got = placeholderNames(value);
      if (got.length !== names.length || got.some((n) => !names.includes(n))) {
        throw new Error(`placeholder mismatch in ${code} for ${JSON.stringify(key)}: ${JSON.stringify(value)}`);
      }
      localizations[APPLE_LOCALES[code]] = { stringUnit: { state: "translated", value: convertPlaceholders(value, names) } };
    }
    if (Object.keys(localizations).length === 0) continue;
    const sorted = Object.fromEntries(Object.entries(localizations).sort(([a], [b]) => (a < b ? -1 : 1)));
    strings[convertPlaceholders(key, names)] = { extractionState: "manual", localizations: sorted };
  }
  return { sourceLanguage: "en", strings, version: "1.0" };
}

/** Xcode's own layout: two-space indent and `"key" : value`. */
export function serialize(value, indent = "") {
  if (Array.isArray(value)) return `[${value.map((v) => serialize(v, indent)).join(", ")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length === 0) return "{\n" + indent + "}";
    const inner = indent + "  ";
    return "{\n" + entries.map(([k, v]) => `${inner}${JSON.stringify(k)} : ${serialize(v, inner)}`).join(",\n") + "\n" + indent + "}";
  }
  return JSON.stringify(value);
}

export function loadLocales(dir = join(root, "public", "locales")) {
  const locales = {};
  for (const code of Object.keys(APPLE_LOCALES)) locales[code] = JSON.parse(readFileSync(join(dir, `${code}.json`), "utf8"));
  return locales;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const out = args.includes("--out") ? resolve(args[args.indexOf("--out") + 1]) : join(root, "macos", "App", "Localizable.xcstrings");
  const used = args.includes("--all") ? null : swiftLiterals(join(root, "macos", "App"));
  const catalog = buildCatalog(loadLocales(), used);
  writeFileSync(out, serialize(catalog) + "\n");
  console.log(`${Object.keys(catalog.strings).length} keys, ${Object.keys(APPLE_LOCALES).length} locales -> ${out}`);
}
