import { api } from './api';
import { Link, usePath } from './router';
import type { Me } from './types';
import { usePoll } from './usePoll';
// Pages (one import per task):
import { Overview } from './pages/Overview';
import { Settings } from './pages/Settings';

const NAV = [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']];

function page(path: string, me: Me | null) {
  const [, section, arg] = path.split('/');
  switch (section) {
    case 'settings': return <Settings me={me} />;
    default: return <Overview />;
  }
}

export function App() {
  const path = usePath();
  const { data: me } = usePoll(() => api<Me>('/api/me'));
  const section = '/' + (path.split('/')[1] ?? '');
  return (
    <div className="layout">
      <header>
        <strong>AgentOS</strong>
        <span>{me?.hostname}</span>
        <span>{me?.tailnetIp ?? 'tailnet down'}</span>
        <span className="login">{me?.login}</span>
      </header>
      <nav>
        {NAV.map(([to, label]) => <Link key={to} to={to} className={section === to ? 'active' : ''}>{label}</Link>)}
      </nav>
      <main>{page(path, me)}</main>
    </div>
  );
}
