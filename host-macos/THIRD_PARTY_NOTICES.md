# Third-party notices

pi-os for macOS includes or downloads the third-party components below. This file is copied into the app bundle as
`Contents/Resources/THIRD_PARTY_NOTICES.md`. The licence texts that FluidAudio ships are copied beside it, into
`Contents/Resources/ThirdParty/FluidAudio/`, when the app is built.

## FluidAudio 0.17.5

- **What:** a Swift library for on-device speech recognition on Core ML. pi-os links it into the app and uses it only
  to run the Parakeet speech model below.
- **Source:** https://github.com/FluidInference/FluidAudio, tag `v0.17.5`, commit
  `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`.
- **Licence:** Apache License 2.0. Copyright FluidInference and contributors.
  - The full text is in `ThirdParty/FluidAudio/LICENSE`, or at http://www.apache.org/licenses/LICENSE-2.0.
  - FluidAudio does not ship a NOTICE file.
- **Build options:** pi-os builds FluidAudio from source with its `NemoTextProcessing` trait switched off, so the
  prebuilt NeMo text-processing library is not included.
- **FluidAudio's own third-party code:** fastcluster (BSD 2-Clause; © 2011 Daniel Müllner, © Google Inc.) and the
  components listed in FluidAudio's `ThirdPartyLicenses/` directory. Those licence texts are copied into
  `ThirdParty/FluidAudio/ThirdPartyLicenses/`.

## NVIDIA Parakeet TDT 0.6B v3 (speech recognition model)

- **What:** the multilingual speech-to-text model behind "enhanced recognition". It is **not part of the app**: it is
  downloaded only after you choose to download it in Settings → Voice.
- **Where it is stored:** on this Mac, in `~/Library/Application Support/pi-os/models/parakeet-tdt-v3/`.
- **Attribution:** "parakeet-tdt-0.6b-v3" by NVIDIA, licensed under the Creative Commons Attribution 4.0
  International licence (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/).
  - Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  - Core ML conversion by FluidInference: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml, revision
    `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`.
- **Changes:** pi-os uses the converted files unmodified, and checks each one against a SHA-256 digest pinned in the
  app before it is installed.
- **No warranty:** the model is provided as-is, without warranties, as the licence states.

## double-metaphone 2.0.1

- **Licence:** MIT. Copyright (c) 2014 Titus Wormer.
- **Source:** https://github.com/words/double-metaphone
- **Use:** ported into `node-harness/src/instant/phonetic.ts`, where it matches spoken app names by how they sound in
  English.

## cologne-phonetic 1.1.1

- **Licence:** MIT. Copyright (c) 2019 Max Dancau.
- **Source:** https://github.com/maxwellium/cologne-phonetic
- **Use:** ported into `node-harness/src/instant/phonetic.ts`, where it matches spoken app names by how they sound in
  German (Kölner Phonetik).

The MIT licence below applies to both double-metaphone and cologne-phonetic:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
> Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Tatoeba word frequencies

- **What:** the list of common English and German words in `node-harness/src/instant/lexiconData.ts`. The spoken app
  matcher uses it so that an ordinary word never opens an app on sound alone.
- **Source:** word counts over the Tatoeba sentence exports (https://tatoeba.org, export of 2026-10-03). Only
  single-word frequency facts are kept; no sentence text is included.
- **Attribution:** the Tatoeba contributors.
- **Licence:** Creative Commons Attribution 2.0 France (CC BY 2.0 FR, https://creativecommons.org/licenses/by/2.0/fr/).
