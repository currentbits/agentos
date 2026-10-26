// Quick actions shared by Overview, Sessions, Desktops and System.
import { api } from './api';
import { navigate } from './router';

export async function openTerminal(): Promise<void> {
  try {
    const s = await api<{ id: string }>('/api/sessions', 'POST', { cli: 'shell' });
    navigate(`/sessions/${encodeURIComponent(s.id)}`);
  } catch (e) {
    alert((e as Error).message);
  }
}

export async function newDesktop(): Promise<void> {
  try {
    const d = await api<{ id: number }>('/api/desktops', 'POST');
    navigate(`/desktops/${d.id}`);
  } catch (e) {
    alert((e as Error).message);
  }
}
