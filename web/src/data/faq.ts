import { FAQ, curly } from './site';
import type { FaqItem } from './site';

const OPEN_FIRST: Record<string, string> = {
  'bank-login':
    "No. Hasala only reads the alerts your bank already sends you. It can't move money, and it will never ask for your bank password or card number.",
};

const MOBILE_Q: Record<string, string> = { email: 'What can Hasala read in my email?' };
const MOBILE_A: Record<string, string> = {
  'bank-login':
    "No. Hasala only reads the alerts your bank already sends. It can't move money and won't ask for your bank password.",
};

export interface HomeFaq {
  id: string;
  question: string;
  questionMobile?: string;
  mobileFirst?: string;
  paragraphs: string[];
  steps: string[];
  more: FaqItem['more'];
}

export const HOME_FAQ: readonly HomeFaq[] = FAQ.map((item) => ({
  id: item.id,
  question: item.question,
  questionMobile: MOBILE_Q[item.id],
  mobileFirst: MOBILE_A[item.id] ? curly(MOBILE_A[item.id]) : undefined,
  paragraphs: (OPEN_FIRST[item.id]
    ? [OPEN_FIRST[item.id]]
    : [item.short, item.answer, item.after].filter(
        (part): part is string => part !== undefined && part !== '',
      )
  ).map((part) => curly(part)),
  steps: (item.steps ?? []).map((step) => curly(step)),
  more: item.more,
}));
