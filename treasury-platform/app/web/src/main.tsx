import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';

function App() {
  return <main><h1>BankFas</h1></main>;
}

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
