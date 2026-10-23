import { createRoot } from 'react-dom/client';
import App from './App.jsx';

// 这里不套 React.StrictMode：它在开发模式下会把 effect 跑两遍，
// 而这个模板的 effect 里就要调 invoke / listen，双跑会让人误以为桥重复投递。
createRoot(document.getElementById('root')).render(<App />);
