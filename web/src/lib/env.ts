export const API_BASE = (import.meta.env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/, '');

export const WAITLIST_MODE: 'email' | 'api' = import.meta.env.PUBLIC_WAITLIST_MODE === 'email' ? 'email' : 'api';

export const TURNSTILE_SITEKEY: string = WAITLIST_MODE === 'api' ? import.meta.env.PUBLIC_TURNSTILE_SITEKEY || '' : '';
