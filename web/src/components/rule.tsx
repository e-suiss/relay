import { useI18n } from "../i18n/i18n";

export interface RuleDescription {
  en: string;
  tr: string;
}

// X-1
// X-12
/** A rule decision: the `rule_id` and the rule dictionary's own sentence; the console writes no text of its own. */
export function RuleSentence({
  ruleId,
  description,
}: {
  ruleId: string | null | undefined;
  description?: RuleDescription | null;
}) {
  const { locale } = useI18n();
  if (ruleId === null || ruleId === undefined) return <>—</>;
  const sentence = description ? description[locale] : null;
  return (
    <span className="rule" data-rule-id={ruleId}>
      <code className="mono">{ruleId}</code>
      {sentence && <span className="rule-sentence">{sentence}</span>}
    </span>
  );
}
