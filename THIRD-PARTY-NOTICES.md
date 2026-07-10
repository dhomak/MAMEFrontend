# Third-party notices

MAMEFrontend's own source is MIT-licensed (see `LICENSE`). It bundles the
following third-party binary, which is invoked as a separate subprocess (not
linked into the app) and retains its own license.

## 7-Zip (`MAMEFrontend/7zz`)

Used to extract artwork/snap images from `.7z` archives when a system `7z`/
`7zz` isn't available.

7-Zip — Copyright (C) 1999-2025 Igor Pavlov.

- The core 7-Zip codebase is licensed under the **GNU LGPL** (v2.1 or later).
- LZFSE decompression (from Apple) and Zstandard decompression (from Meta)
  are under the **BSD 3-Clause License**.
- XXH64 hashing (derived from Yann Collet's work) is under the
  **BSD 2-Clause License**.
- RAR decompression is subject to the **unRAR license restriction**: the code
  may be used to extract RAR archives, but not to develop a RAR/WinRAR
  compatible archiver. Copyright (C) Alexander Roshal.

7-Zip is free software and its use here — as an unmodified, separately
invoked executable — does not place MAMEFrontend's own source under LGPL.
Full license text: https://www.7-zip.org/license.txt
Source code: https://www.7-zip.org/download.html
