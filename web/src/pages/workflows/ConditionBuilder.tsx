import { useId, useState } from "react";
import { useI18n } from "../../i18n/i18n";
import {
  emptyRule,
  fromCondition,
  operators,
  pathPattern,
  ruleComplete,
  toCondition,
  valueKinds,
  type Operator,
  type PathOption,
  type Rule,
  type RuleGroup,
} from "./condition";
import type { Condition } from "./model";

const custom = "__custom__";

function RuleRow({
  rule,
  index,
  options,
  incoming,
  disabled,
  onChange,
  onRemove,
}: {
  rule: Rule;
  index: number;
  options: readonly PathOption[];
  incoming: boolean;
  disabled: boolean;
  onChange: (rule: Rule) => void;
  onRemove: (() => void) | null;
}) {
  const { t } = useI18n();
  const ids = { path: useId(), custom: useId(), op: useId(), kind: useId(), value: useId() };
  const known = options.some((option) => option.path === rule.path);
  const [typing, setTyping] = useState(!known && rule.path !== "");
  const unary = rule.operator === "exists" || rule.operator === "not_exists";
  const groups = [...new Set(options.map((option) => option.group))];
  return (
    <fieldset
      className="rule-row"
      data-rule-complete={ruleComplete(rule)}
      disabled={disabled}
    >
      <legend className="visually-hidden">
        {t("cond.rule", { n: index + 1 })}
      </legend>
      <div className="field">
        <label htmlFor={ids.path}>{t("cond.path")}</label>
        <select
          id={ids.path}
          value={typing ? custom : rule.path}
          onChange={(event) => {
            if (event.target.value === custom) {
              setTyping(true);
              return;
            }
            setTyping(false);
            onChange({ ...rule, path: event.target.value });
          }}
        >
          <option value="">{t("cond.choosePath")}</option>
          {groups.map((group) => (
            <optgroup key={group} label={t(`cond.group.${group}`)}>
              {options
                .filter((option) => option.group === group)
                .map((option) => (
                  <option key={option.path} value={option.path}>
                    {option.path}
                  </option>
                ))}
            </optgroup>
          ))}
          <option value={custom}>
            {incoming ? t("cond.otherIncoming") : t("cond.otherData")}
          </option>
        </select>
      </div>
      {typing && (
        <div className="field">
          <label htmlFor={ids.custom}>{t("cond.customPath")}</label>
          <input
            id={ids.custom}
            value={rule.path}
            placeholder={incoming ? "incoming.order.id" : "data.order.id"}
            aria-invalid={rule.path !== "" && !pathPattern.test(rule.path)}
            onChange={(event) => {
              onChange({ ...rule, path: event.target.value.trim() });
            }}
          />
        </div>
      )}
      <div className="field">
        <label htmlFor={ids.op}>{t("cond.operator")}</label>
        <select
          id={ids.op}
          value={rule.operator}
          onChange={(event) => {
            onChange({ ...rule, operator: event.target.value as Operator });
          }}
        >
          {operators.map((operator) => (
            <option key={operator} value={operator}>
              {t(`cond.op.${operator}`)}
            </option>
          ))}
        </select>
      </div>
      {!unary && (
        <>
          <div className="field">
            <label htmlFor={ids.kind}>{t("cond.kind")}</label>
            <select
              id={ids.kind}
              value={rule.kind}
              onChange={(event) => {
                onChange({ ...rule, kind: event.target.value as Rule["kind"] });
              }}
            >
              {valueKinds.map((kind) => (
                <option key={kind} value={kind}>
                  {t(`cond.kind.${kind}`)}
                </option>
              ))}
            </select>
          </div>
          {rule.kind === "boolean" ? (
            <div className="field">
              <label htmlFor={ids.value}>{t("cond.value")}</label>
              <select
                id={ids.value}
                value={rule.value}
                onChange={(event) => {
                  onChange({ ...rule, value: event.target.value });
                }}
              >
                <option value="">{t("cond.chooseValue")}</option>
                <option value="true">{t("common.yes")}</option>
                <option value="false">{t("common.no")}</option>
              </select>
            </div>
          ) : rule.kind === "null" ? null : (
            <div className="field">
              <label htmlFor={ids.value}>
                {rule.kind === "list" ? t("cond.listValue") : t("cond.value")}
              </label>
              <input
                id={ids.value}
                inputMode={rule.kind === "number" ? "decimal" : undefined}
                value={rule.value}
                onChange={(event) => {
                  onChange({ ...rule, value: event.target.value });
                }}
              />
            </div>
          )}
        </>
      )}
      {onRemove && (
        <button type="button" onClick={onRemove}>
          {t("cond.removeRule")}
        </button>
      )}
    </fieldset>
  );
}

// WF-60
// X-10
/** Builds a condition from lists: each rule picks a path, an operator and a typed value; rules join with all or any. A condition the lists cannot show is kept as it is and can only be replaced. */
export function ConditionBuilder({
  condition,
  options,
  incoming = false,
  disabled,
  onChange,
}: {
  condition: Condition | undefined;
  options: readonly PathOption[];
  incoming?: boolean;
  disabled: boolean;
  onChange: (condition: Condition | undefined) => void;
}) {
  const { t } = useI18n();
  const joinId = useId();
  const group: RuleGroup | null =
    condition === undefined
      ? { join: "all", rules: [] }
      : fromCondition(condition);

  if (group === null)
    return (
      <div className="stack" data-condition-complex>
        <p className="notice small">{t("cond.complex")}</p>
        <pre className="plain-text" tabIndex={0}>
          {JSON.stringify(condition, null, 2)}
        </pre>
        <span>
          <button
            type="button"
            disabled={disabled}
            onClick={() => {
              onChange(toCondition({ join: "all", rules: [emptyRule()] }));
            }}
          >
            {t("cond.replace")}
          </button>
        </span>
      </div>
    );

  const update = (next: RuleGroup) => {
    onChange(next.rules.length === 0 ? undefined : toCondition(next));
  };

  return (
    <div className="stack condition-builder">
      {group.rules.length > 1 && (
        <div className="field">
          <label htmlFor={joinId}>{t("cond.join")}</label>
          <select
            id={joinId}
            value={group.join}
            disabled={disabled}
            onChange={(event) => {
              update({ ...group, join: event.target.value as RuleGroup["join"] });
            }}
          >
            <option value="all">{t("cond.join.all")}</option>
            <option value="any">{t("cond.join.any")}</option>
          </select>
        </div>
      )}
      {group.rules.map((rule, index) => (
        <RuleRow
          key={index}
          rule={rule}
          index={index}
          options={options}
          incoming={incoming}
          disabled={disabled}
          onChange={(next) => {
            update({
              ...group,
              rules: group.rules.map((item, at) => (at === index ? next : item)),
            });
          }}
          onRemove={
            group.rules.length > 1 || incoming
              ? () => {
                  update({
                    ...group,
                    rules: group.rules.filter((_item, at) => at !== index),
                  });
                }
              : null
          }
        />
      ))}
      <span>
        <button
          type="button"
          disabled={disabled || group.rules.length >= 16}
          onClick={() => {
            update({ ...group, rules: [...group.rules, emptyRule()] });
          }}
        >
          {t("cond.addRule")}
        </button>
      </span>
    </div>
  );
}
