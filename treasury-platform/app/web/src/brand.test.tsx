import { describe, expect, it } from 'vitest';
import { render } from '@testing-library/react';
import { Chip, toneOf } from './brand';
import { I18nProvider } from './i18n';

// The status tones of the identity guide (p.13): an unknown code never reads as a success.
describe('toneOf', () => {
  it('reads the common states', () => {
    expect(toneOf('ACTIVE')).toBe('done');
    expect(toneOf('APPROVED')).toBe('done');
    expect(toneOf('DRAFT')).toBe('draft');
    expect(toneOf('PENDING_APPROVAL')).toBe('review');
    expect(toneOf('IN_COMMITTEE')).toBe('committee');
    expect(toneOf('REJECTED')).toBe('stop');
    expect(toneOf('OVERDUE')).toBe('stop');
  });
  it('keeps the negative forms apart', () => {
    expect(toneOf('INACTIVE')).toBe('draft');
    expect(toneOf('DISABLED')).toBe('draft');
    expect(toneOf('INCOMPLETE')).toBe('review');
    expect(toneOf('INVALID')).toBe('stop');
    expect(toneOf('NON_COMPLIANT')).toBe('stop');
    expect(toneOf('SOMETHING_NEW')).toBe('draft');
  });
});

describe('Chip', () => {
  it('shows the mark and a readable word', () => {
    localStorage.setItem('bf.lang', 'en');
    const { container } = render(<I18nProvider><Chip s="SOMETHING_NEW" /></I18nProvider>);
    expect(container.querySelector('.chip.draft')?.textContent).toBe('○ Something new');
  });
});
