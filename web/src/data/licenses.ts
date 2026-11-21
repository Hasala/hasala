const MIT_TERMS = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`;

export const mitLicense = (copyright: readonly string[]) => `MIT License\n\n${copyright.join('\n')}\n\n${MIT_TERMS}\n`;

export interface ThirdParty {
  name: string;
  use: string;
  copyright: readonly string[];
  license: 'MIT' | 'OFL-1.1';
  licenseName: string;
  licenseUrl: string;
  homepage: string;
}

export const THIRD_PARTY: readonly ThirdParty[] = [
  {
    name: 'Inter',
    use: 'The typeface every page is set in: the Latin subset of the Inter variable font, served from hasala.app.',
    copyright: ['Copyright 2016 The Inter Project Authors (https://github.com/rsms/inter)'],
    license: 'OFL-1.1',
    licenseName: 'SIL Open Font License, Version 1.1',
    licenseUrl: 'https://spdx.org/licenses/OFL-1.1.html',
    homepage: 'https://github.com/rsms/inter',
  },
  {
    name: 'Astro',
    use: 'The client-side router that moves between pages without a full reload. It runs on every page.',
    copyright: [
      'Copyright (c) 2021 Fred K. Schott',
      'Parts from SvelteKit: Copyright (c) 2020 SvelteKit contributors',
      'Parts from Vite: Copyright (c) 2019-present, Yuxi (Evan) You and Vite contributors',
    ],
    license: 'MIT',
    licenseName: 'MIT License',
    licenseUrl: 'https://spdx.org/licenses/MIT.html',
    homepage: 'https://github.com/withastro/astro',
  },
  {
    name: 'Vite',
    use: 'A small module-preload helper, bundled into the invite page’s script.',
    copyright: ['Copyright (c) 2019-present, VoidZero Inc. and Vite contributors'],
    license: 'MIT',
    licenseName: 'MIT License',
    licenseUrl: 'https://spdx.org/licenses/MIT.html',
    homepage: 'https://github.com/vitejs/vite',
  },
  {
    name: 'uqr',
    use: 'The QR code encoder on the invite page, for opening an invite on your iPhone from a computer.',
    copyright: ['Copyright (c) Project Nayuki', 'Copyright (c) 2023 Anthony Fu <https://github.com/antfu>'],
    license: 'MIT',
    licenseName: 'MIT License',
    licenseUrl: 'https://spdx.org/licenses/MIT.html',
    homepage: 'https://github.com/unjs/uqr',
  },
];
