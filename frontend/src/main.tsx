import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource/ibm-plex-sans-arabic/300.css";
import "@fontsource/ibm-plex-sans-arabic/400.css";
import "@fontsource/ibm-plex-sans-arabic/500.css";
import "@fontsource/ibm-plex-sans-arabic/600.css";
import "@fontsource/ibm-plex-sans-arabic/700.css";
import "@fontsource/readex-pro/600.css";
import "@fontsource/readex-pro/700.css";
import "./theme.css";
import { I18nProvider } from "./i18n";
import { AuthProvider } from "./auth";
import { ToastProvider } from "./components/ui";
import { ModulesProvider } from "./modules/context";
import App from "./App";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <I18nProvider>
      <AuthProvider>
        <ModulesProvider>
          <ToastProvider>
            <App />
          </ToastProvider>
        </ModulesProvider>
      </AuthProvider>
    </I18nProvider>
  </StrictMode>,
);
