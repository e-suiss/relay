# Translations

Relay's own product texts (the console, the components and these docs' interface) and your templates are translated in different places.

## Your templates

Templates have one variant per channel and locale. The console shows the channel by locale matrix with missing locales highlighted, and a notification for a locale that has no variant falls back along the locale chain and records `template_locale_missing`. Plural forms use the CLDR categories of each language. See the template operations in the [API reference](/reference/).

## Relay's product texts

Product texts are kept as catalogs of keys and texts, one file per locale, with English as the base. A pull request that changes a catalog runs a check that fails when:

- a key of the base catalog has no translation, or a translation has a key the base does not,
- a text is empty,
- a translation uses a different set of placeholders than the base text, such as `{count}` in English but `{total}` in Turkish.

The same check writes a pseudo-locale for every catalog: each text with accented letters, about a third longer and wrapped in `⟦ ⟧`, with its placeholders untouched. Running the interface in the pseudo-locale shows texts that are not translatable (they appear without the brackets), layouts that break with longer languages and characters a font cannot render, before a real translation exists.

Translators work in a translation management system on the same catalog files; every change comes back as a pull request and goes through the check.
