import { useCallback, useEffect, useState } from "react";

export interface Load<T> { data: T | null; error: unknown; loading: boolean; reload: () => void }

/** Runs an async loader on mount and whenever deps change; reload() runs it again. */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[] = []): Load<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  // the loader is recreated each render; deps decide when it runs
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const run = useCallback(fn, deps);
  useEffect(() => {
    let live = true;
    setLoading(true); setError(null);
    run().then((d) => { if (live) setData(d); }, (e) => { if (live) setError(e); }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [run, tick]);
  return { data, error, loading, reload: () => setTick((n) => n + 1) };
}
