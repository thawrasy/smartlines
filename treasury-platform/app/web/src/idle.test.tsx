import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SESSION_ENDED } from './api';
import { I18nProvider } from './i18n';
import { IdleGuard } from './ui';

// FR-PLT-014: an idle user is warned a minute before and then signed out; activity, or "stay signed in", resets the clock.
describe('IdleGuard', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { cleanup(); vi.useRealTimers(); });

  const mount = (onExpire: () => void, keepAlive = vi.fn(() => Promise.resolve())) =>
    render(<I18nProvider><IdleGuard minutes={3} keepAlive={keepAlive} onExpire={onExpire} /></I18nProvider>);

  it('warns a minute before and signs out at the idle time', () => {
    const expire = vi.fn();
    mount(expire);
    act(() => { vi.advanceTimersByTime(119_000); });
    expect(screen.queryByRole('alert')).toBeNull();
    act(() => { vi.advanceTimersByTime(6_000); });
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(expire).not.toHaveBeenCalled();
    act(() => { vi.advanceTimersByTime(60_000); });
    expect(expire).toHaveBeenCalledTimes(1);
  });

  it('counts activity and lets the user stay signed in', () => {
    const expire = vi.fn();
    const keepAlive = vi.fn(() => Promise.resolve());
    mount(expire, keepAlive);
    act(() => { vi.advanceTimersByTime(150_000); });
    fireEvent.click(screen.getByRole('button'));
    expect(keepAlive).toHaveBeenCalled();
    act(() => { vi.advanceTimersByTime(150_000); });
    fireEvent.keyDown(window);
    act(() => { vi.advanceTimersByTime(150_000); });
    expect(expire).not.toHaveBeenCalled();
  });

  it('leaves at once when the server ends the session', () => {
    const expire = vi.fn();
    mount(expire);
    act(() => { window.dispatchEvent(new Event(SESSION_ENDED)); });
    expect(expire).toHaveBeenCalledTimes(1);
  });
});
