import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { I18nProvider } from './i18n';
import { Panel } from './operator/Panel';
import { Portal } from './portal/Portal';
import './styles.css';

// One bundle, two surfaces: the operator panel on admin.<domain>, a tenant portal on every other sub-domain (ADR 0040).
const operator = window.location.hostname.startsWith('admin.');

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>
      <BrowserRouter>{operator ? <Panel /> : <Portal />}</BrowserRouter>
    </I18nProvider>
  </StrictMode>,
);
