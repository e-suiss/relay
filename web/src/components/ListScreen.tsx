import type { ReactNode } from "react";
import type { QueryValue } from "../api/client";
import { usePaged } from "../api/hooks";
import { DataTable, Loadable, Pager, Section, type Column } from "./data";

/** A paged API list as a table, with an optional detail rendered under each page. */
export function PagedTable<T>({
  title,
  path,
  query,
  columns,
  rowKey,
  after,
}: {
  title: string;
  path: string;
  query?: Record<string, QueryValue>;
  columns: readonly Column<T>[];
  rowKey: (row: T) => string;
  after?: (rows: readonly T[], reload: () => void) => ReactNode;
}) {
  const paged = usePaged<T>(path, query);
  return (
    <Section title={title}>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <>
            {(columns.length > 0 || paged.items.length === 0) && (
              <DataTable
                caption={title}
                columns={columns}
                rows={paged.items}
                rowKey={rowKey}
              />
            )}
            {paged.items.length > 0 && after?.(paged.items, paged.reload)}
          </>
        )}
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </Section>
  );
}
