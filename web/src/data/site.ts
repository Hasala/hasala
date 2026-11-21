import { WAITLIST_MODE } from '../lib/env';

export const MAIL_PROVIDERS = ['Gmail', 'Outlook'] as const;
export const MAIL = new Intl.ListFormat('en', { type: 'disjunction' }).format(MAIL_PROVIDERS);
export const MAIL_PERSONAL = 'Gmail or personal Outlook';
export const MAIL_NOTE = 'Hasala works with Gmail and with personal Outlook accounts (outlook.com, hotmail.com and live.com) for now. Work and school accounts aren’t supported yet.';

export const SITE = {
  name: 'Hasala',
  arabicName: 'حصّالة',
  appStoreName: 'Hasala Budgeting',
  url: 'https://hasala.app',
  tagline: 'A private budgeting app that shows where your money goes.',
  description:
    "Hasala is a private budgeting app for iPhone in the UAE. It reads your bank's alerts, by email or text, and shows where your money goes. Your transactions and budget are encrypted on your iPhone, so we can't read them.",
  shortDescription: 'Hasala (حصّالة) is Arabic for piggy bank.',
  supportEmail: 'support@hasala.app',
  privacyEmail: 'privacy@hasala.app',
  securityEmail: 'security@hasala.app',
  mailFrom: 'no-reply@hasala.app',
  ogImage: '/og-image.png',
  ogImageAlt: 'Hasala: a private budgeting app that shows where your money goes. For iPhone, in the UAE.',
  testFlightAppStore: 'https://apps.apple.com/app/testflight/id899247664',
  repoUrl: 'https://github.com/salehtl/hasala',
  licenseUrl: 'https://github.com/salehtl/hasala/blob/main/LICENSE.md',
  trademarksUrl: 'https://github.com/salehtl/hasala/blob/main/TRADEMARKS.md',
  requirements: `You’ll need an iPhone with iOS 26 or later, and your bank’s alerts by text or in a ${MAIL_PERSONAL} address. The app is in English only for now.`,
} as const;

export const BANKS = [
  { value: 'dib', name: 'Dubai Islamic Bank', short: 'DIB' },
  { value: 'enbd', name: 'Emirates NBD', short: 'ENBD' },
  { value: 'adib', name: 'Abu Dhabi Islamic Bank', short: 'ADIB' },
] as const;

export const OTHER_BANKS = [
  { value: 'adcb', name: 'ADCB' },
  { value: 'emirates-islamic', name: 'Emirates Islamic' },
  { value: 'fab', name: 'First Abu Dhabi Bank' },
  { value: 'liv', name: 'Liv' },
  { value: 'mashreq', name: 'Mashreq' },
  { value: 'rakbank', name: 'RAKBANK' },
  { value: 'wio', name: 'Wio' },
] as const;

export const NAV = [
  { href: '/how-it-works', label: 'How it works' },
  { href: '/budgeting', label: 'Budgeting' },
  { href: '/how-privacy-works', label: 'How privacy works' },
  { href: '/faq', label: 'FAQ' },
] as const;

export const FOOTER = [
  {
    title: 'Hasala',
    links: [
      ...NAV,
      { href: '/#invite', label: 'Request an invite' },
      { href: '/i', label: 'Have an invite code?' },
    ],
  },
  {
    title: 'Help',
    links: [
      { href: '/support', label: 'Support' },
      { href: '/security', label: 'Security' },
      { href: `mailto:${SITE.supportEmail}`, label: 'Contact' },
    ],
  },
  {
    title: 'Legal',
    links: [
      { href: '/privacy', label: 'Privacy Policy' },
      { href: '/terms', label: 'Terms of Service' },
      { href: '/licenses', label: 'Licences' },
    ],
  },
] as const;

export const VISIBILITY = [
  { who: 'You', sees: 'Everything, on your own devices', never: null },
  {
    who: 'Hasala, our server',
    sees: 'What it needs to run your account: your email address and name, when you sync, how much encrypted data you keep, and when new mail reaches your inbox. It also keeps sign‑in and device details: your passkey’s public key or a scrambled form of your password, your devices’ push tokens, and a scrambled form of the email address you connect',
    never: 'Your emails, amounts, merchants, categories, budget or plan',
  },
  {
    who: 'Cloudflare, our network provider',
    sees: 'Your requests on their way to our server: your IP address, times, sizes and the still‑encrypted data. It also sends our emails to you, and counts visits to this website for us, in totals only. If you turn on Cloud suggestions, its AI service sees the merchant names Hasala asks about, without your name or account',
    never: 'What’s inside the encrypted data',
  },
  {
    who: 'Your email provider',
    sees: 'Your email, as it already does, and that you’ve given Hasala read‑only access',
    never: 'Your budget, or anything Hasala works out',
  },
  {
    who: 'Apple',
    sees: 'Your email address, because it handles your TestFlight invitation, and that you’ve installed Hasala. If you use a passkey, it syncs in iCloud Keychain, end‑to‑end encrypted by Apple',
    never: 'Your transactions or your plan',
  },
] as const;

const ASK_FOR_INVITE =
  WAITLIST_MODE === 'email'
    ? 'Request an invite on the home page. For now, the form opens an email to support@hasala.app in your email app; send it, and we add the address you sent it from to the list.'
    : 'Request an invite on the home page, then tap Confirm my email in the email we send.';

export type FaqItem = {
  id: string;
  q: string;
  short: string;
  a?: string;
  steps?: readonly string[];
  after?: string;
  more: { href: string; label: string };
};

export const FAQ: readonly FaqItem[] = [
  {
    id: 'bank-login',
    q: 'Do you need my bank login?',
    short: 'No. Hasala reads the alerts your bank already sends you.',
    a: "It will never ask for a banking password or card number, and it can't move money.",
    more: { href: '/how-privacy-works', label: 'How privacy works' },
  },
  {
    id: 'email',
    q: 'What exactly can Hasala read in my email?',
    short: "Only your bank's alert emails, read-only.",
    a: `Your iPhone asks your mailbox only for messages from your bank's alert senders and reads those on the phone. The rest of your inbox is never downloaded. Before it uses an email, your iPhone checks it, and one it can't be sure came from your bank waits for you to review. Hasala can't send, change or delete mail, and no email is sent to an AI service. ${MAIL_NOTE}`,
    more: { href: '/how-it-works#email', label: 'Connecting your email' },
  },
  {
    id: 'texts',
    q: "Can Hasala use my bank's texts instead of my email?",
    short: 'Yes. Bank texts work with no mailbox access.',
    a: "Set up one automation in Apple's Shortcuts, and your iPhone hands Hasala the texts it receives. It keeps only payment texts and drops the rest at once. No text leaves your iPhone. It works from your next payment on, with any bank. An account uses bank email or bank texts, not both.",
    more: { href: '/how-it-works#texts', label: 'Using bank texts instead' },
  },
  {
    id: 'lost-phone',
    q: 'What if I lose my phone?',
    short: 'Your passkey or your 12‑word recovery phrase unlocks your data on a new iPhone.',
    a: "Your transactions and budget are encrypted with a key only your devices hold. Your passkey syncs in iCloud Keychain. A password signs you in but never unlocks your data. Keep the 12 words somewhere safe: we can't reset them for you.",
    more: { href: '/how-privacy-works#new-phone', label: 'A new or lost phone' },
  },
  {
    id: 'free',
    q: 'Is it free?',
    short: 'Yes. Hasala is free during the beta.',
    more: { href: '/#invite', label: 'Request an invite' },
  },
  {
    id: 'iphone-english',
    q: 'Why only iPhone, and only English?',
    short: 'Hasala does its work on the iPhone itself.',
    a: "Starting with one platform and one language lets us get every bank alert right before we promise more. The app is in light mode only for now, too.",
    more: { href: '/how-it-works#iphone', label: 'iPhone and English only, for now' },
  },
  {
    id: 'delete',
    q: 'How do I delete my account and data?',
    short: 'In Hasala, open Profile, then Delete your account.',
    a: 'That removes your account and the encrypted data our server keeps. To leave the waitlist instead, use the link in any email we sent you, or write to support@hasala.app.',
    more: { href: '/support', label: 'Support' },
  },
  {
    id: 'testflight',
    q: 'How does the TestFlight beta work?',
    short: "We email you an invite, and you install Hasala with Apple's TestFlight app.",
    a: `TestFlight is Apple's free app for trying beta apps. ${ASK_FOR_INVITE} When there's room, we email your invite from no-reply@hasala.app. Then:`,
    steps: [
      'Get TestFlight.',
      "Accept Apple's invitation and install Hasala. It comes by email, or use the link in your invite.",
      'Open Hasala and paste or type your invite.',
    ],
    after:
      `Apple handles the invitation, so it sees your email address and that you installed Hasala; other testers never see you. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day. You need an iPhone with iOS 26 or later, and your bank's alerts by text or in a ${MAIL_PERSONAL} address.`,
    more: { href: '/#invite', label: 'Request an invite' },
  },
];

export const curly = (s: string) => s.replace(/'/g, '’');

export const faqText = (f: FaqItem): string =>
  [f.short, f.a, f.steps?.map((step, i) => `${i + 1}. ${step}`).join(' '), f.after].filter(Boolean).join(' ');
