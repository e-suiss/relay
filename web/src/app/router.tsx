import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type AnchorHTMLAttributes,
  type MouseEvent,
  type ReactNode,
} from "react";

export const basePath = "/console";

export interface Location {
  path: string;
  search: URLSearchParams;
}

interface Router {
  location: Location;
  navigate: (to: string, options?: { replace?: boolean }) => void;
}

const RouterContext = createContext<Router | null>(null);

export function stripBase(pathname: string): string {
  if (pathname === basePath) return "/";
  if (pathname.startsWith(`${basePath}/`)) {
    const rest = pathname.slice(basePath.length);
    return rest.length > 1 && rest.endsWith("/") ? rest.slice(0, -1) : rest;
  }
  return pathname;
}

export function href(to: string): string {
  return to === "/" ? `${basePath}/` : `${basePath}${to}`;
}

function current(): Location {
  return {
    path: stripBase(window.location.pathname),
    search: new URLSearchParams(window.location.search),
  };
}

export function RouterProvider({ children }: { children: ReactNode }) {
  const [location, setLocation] = useState<Location>(current);

  useEffect(() => {
    const onPop = () => {
      setLocation(current());
    };
    window.addEventListener("popstate", onPop);
    return () => {
      window.removeEventListener("popstate", onPop);
    };
  }, []);

  const navigate = useCallback(
    (to: string, options: { replace?: boolean } = {}) => {
      if (options.replace) window.history.replaceState(null, "", href(to));
      else window.history.pushState(null, "", href(to));
      setLocation(current());
      window.scrollTo(0, 0);
    },
    [],
  );

  const value = useMemo(() => ({ location, navigate }), [location, navigate]);
  return <RouterContext value={value}>{children}</RouterContext>;
}

export function useRouter(): Router {
  const value = useContext(RouterContext);
  if (value === null) throw new Error("useRouter outside RouterProvider");
  return value;
}

export type Params = Record<string, string>;

/** Matches a console path against a pattern such as `/workflows/:key`; a trailing `/*` matches any rest. */
export function match(pattern: string, path: string): Params | null {
  const wanted = pattern.split("/").filter(Boolean);
  const given = path.split("/").filter(Boolean);
  const params: Params = {};
  for (const [index, part] of wanted.entries()) {
    if (part === "*") {
      params["*"] = given.slice(index).map(decodeURIComponent).join("/");
      return params;
    }
    const value = given[index];
    if (value === undefined) return null;
    if (part.startsWith(":")) params[part.slice(1)] = decodeURIComponent(value);
    else if (part !== value) return null;
  }
  return given.length === wanted.length ? params : null;
}

type LinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href"> & {
  to: string;
};

export function Link({ to, onClick, children, ...rest }: LinkProps) {
  const { navigate } = useRouter();
  const handle = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event);
    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;
    event.preventDefault();
    navigate(to);
  };
  return (
    <a href={href(to)} onClick={handle} {...rest}>
      {children}
    </a>
  );
}
