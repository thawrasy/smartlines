// How long a saved ticket is shown without a connection: 72 hours after the last check with the server (the proposal
// of 10 October 2026). After that the passenger must connect before the ticket shows, because a cancellation or a
// change may have happened. A clock set back is refused too (the check cannot lie about the future).
export const OFFLINE_SHOW_SECONDS = 72 * 3600;
const CLOCK_SLACK_SECONDS = 300;

export function isFresh(verifiedAt: number | undefined, nowSeconds: number): boolean {
  if (verifiedAt === undefined) return false;
  const age = nowSeconds - verifiedAt;
  return age >= -CLOCK_SLACK_SECONDS && age < OFFLINE_SHOW_SECONDS;
}
