import type { Channel } from "../../api/types";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { durationSeconds, humanDuration } from "../../lib/duration";

type Node = unknown;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? (value as unknown[]) : [];
}

function Channels({ value }: { value: unknown }) {
  return (
    <>
      {list(value).map((channel, index) => (
        <span key={index}>
          {index > 0 && ", "}
          <ChannelLabel channel={channel as Channel} />
        </span>
      ))}
    </>
  );
}

function After({ value }: { value: unknown }) {
  const { locale } = useI18n();
  const text = typeof value === "string" ? value : "";
  const seconds = durationSeconds(text);
  return (
    <span title={text}>
      {seconds === null ? text : humanDuration(seconds, locale)}
    </span>
  );
}

// WF-13
// WF-21
/** A route tree in words: fallback and fan-out lists, channel choices and escalation ladders with their waits and stop signals. */
export function RouteTree({ node }: { node: Node }) {
  const { t } = useI18n();
  if (typeof node === "string")
    return <ChannelLabel channel={node as Channel} />;
  if (!isRecord(node))
    return <code className="mono">{JSON.stringify(node)}</code>;
  if (
    typeof node.channel === "string" &&
    node.strategy === "last_active_device"
  )
    return (
      <span>
        <ChannelLabel channel={node.channel as Channel} />{" "}
        {t("route.lastDevice")}
      </span>
    );
  if (Array.isArray(node.single)) {
    const trigger = node.trigger;
    return (
      <div className="route-node">
        <span>
          {t("route.single")}
          {isRecord(trigger) && (
            <>
              {" · "}
              {t("route.afterDelay")} <After value={trigger.after_delay} />
            </>
          )}
        </span>
        <ol>
          {list(node.single).map((child, index) => (
            <li key={index}>
              <RouteTree node={child} />
            </li>
          ))}
        </ol>
      </div>
    );
  }
  if (Array.isArray(node.all))
    return (
      <div className="route-node">
        <span>{t("route.all")}</span>
        <ul>
          {list(node.all).map((child, index) => (
            <li key={index}>
              <RouteTree node={child} />
            </li>
          ))}
        </ul>
      </div>
    );
  if (Array.isArray(node.last_active))
    return (
      <span>
        {t("route.lastActive")} <Channels value={node.last_active} />
      </span>
    );
  if (Array.isArray(node.user_preference))
    return (
      <span>
        {t("route.preference")} <Channels value={node.user_preference} />
      </span>
    );
  if (isRecord(node.escalate)) {
    const escalate = node.escalate;
    const unless = typeof escalate.unless === "string" ? escalate.unless : "";
    return (
      <div className="route-node" data-escalate>
        <span>
          {t("route.escalate", { unless })}
          {typeof escalate.event_type === "string" && (
            <>
              {" "}
              <code className="mono">{escalate.event_type}</code>
            </>
          )}
        </span>
        <ol>
          {list(escalate.ladder).map((rung, index) => (
            <li key={index}>
              {isRecord(rung) ? (
                <>
                  {t("route.after")} <After value={rung.after} />
                  {" → "}
                  <RouteTree node={rung.node} />
                </>
              ) : null}
            </li>
          ))}
        </ol>
      </div>
    );
  }
  return <code className="mono">{JSON.stringify(node)}</code>;
}
