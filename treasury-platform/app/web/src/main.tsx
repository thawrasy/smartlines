import { lazy, StrictMode, Suspense } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { I18nProvider } from './i18n';
// The operator panel and the portal are separate chunks: a tenant never downloads the panel, nor an operator the portal.
const Panel = lazy(async () => ({ default: (await import('./operator/Panel')).Panel }));
const Portal = lazy(async () => ({ default: (await import('./portal/Portal')).Portal }));
import './styles.css';

// One bundle, two surfaces: the operator panel on admin.<domain>, a tenant portal on every other sub-domain (ADR 0040).
const operator = window.location.hostname.startsWith('admin.');

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>
      <BrowserRouter><Suspense fallback={null}>{operator ? <Panel /> : <Portal />}</Suspense></BrowserRouter>
    </I18nProvider>
  </StrictMode>,
);
