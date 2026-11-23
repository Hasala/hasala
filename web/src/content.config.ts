import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';
import { LEGAL_STATUSES } from './lib/legal-status.mjs';

const legal = defineCollection({
  loader: glob({ pattern: '*.md', base: '../docs/legal' }),
  schema: z
    .object({
      title: z.string(),
      description: z.string().optional(),
      standfirst: z.string().optional(),
      plainWords: z.union([z.string(), z.record(z.string(), z.string())]).optional(),
      status: z.enum(LEGAL_STATUSES).default('draft'),
      draftNote: z.string().optional(),
      version: z.union([z.string(), z.number()]).optional(),
      updated: z.coerce.date().optional(),
      lastUpdated: z.coerce.date().optional(),
      effective: z.coerce.date().optional(),
      contact: z.string().optional(),
    })
    .loose(),
});

export const collections = { legal };
