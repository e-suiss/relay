export type PluralCategory = Intl.LDMLPluralRule;

const order: readonly PluralCategory[] = [
  "zero",
  "one",
  "two",
  "few",
  "many",
  "other",
];

// TP-27
/** The CLDR cardinal plural categories of a language, in canonical order; `other` is always one of them. */
export function pluralCategories(locale: string): PluralCategory[] {
  let found: readonly PluralCategory[];
  try {
    found = new Intl.PluralRules(locale).resolvedOptions().pluralCategories;
  } catch {
    found = ["other"];
  }
  return order.filter((category) => found.includes(category));
}

const liquid = /(\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\})/;

function escapeLiteral(text: string): string {
  return text.replace(/'/g, "''").replace(/[{}]/g, (brace) => `'${brace}'`);
}

/** Escapes a form text for classic ICU MessageFormat, leaving Liquid output and tags as written. */
export function icuEscape(text: string): string {
  return text
    .split(liquid)
    .map((part, index) => (index % 2 === 1 ? part : escapeLiteral(part)))
    .join("");
}

export const variablePattern = /^data(\.[A-Za-z0-9_-]{1,128})+$/;

export interface PluralForms {
  variable: string;
  zero: string | null;
  forms: Partial<Record<PluralCategory, string>>;
}

// TP-27
/** The ICU message of a plural field: an optional `=0` match and one form per category of the language. */
export function icuMessage(value: PluralForms, locale: string): string {
  const options = [
    ...(value.zero === null ? [] : [`=0 {${icuEscape(value.zero)}}`]),
    ...pluralCategories(locale).map(
      (category) => `${category} {${icuEscape(value.forms[category] ?? "")}}`,
    ),
  ];
  return `{n, plural, ${options.join(" ")}}`;
}

// TP-27
/** The Liquid that renders a plural field through the `icu` filter: the message is captured under a name and formatted with the variable as `n`. */
export function pluralSnippet(
  name: string,
  value: PluralForms,
  locale: string,
): string {
  return `{% capture ${name} %}${icuMessage(value, locale)}{% endcapture %}{{ ${name} | icu: n: ${value.variable} }}`;
}

/** A capture name not yet used in the text. */
export function freshName(text: string): string {
  let index = 1;
  while (text.includes(`plural_${index}`)) index += 1;
  return `plural_${index}`;
}

/** What the plural field reads for a sample count, to show beside the inputs. */
export function samplePlural(
  value: PluralForms,
  count: number,
  locale: string,
): string {
  const number = new Intl.NumberFormat(locale).format(count);
  if (count === 0 && value.zero !== null)
    return value.zero.replace(/#/g, number);
  const category = new Intl.PluralRules(locale).select(count);
  return (value.forms[category] ?? value.forms.other ?? "").replace(
    /#/g,
    number,
  );
}
